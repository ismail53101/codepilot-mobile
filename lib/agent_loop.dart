import 'dart:async';
import 'dart:convert';

import 'api_client.dart';
import 'models.dart';
import 'project_service.dart';
import 'tool_registry.dart';

/// Explicit lifecycle of one agent task. Every task reaches EXACTLY ONE
/// final state; the UI must never stay in [running] indefinitely.
enum AgentTaskState { idle, running, stopping, completed, failed, cancelled }

extension AgentTaskStateX on AgentTaskState {
  bool get isFinal =>
      this == AgentTaskState.completed ||
      this == AgentTaskState.failed ||
      this == AgentTaskState.cancelled;
}

/// The single, authoritative end-of-task record. Emitted exactly once.
class AgentOutcome {
  final AgentTaskState state; // always final
  final String message; // human-readable summary / error
  final String? detail; // technical detail (e.g. exception string)

  const AgentOutcome(this.state, this.message, {this.detail});

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

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

/// The autonomous agent loop.
///
/// USER PROMPT → [context build] → LLM with tools → execute tools (each with
/// its own timeout) → feed results back → repeat (up to [maxRounds]) → final
/// answer.
///
/// Lifecycle guarantees:
/// - [outcome] emits EXACTLY ONE final [AgentOutcome] per run.
/// - The watchdog measures **inactivity**: it re-arms before EVERY LLM call
///   and EVERY tool execution. Long multi-step tasks are fine; a task stuck
///   longer than [stepTimeout] on a single operation (hung request, stuck
///   subprocess) is finalized FAILED and the stuck operation aborted.
/// - [cancel] flips to STOPPING immediately: in-flight LLM requests abort
///   through the [CancelToken], running subprocesses are killed, no new
///   tools start, pending approvals resolve, run finalizes CANCELLED.
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

  /// Inactivity ceiling: max time ONE LLM call or ONE tool execution may
  /// take before the task finalizes as timed out. The watchdog re-arms
  /// before every step, so total task length is unbounded (progress-driven).
  final Duration stepTimeout;

  AgentLoop({
    required this.backend,
    required this.registry,
    required this.projects,
    this.mode = AgentMode.auto,
    this.maxRounds = 10,
    this.stepTimeout = const Duration(minutes: 60),
  });

  final _events = StreamController<AgentEvent>.broadcast();
  final _thoughts = StreamController<AgentThought>.broadcast();
  final _approvals = StreamController<AgentApprovalNeeded>.broadcast();
  final _outcomeCtrl = StreamController<AgentOutcome>.broadcast();

  Stream<AgentEvent> get events => _events.stream;
  Stream<AgentThought> get thoughts => _thoughts.stream;
  Stream<AgentApprovalNeeded> get approvals => _approvals.stream;

  /// Emits exactly one final [AgentOutcome] per run.
  Stream<AgentOutcome> get outcome => _outcomeCtrl.stream;

  AgentTaskState _state = AgentTaskState.idle;
  AgentTaskState get state => _state;

  bool _cancelled = false;
  CancelToken? _cancelToken; // aborts the in-flight LLM request
  Timer? _watchdog; // inactivity watchdog — re-armed per step
  CancelToken? _toolCancel; // aborts/kill the running tool (subprocess etc.)

  /// Begin stopping: flip state, abort HTTP, kill subprocesses, refuse new
  /// work. Safe to call multiple times.
  void cancel() {
    if (_state.isFinal || _state == AgentTaskState.stopping) return;
    _cancelled = true;
    if (_state == AgentTaskState.running) _state = AgentTaskState.stopping;
    // Abort the in-flight LLM request immediately (socket close).
    _cancelToken?.cancel();
    // Kill any running tool subprocess / abort its waits.
    _toolCancel?.cancel();
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

  /// (Re-)arm the inactivity watchdog for the NEXT step (LLM call or tool).
  /// [budget] may extend [stepTimeout] for tools that legitimately poll
  /// longer (e.g. ci_status waits up to 5 minutes internally).
  void _armWatchdog(String what, {Duration? budget}) {
    final limit = budget ?? stepTimeout;
    _watchdog?.cancel();
    _watchdog = Timer(limit, () {
      if (_state.isFinal) return;
      _cancelToken?.cancel();
      _toolCancel?.cancel();
      for (final c in _pendingApprovals.values) {
        if (!c.isCompleted) c.complete(false);
      }
      _pendingApprovals.clear();
      _finalize(AgentOutcome(
        AgentTaskState.failed,
        'Task timed out: $what exceeded the '
            '${limit.inSeconds}s step limit.',
        detail: 'deadline_exceeded: the inactivity watchdog aborted the '
            'stuck operation so the UI can never hang on a spinner.',
      ));
    });
  }

  /// Run the agent for [userRequest]. Returns the final assistant text.
  ///
  /// The returned future ALWAYS completes: the watchdog re-arms before every
  /// LLM call and tool execution, and the catch-all converts unexpected
  /// errors into a FAILED outcome. Exactly one outcome is emitted.
  Future<String> run(String userRequest, {List<ChatMessage>? priorHistory}) {
    if (_state == AgentTaskState.running || _state == AgentTaskState.stopping) {
      throw StateError('AgentLoop.run called while already running — '
          'create a new AgentLoop per task.');
    }
    _state = AgentTaskState.running;
    _cancelled = false;

    return _runInner(userRequest, priorHistory).whenComplete(() {
      _watchdog?.cancel();
      _watchdog = null;
    });
  }

  Future<String> _runInner(
      String userRequest, List<ChatMessage>? priorHistory) async {
    final hasProject = projects.projectName != null;
    final messages = <ChatMessage>[
      ChatMessage(role: 'system', content: _systemPrompt(hasProject)),
      if (priorHistory != null)
        ...priorHistory.where((m) => m.role == 'user' || m.role == 'assistant'),
      ChatMessage(role: 'user', content: _userTurn(userRequest)),
    ];

    String finalText = '';
    try {
      for (var round = 0; round < maxRounds; round++) {
        if (_cancelled) {
          _finalize(const AgentOutcome(AgentTaskState.cancelled,
              'Task stopped by the user.'));
          return finalText;
        }

        final ({String content, List<ToolCall> toolCalls}) resp;
        try {
          _cancelToken = CancelToken();
          _armWatchdog('the model request');
          // retries: 1 — a provider timeout should fail the task promptly
          // instead of silently retrying for many minutes.
          resp = await backend.chatWithTools(
            messages,
            tools: registry.schemas(),
            cancelToken: _cancelToken,
            retries: 1,
          );
        } on ApiException catch (e) {
          if (_cancelled || e.kind == 'cancelled') {
            _finalize(const AgentOutcome(AgentTaskState.cancelled,
                'Task stopped by the user.'));
            return finalText;
          }
          _finalize(AgentOutcome(AgentTaskState.failed, e.message,
              detail: e.kind));
          return finalText;
        } catch (e) {
          _finalize(
              AgentOutcome(AgentTaskState.failed, 'Agent failed: $e'));
          return finalText;
        } finally {
          _cancelToken = null;
        }

        if (_cancelled) {
          _finalize(const AgentOutcome(AgentTaskState.cancelled,
              'Task stopped by the user.'));
          return finalText;
        }

        if (resp.content.trim().isNotEmpty) {
          finalText = resp.content.trim();
          // Narration between tool rounds is the model's user-facing
          // reasoning; the FINAL round's content is the answer itself and
          // is not duplicated as a reasoning block.
          if (resp.toolCalls.isNotEmpty) {
            _thoughts.add(AgentThought(resp.content.trim()));
          }
        }

        if (resp.toolCalls.isEmpty) {
          // Model is done — no more tools requested.
          _finalize(AgentOutcome(AgentTaskState.completed,
              finalText.isEmpty ? 'Task completed.' : finalText));
          return finalText;
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
          if (_cancelled) {
            _finalize(const AgentOutcome(AgentTaskState.cancelled,
                'Task stopped by the user.'));
            return finalText;
          }
          _armWatchdog('tool "${call.name}"',
              budget: call.name == 'ci_status'
                  ? const Duration(minutes: 6)
                  : null);
          final result = await _executeStep(call);
          if (_state.isFinal) return finalText; // watchdog/cancel mid-step
          messages.add(ChatMessage(
            role: 'tool',
            content: result,
            toolCallId: call.id,
          ));
        }
      }

      // Ran out of rounds — one final no-tools call to force a wrap-up.
      try {
        _cancelToken = CancelToken();
        _armWatchdog('the summary request');
        final wrap = await backend.chatWithTools([
          ...messages,
          ChatMessage(
              role: 'user',
              content:
                  'You have reached the step limit. Summarize the outcome now: '
                  'what changed, what was verified, what remains.'),
        ], cancelToken: _cancelToken, retries: 1);
        finalText = wrap.content.trim().isEmpty ? finalText : wrap.content.trim();
      } on ApiException catch (e) {
        if (!_cancelled && e.kind != 'cancelled') {
          // The work itself may be done; report the summary failure but the
          // task outcome reflects the error honestly.
          _finalize(AgentOutcome(AgentTaskState.failed,
              'Task finished but the final summary request failed: ${e.message}',
              detail: e.kind));
          return finalText;
        }
      } catch (e) {
        _finalize(
            AgentOutcome(AgentTaskState.failed, 'Agent failed: $e'));
        return finalText;
      } finally {
        _cancelToken = null;
      }
      _finalize(AgentOutcome(AgentTaskState.completed,
          finalText.isEmpty ? 'Task completed.' : finalText));
      return finalText;
    } catch (e) {
      // Last-resort guard: nothing may escape without a final outcome.
      _finalize(AgentOutcome(AgentTaskState.failed, 'Agent failed: $e'));
      return finalText;
    }
  }

  /// Finalize-once: only the FIRST call wins; every later call is ignored.
  /// This is the single point where duplicate completion/failure/cancel
  /// events are collapsed.
  void _finalize(AgentOutcome o) {
    if (_state.isFinal) return; // late duplicates are dropped
    _watchdog?.cancel();
    _watchdog = null;
    _state = o.state;
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final c in _pendingApprovals.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingApprovals.clear();
    _outcomeCtrl.add(o);
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

    if (_cancelled) {
      step
        ..status = AgentStepStatus.failed
        ..detail = 'Cancelled before execution.';
      _events.add(StepFinished(step));
      return 'CANCELLED';
    }

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
      if (_cancelled) {
        step
          ..status = AgentStepStatus.failed
          ..detail = 'Cancelled while awaiting approval.';
        _events.add(StepFinished(step));
        return 'CANCELLED';
      }
      if (!approved) {
        step
          ..status = AgentStepStatus.failed
          ..detail = 'The user denied this action.';
        _events.add(StepFinished(step));
        return 'DENIED: the user declined this action. Stop and explain, or '
            'adjust your plan. Do not retry the same call.';
      }
    }

    String result;
    // Per-tool budget: commands die at the terminal's own 30s cap; CI
    // polling legitimately waits up to 5 minutes; everything else 60s.
    final perTool = switch (call.name) {
      'ci_status' => const Duration(minutes: 6),
      'run_command' => const Duration(seconds: 60),
      _ => const Duration(seconds: 60),
    };
    try {
      // Per-tool timeout + cancellation: a slow tool (build, CI poll,
      // subprocess) can never wedge the whole task. The tool sees a cancel
      // token it can honor (subprocess kill, poll abort).
      _toolCancel = CancelToken();
      result = await registry
          .execute(call.name, call.arguments,
              cancelToken: _toolCancel, timeout: perTool)
          .timeout(perTool + const Duration(seconds: 30), onTimeout: () {
        _toolCancel?.cancel();
        return 'ERROR: tool "${call.name}" timed out after '
            '${perTool.inSeconds}s and was aborted. Do NOT retry the same '
            'long-running call; report the timeout and continue.';
      });
    } catch (e) {
      result = 'ERROR: tool crashed: $e';
    } finally {
      _toolCancel = null;
    }
    if (_state.isFinal) return result;

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
You are CodeFexa, an AUTONOMOUS coding agent running on the user's Android device.
You accomplish tasks by CALLING TOOLS, not by printing code for the user to apply.

Working rules:
1. UNDERSTAND the task. INSPECT the project first (list_files, search_code, read_file).
2. PLAN briefly (2-5 steps) in plain text before editing.
3. EDIT files with write_file / create_file / patch_file. patch_file needs an EXACT old_text copied from read_file output. write_file needs the COMPLETE new file content.
4. VERIFY after editing when possible: re-read the changed region or run a safe read-only command (run_command supports ls/cat/grep/find on-device).
5. If a verification or command FAILS, read the error, fix the cause, and retry — up to 3 attempts — before reporting failure.
6. When the user asks to commit: run git_status, then git_commit with a clear message. For a PR: create_branch → commit to it → create_pull_request. These need a linked GitHub repository.
7. NEVER use sleep, long-running watchers, or busy-wait loops — they are blocked and waste the task budget. To watch a build: use ci_status (it polls for up to 5 minutes internally), or ci_status {"wait": false} for a quick check.
8. Each tool call has its own time limit (commands 120s, CI polling 5 min). If a tool times out, do NOT retry the same call — report the timeout and continue or summarize.
9. FINAL MESSAGE: a compact summary — Changes, Files changed, Verification, and Git result (commit hash / PR link) when applicable. Plain text; the UI renders it.
10. NEVER invent tool results. NEVER claim a file was modified unless a write tool returned OK. NEVER claim tests passed unless you actually ran them and they passed.
11. NARRATION: begin every turn that calls tools with ONE short, action-oriented sentence (max 25 words) saying what you are doing next and why (e.g. "I'll inspect the navigation setup before removing the duplicate tab."). The UI shows it as your visible reasoning — keep it concise; no private deliberation.
''';
    if (hasProject) {
      return '$base\nA project IS open. Use tools on it. Do not ask the user to paste files.';
    }
    return '$base\nNO project is open: file and git tools will return an error. '
        'For coding questions answer directly; for project work, tell the user to '
        'create a project (Home → menu → Projects → New Project) or import one '
        '(Home → File → ZIP, or Integrations → GitHub).';
  }

  String _userTurn(String request) {
    final hasProject = projects.projectName != null;
    final head = hasProject
        ? 'PROJECT: ${projects.projectName} (${projects.detectType()})\n'
        : 'PROJECT: none open\n';
    return '$head\nTASK: $request';
  }
}
