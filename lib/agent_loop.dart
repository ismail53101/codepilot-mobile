import 'dart:async';
import 'dart:convert';

import 'api_client.dart';
import 'models.dart';
import 'project_service.dart';
import 'tool_registry.dart';

/// Events emitted while the agent loop runs. The UI renders these as the
/// live activity panel; every event corresponds to a real tool execution.
sealed class AgentEvent {
  final AgentStep step;
  AgentEvent(this.step);
}

class StepStarted extends AgentEvent {
  StepStarted(super.step);
}

class StepFinished extends AgentEvent {
  StepFinished(super.step);
}

class AgentThought {
  final String text;
  AgentThought(this.text);
}

class AgentApprovalNeeded {
  final String tool;
  final Map<String, dynamic> args;
  AgentApprovalNeeded(this.tool, this.args);
}

class AgentFailed {
  final String message;
  AgentFailed(this.message);
}

/// The autonomous agent loop.
///
/// USER PROMPT → [context build] → LLM with tools → execute tool calls →
/// feed results back → repeat (up to [maxRounds]) → final answer.
///
/// Approval modes:
/// - planOnly: one LLM round, tools provided but the executor REJECTS every
///   mutating tool with a "plan only" message, so the model can only read
///   and plan.
/// - askBeforeChanges: mutating tools pause the loop and call
///   [onApproval]; the user's decision is enforced via the registry gate.
/// - auto: mutating tools run without asking (the chat UI still shows every
///   step; the change log makes everything reversible via undo).
class AgentLoop {
  final ChatBackend backend;
  final ToolRegistry registry;
  final ProjectService projects;
  final AgentMode mode;
  final int maxRounds;

  AgentLoop({
    required this.backend,
    required this.registry,
    required this.projects,
    this.mode = AgentMode.auto,
    this.maxRounds = 10,
  });

  final _events = StreamController<AgentEvent>.broadcast();
  final _thoughts = StreamController<AgentThought>.broadcast();
  final _approvals = StreamController<AgentApprovalNeeded>.broadcast();
  final _failures = StreamController<AgentFailed>.broadcast();

  Stream<AgentEvent> get events => _events.stream;
  Stream<AgentThought> get thoughts => _thoughts.stream;
  Stream<AgentApprovalNeeded> get approvals => _approvals.stream;
  Stream<AgentFailed> get failures => _failures.stream;

  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    // A user cancelling while an approval dialog is up must not leave the
    // loop (or the registry gate) hanging forever.
    for (final c in _pendingApprovals.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingApprovals.clear();
  }

  /// Tools that change the workspace — gated by approval mode.
  static const _mutating = {
    'write_file',
    'create_file',
    'patch_file',
    'delete_file',
    'move_file',
    'git_commit',
    'git_push',
    'create_branch',
    'create_pull_request',
  };

  /// Run the agent for [userRequest]. Returns the final assistant text.
  Future<String> run(String userRequest, {List<ChatMessage>? priorHistory}) async {
    _cancelled = false;
    final hasProject = projects.projectName != null;
    final messages = <ChatMessage>[
      ChatMessage(role: 'system', content: _systemPrompt(hasProject)),
      if (priorHistory != null)
        ...priorHistory.where((m) => m.role == 'user' || m.role == 'assistant'),
      ChatMessage(role: 'user', content: _userTurn(userRequest)),
    ];

    // Approval handling lives in the loop (_executeStep): the registry stays
    // gate-free so there is no register/resolve race between the UI dialog
    // and a gate completer.

    String finalText = '';
    for (var round = 0; round < maxRounds; round++) {
      if (_cancelled) return finalText;

      final ({String content, List<ToolCall> toolCalls}) resp;
      try {
        resp = await backend
            .chatWithTools(messages, tools: registry.schemas());
      } on ApiException catch (e) {
        _failures.add(AgentFailed(e.message));
        rethrow;
      }

      if (_cancelled) return finalText;

      if (resp.content.trim().isNotEmpty) {
        _thoughts.add(AgentThought(resp.content.trim()));
        finalText = resp.content.trim();
      }

      if (resp.toolCalls.isEmpty) {
        return finalText; // model is done — no more tools requested
      }

      // Echo the assistant tool_calls turn, then append tool results.
      messages.add(ChatMessage(
        role: 'assistant',
        content: resp.content,
        toolCalls: [
          for (final c in resp.toolCalls)
            {
              'id': c.id,
              'type': 'function',
              'function': {
                'name': c.name,
                'arguments': jsonEncode(c.arguments),
              },
            },
        ],
      ));

      for (final call in resp.toolCalls) {
        if (_cancelled) return finalText;
        final result = await _executeStep(call);
        messages.add(ChatMessage(
          role: 'tool',
          content: result,
          toolCallId: call.id,
        ));
      }
    }

    // Ran out of rounds — one final no-tools call to force a wrap-up.
    try {
      final wrap = await backend.chatWithTools([
        ...messages,
        ChatMessage(
            role: 'user',
            content:
                'You have reached the step limit. Summarize the outcome now: '
                'what changed, what was verified, what remains.'),
      ]);
      return wrap.content.trim().isEmpty ? finalText : wrap.content.trim();
    } on ApiException {
      return finalText;
    }
  }

  Future<String> _executeStep(ToolCall call) async {
    final step = AgentStep(
      id: call.id,
      title: _titleFor(call),
      tool: call.name,
      args: call.arguments,
      status: AgentStepStatus.running,
    );
    _events.add(StepStarted(step));

    if (mode == AgentMode.planOnly && _mutating.contains(call.name)) {
      step
        ..status = AgentStepStatus.failed
        ..detail = 'Plan-only mode: mutation "${call.name}" was not executed.';
      _events.add(StepFinished(step));
      return 'DENIED: Plan-only mode. This session cannot modify the project. '
          'Present a detailed implementation plan instead.';
    }

    // For ask-before-changes, ask the user BEFORE running. The completer is
    // registered synchronously inside _gate before the first await, so the
    // UI's later resolveApproval() always finds it.
    if (mode == AgentMode.askBeforeChanges && _mutating.contains(call.name)) {
      _approvals.add(AgentApprovalNeeded(call.name, call.arguments));
      final approved = await _gate(call.name, call.arguments);
      if (_cancelled) return 'CANCELLED';
      if (!approved) {
        step
          ..status = AgentStepStatus.failed
          ..detail = 'The user denied this action.';
        _events.add(StepFinished(step));
        return 'DENIED: the user declined this action. Stop and explain, or '
            'adjust your plan. Do not retry the same call.';
      }
    }

    final result = await registry.execute(call.name, call.arguments);
    if (_cancelled) return result;

    if (const ['write_file', 'create_file', 'patch_file']
        .contains(call.name)) {
      agentHistory.recordIfWrite(call.name, call.arguments);
    }

    step
      ..status = result.startsWith('ERROR') || result.startsWith('DENIED')
          ? AgentStepStatus.failed
          : AgentStepStatus.done
      ..detail = result;
    _events.add(StepFinished(step));
    return result;
  }

  /// Registry gate: in ask-mode this is where the UI dialog decision lands.
  /// The loop records the request via [_approvals]; the ChatScreen awaits a
  /// user decision through [resolveApproval].
  final Map<String, Completer<bool>> _pendingApprovals = {};

  Future<bool> _gate(String tool, Map<String, dynamic> args) async {
    if (mode == AgentMode.auto) return true;
    final completer = Completer<bool>();
    _pendingApprovals['$tool:${args['path'] ?? args['name'] ?? ''}'] = completer;
    return completer.future;
  }

  /// Called by the UI when the user answers an approval dialog.
  void resolveApproval(String tool, String key, bool approved) {
    final c = _pendingApprovals.remove('$tool:$key');
    c?.complete(approved);
  }

  String _titleFor(ToolCall call) => switch (call.name) {
        'list_files' => 'Inspecting project structure',
        'read_file' => 'Reading ${call.arguments['path'] ?? 'file'}',
        'search_code' => 'Searching “${call.arguments['query'] ?? ''}”',
        'write_file' => 'Writing ${call.arguments['path'] ?? 'file'}',
        'create_file' => 'Creating ${call.arguments['path'] ?? 'file'}',
        'patch_file' => 'Patching ${call.arguments['path'] ?? 'file'}',
        'delete_file' => 'Deleting ${call.arguments['path'] ?? 'file'}',
        'move_file' =>
          'Moving ${call.arguments['source'] ?? ''} → ${call.arguments['destination'] ?? ''}',
        'run_command' => 'Running: ${call.arguments['command'] ?? ''}',
        'git_status' => 'Checking workspace changes',
        'git_commit' => 'Creating git commit',
        'create_branch' => 'Creating branch ${call.arguments['name'] ?? ''}',
        'git_push' => 'Pushing to GitHub',
        'create_pull_request' => 'Opening pull request',
        'ci_status' => 'Checking CI status',
        _ => call.name,
      };

  // ------------------------------------------------------------------
  // Prompts
  // ------------------------------------------------------------------

  String _systemPrompt(bool hasProject) {
    const base = '''
You are CodePilot, an AUTONOMOUS coding agent running on the user's Android device.
You accomplish tasks by CALLING TOOLS, not by printing code for the user to apply.

Working rules:
1. UNDERSTAND the task. INSPECT the project first (list_files, search_code, read_file).
2. PLAN briefly (2-5 steps) in plain text before editing.
3. EDIT files with write_file / create_file / patch_file. patch_file needs an EXACT old_text copied from read_file output. write_file needs the COMPLETE new file content.
4. VERIFY after editing when possible: re-read the changed region or run a safe read-only command (run_command supports ls/cat/grep/find on-device).
5. If a verification or command FAILS, read the error, fix the cause, and retry — up to 3 attempts — before reporting failure.
6. When the user asks to commit: run git_status, then git_commit with a clear message. For a PR: create_branch → commit to it → create_pull_request. These need a linked GitHub repository.
7. FINAL MESSAGE: a compact summary — Changes, Files changed, Verification, and Git result (commit hash / PR link) when applicable. Plain text; the UI renders it.
8. NEVER invent tool results. NEVER claim a file was modified unless a write tool returned OK. NEVER claim tests passed unless you actually ran them and they passed.
''';
    if (hasProject) {
      return '$base\nA project IS open. Use tools on it. Do not ask the user to paste files.';
    }
    return '$base\nNO project is open: file and git tools will return an error. '
        'For coding questions answer directly; for project work, tell the user to '
        'import a project (Home → File → ZIP, or Integrations → GitHub).';
  }

  String _userTurn(String request) {
    final hasProject = projects.projectName != null;
    final head = hasProject
        ? 'PROJECT: ${projects.projectName} (${projects.detectType()})\n'
        : 'PROJECT: none imported\n';
    return '$head\nTASK: $request';
  }
}
