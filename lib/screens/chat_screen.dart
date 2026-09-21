import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../agent_loop.dart';
import '../agent_activity.dart';
import '../agent_service.dart';
import '../api_client.dart';
import '../github_service.dart';
import '../main.dart';
import '../models.dart';
import '../pdf_text.dart';
import '../preview_manager.dart';
import '../project_service.dart';
import '../stores.dart';
import '../theme.dart';
import '../tool_registry.dart';
import '../widgets/agent_activity_panel.dart';
import 'preview_screen.dart';

/// AI Coding Chat screen: command bar + streaming chat + confirm/diff flow.
///
/// Conversations persist across app restarts ([ChatSessionStore]) and can be
/// resumed from the Chats sheet. Assistant replies render fenced code blocks
/// as copyable monospace cards.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _manualScrollActive = false;
  bool _userNearBottom = true;
  final List<ChatMessage> _messages = [];
  List<ProposedChange> _pending = [];
  bool _busy = false;
  bool _restored = false;
  String? _streamBuf;
  String? _sessionId;
  // Content of a file attached on Home (route argument), injected once.
  String? _pendingAttachment;
  String? _pendingAttachmentName;
  String? _pendingAttachmentKind;
  // Image attached in-chat (base64 data URL) — sent via vision format.
  String? _pendingImage;
  String? _pendingImageName;

  // ---- autonomous agent state ----
  bool _agentMode = false; // Chat is the safe default; Project is explicit.
  AgentMode _approvalMode = AgentMode.auto;
  AgentLoop? _activeLoop;

  /// Ordered REAL activity timeline: model narration (ReasoningEntry)
  /// interleaved with executed tool steps (StepEntry). Drives the live
  /// activity panel AND the persisted snapshot — nothing is fabricated.
  final List<AgentTimelineEntry> _timeline = [];

  /// Real task start/end — the only sources for the elapsed label.
  DateTime? _taskStart;
  DateTime? _taskEnd;
  /// Explicit task lifecycle: the UI is driven by this + the loop's outcome
  /// stream, never by an indefinite boolean spinner.
  AgentTaskState _agentState = AgentTaskState.idle;
  String? _agentError;
  /// Text of the last agent task — powers the one-tap Retry on failure.
  String? _lastAgentRequest;
  String? _taskId;
  Map<String, dynamic>? _resumeContext;
  /// Most recent saved conversations (for the resume card on fresh chats).
  List<ChatSession> _recentSessions = const [];
  StreamSubscription<AgentEvent>? _eventSub;
  StreamSubscription<AgentThought>? _thoughtSub;
  StreamSubscription<AgentApprovalNeeded>? _approvalSub;
  StreamSubscription<AgentOutcome>? _outcomeSub;

  static String _approvalKey(String tool, Map<String, dynamic> args) =>
      '$tool:${args['path'] ?? args['name'] ?? ''}';

  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

  /// Pick an image/code file mid-chat. Images go to the model as vision
  /// input; text files are inlined. Nothing becomes a project unless the
  /// user explicitly imports it from Project mode.
  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      final file = result?.files.single;
      if (file == null) return;
      final ext = file.extension?.toLowerCase() ?? '';

      if (ext == 'zip') {
        if (_agentMode) {
          if (file.path == null) return;
          try {
            final message = await projectService.importZip(file.path!);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import ZIP: $e')));
          }
        } else {
          setState(() {
            _pendingAttachment = null;
            _pendingAttachmentName = file.name;
            _pendingAttachmentKind = 'archive';
          });
        }
        return;
      }

      if (_imageExtensions.contains(ext)) {
        final bytes = file.bytes;
        if (bytes == null || bytes.lengthInBytes > 5 * 1024 * 1024) {
          _push('system', 'Image is missing or larger than 5 MB.', isError: true);
          return;
        }
        setState(() {
          _pendingImage = 'data:image/$ext;base64,${base64Encode(bytes)}';
          _pendingImageName = file.name;
          _pendingAttachmentKind = 'image';
        });
        return;
      }

      if (ext == 'pdf') {
        final bytes = file.bytes;
        if (bytes == null) {
          _push('system', 'Could not read the PDF.', isError: true);
          return;
        }
        try {
          final result = PdfText.extract(bytes);
          if (result.scanned) {
            _push('system',
                '"${file.name}" is a scanned PDF (page images, no text layer). It has no extractable text — attach screenshots of the pages instead.',
                isError: true);
            return;
          }
          if (result.text.trim().isEmpty) {
            _push('system', 'No text could be extracted from "${file.name}".', isError: true);
            return;
          }
          setState(() {
            _pendingAttachment = result.text;
            _pendingAttachmentName = file.name;
            _pendingAttachmentKind = 'pdf';
          });
        } catch (_) {
          _push('system', 'Could not extract text from "${file.name}" — it may be corrupted or password-protected.',
              isError: true);
        }
        return;
      }

      // Treat everything else as a text/code file (binary-safe read).
      final bytes = file.bytes;
      if (bytes == null) return;
      for (final b in bytes.take(512)) {
        if (b < 9 || (b > 13 && b < 32)) {
          _push('system', 'Unsupported binary file type: .${file.extension}', isError: true);
          return;
        }
      }
      final content = utf8.decode(bytes, allowMalformed: true);
      setState(() {
        _pendingAttachment = content.length > 12000
            ? content.substring(0, 12000)
            : content;
        _pendingAttachmentName = file.name;
        _pendingAttachmentKind = 'code';
      });
    } catch (e) {
      _push('system', 'File picker unavailable: $e', isError: true);
    }
  }

  void _clearAttachments() {
    setState(() {
      _clearAttachmentState();
    });
  }

  void _clearAttachmentState() {
    _pendingAttachment = null;
    _pendingAttachmentName = null;
    _pendingAttachmentKind = null;
    _pendingImage = null;
    _pendingImageName = null;
  }

  bool get _hasPendingAttachment =>
      _pendingAttachmentName != null || _pendingImage != null;

  Future<void> _setProjectMode(bool project) async {
    if (_busy || _agentMode == project) return;
    if (!project) {
      setState(() => _agentMode = false);
      return;
    }
    final projects = await projectService.listProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No project selected. Create or open a project first.')),
      );
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.navyPanel,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Select project', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final name in projects)
              ListTile(
                leading: const Icon(Icons.folder_outlined, color: AppTheme.glowAccent),
                title: Text(name),
                onTap: () => Navigator.pop(sheetContext, name),
              ),
            ListTile(
              leading: const Icon(Icons.add, color: AppTheme.accent),
              title: const Text('Create Project'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.pushNamed(context, '/new-project');
              },
            ),
          ],
        ),
      ),
    );
    if (!mounted || chosen == null) return;
    try {
      await projectService.openProject(chosen);
      if (!mounted) return;
      setState(() => _agentMode = true);
    } on ProjectException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void dispose() {
    // Leaving the screen mid-task must stop the loop and any pending
    // approval wait — no background polling, no orphaned completers.
    // Persist the thread FIRST so backing out mid-run never loses the task
    // text (the post-run save can no longer happen once unmounted).
    if (_agentState == AgentTaskState.running ||
        _agentState == AgentTaskState.stopping) {
      // Mark the thread honestly: the agent was cancelled because the user
      // left the screen. Without this the reopened chat would show the task
      // text with no explanation of what happened to it.
      _messages.add(const ChatMessage(
        role: 'system',
        content: '⏹ Task stopped — you left this screen while the agent was '
            'working. Send the task again (or use Retry) to continue.',
      ));
      // Finalize the persisted activity state too, so reopening the chat
      // shows the honest incomplete block instead of a phantom running task.
      _agentState = AgentTaskState.cancelled;
      _agentError = 'You left this screen while the agent was working.';
      _taskEnd ??= DateTime.now();
    }
    if (_messages.isNotEmpty || _timeline.isNotEmpty) {
      unawaited(_saveSession());
    }
    _activeLoop?.cancel();
    _eventSub?.cancel();
    _thoughtSub?.cancel();
    _approvalSub?.cancel();
    _outcomeSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Chat is always the safe default. A project becomes conversation context
    // only after the user explicitly switches mode and opens/selects it.
    _agentMode = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initFromRoute());
  }

  Future<void> _initFromRoute() async {
    if (!mounted) return;
    final arg = ModalRoute.of(context)?.settings.arguments;
    final bool fresh = arg is Map && arg['fresh'] == true;
    final String? requestedSessionId = arg is Map ? arg['sessionId'] as String? : null;

    // A query passed from the Home composer (or File Preview "Ask AI") is
    // the user's FIRST MESSAGE — send it immediately so there is exactly one
    // composer in play: Home submits, Chat answers and owns follow-ups.
    String? routeQuery;
    if (arg is String && arg.isNotEmpty) {
      routeQuery = arg;
    } else if (arg is Map) {
      final query = arg['query'];
      if (query is String && query.isNotEmpty) routeQuery = query;
      if (arg['attachmentName'] is String && arg['attachmentContent'] is String) {
        setState(() {
          _pendingAttachmentName = arg['attachmentName'] as String;
          _pendingAttachment = arg['attachmentContent'] as String;
        });
      }
    }

    // Resume the most recent conversation silently (memory across restarts).
    if (requestedSessionId != null) {
      final sessions = await chatSessionStore.load();
      ChatSession? chosen;
      for (final session in sessions) {
        if (session.id == requestedSessionId) {
          chosen = session;
          break;
        }
      }
      if (!mounted) return;
      if (chosen != null) {
        final selected = chosen;
        setState(() {
          _restored = true;
          _agentMode = selected.isProject;
          _sessionId = selected.id;
          _messages.addAll(selected.messages);
          _restoreActivity(selected.activity);
        });
      }
    } else if (fresh) {
      // Entering from Home: ALWAYS a brand-new conversation, like other
      // chatbots. A previously resumed thread is not lost — it stays in
      // the Chats history and is offered via the resume card below.
      final sessions = await chatSessionStore.load();
      if (!mounted) return;
      setState(() {
        _restored = true;
        _sessionId = null;
        _taskId = null;
        _lastAgentRequest = null;
        _resumeContext = null;
        _agentMode = false;
        _messages.clear();
        _pending.clear();
        _recentSessions = sessions.where((s) => !s.isProject).take(3).toList();
      });
    } else if (!_restored) {
      final sessions = await chatSessionStore.load();
      if (!mounted) return;
      setState(() {
        _restored = true;
        final matching = sessions.where((s) => s.isProject == _agentMode).toList();
        if (matching.isNotEmpty) {
          _sessionId = matching.first.id;
          _messages.addAll(matching.first.messages);
          // Restore the saved task activity too (steps, reasoning,
          // progress, errors, result) so reopened chats look identical.
          _restoreActivity(matching.first.activity);
        }
      });
    }

    if (routeQuery != null) {
      // Continuity: route queries CONTINUE the current conversation (or the
      // resumed one) — they never wipe it. Home submits, Chat keeps one
      // running thread.
      _input.text = routeQuery;
      await _send(); // _send() clears _input after queueing the message
    } else {
      _scrollDown();
    }
  }

  String get _sessionTitle {
    for (final m in _messages) {
      if (m.role == 'user') {
        final t = m.content.trim().replaceAll('\n', ' ');
        return t.length > 60 ? '${t.substring(0, 60)}…' : t;
      }
    }
    return 'Chat';
  }

  /// Persisted activity snapshot — conversation + task state are saved
  /// CONTINUOUSLY (task start, every finished step, final outcome), never
  /// only at the end, so backing out mid-run preserves everything.
  Map<String, dynamic>? _activitySnapshot() {
    if (_timeline.isEmpty) return null;
    return AgentActivitySnapshot(
      state: _agentState.name,
      entries: List.of(_timeline),
      startedAt: _taskStart,
      endedAt: _taskEnd,
      error: _agentError,
      resumeContext: _resumeContext,
    ).toJson();
  }

  /// Restore a persisted activity snapshot (reopen conversation / resume).
  void _restoreActivity(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final snap = AgentActivitySnapshot.fromJson(data);
      var stateName = snap.state;
      String? error = snap.error;
      // A hard app kill can persist a non-final state — show it honestly
      // as stopped rather than a phantom running task.
      if (stateName == 'running' || stateName == 'stopping' || stateName == 'idle') {
        stateName = 'cancelled';
        error ??= 'The app closed while the task was running.';
      }
      final state = AgentTaskState.values
          .firstWhere((s) => s.name == stateName, orElse: () => AgentTaskState.idle);
      _timeline.addAll(snap.entries);
      _agentState = state;
      _agentError = error;
      _taskStart = snap.startedAt;
      _taskEnd = snap.endedAt;
      _resumeContext = snap.resumeContext;
      _taskId = _resumeContext?['taskId'] as String?;
      _lastAgentRequest = _lastUserMessage();
    } catch (_) {
      // Corrupt snapshot → ignore activity, keep the transcript.
    }
  }

  String? _lastUserMessage() {
    for (final m in _messages.reversed) {
      if (m.role == 'user') return m.content;
    }
    return null;
  }

  void _updateResumeContext({String? interruptedAction}) {
    final steps = [
      for (final entry in _timeline)
        if (entry is StepEntry) entry.step,
    ];
    final done = steps.where((s) => s.status == AgentStepStatus.done).toList();
    final failed = steps.where((s) => s.status == AgentStepStatus.failed).toList();
    String label(AgentStep s) {
      final detail = s.args['path'] ?? s.args['command'] ?? s.args['query'];
      return detail == null ? s.title : '${s.title}: $detail';
    }
    _resumeContext = {
      'taskId': _taskId,
      'projectId': projectService.projectName,
      'objective': _lastAgentRequest ?? '',
      'completedSteps': [for (final s in done) label(s)],
      'modifiedFiles': [
        for (final s in done.where((s) => const ['write_file', 'create_file', 'patch_file', 'delete_file', 'move_file'].contains(s.tool)))
          if (s.args['path'] is String) s.args['path'],
      ],
      'commandsSucceeded': [
        for (final s in done.where((s) => s.tool == 'run_command'))
          if (s.args['command'] is String) s.args['command'],
      ],
      'failedStep': failed.isEmpty ? null : label(failed.last),
      'lastSuccessfulCheckpoint': done.isEmpty ? null : label(done.last),
      'nextAction': interruptedAction ?? (failed.isEmpty ? 'Inspect the current project and continue with the first incomplete action.' : label(failed.last)),
      'pendingSteps': remainingWork(steps),
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  String _resumePrompt() {
    final c = _resumeContext;
    if (c == null) return _lastAgentRequest ?? '';
    final completed = (c['completedSteps'] as List? ?? const []).join('\n- ');
    final pending = (c['pendingSteps'] as List? ?? const []).join('\n- ');
    return 'RESUME EXISTING PROJECT TASK FROM CHECKPOINT.\n'
        'PROJECT: ${c['projectId'] ?? projectService.projectName ?? 'none'}\n'
        'ORIGINAL TASK: ${c['objective']}\n'
        'COMPLETED CHECKPOINTS:\n- $completed\n'
        'LAST SUCCESSFUL CHECKPOINT: ${c['lastSuccessfulCheckpoint'] ?? 'none'}\n'
        'INTERRUPTED ACTION: ${c['failedStep'] ?? c['nextAction'] ?? 'unknown'}\n'
        'REMAINING:\n- $pending\n'
        'IMPORTANT: Inspect the current filesystem first. Do not repeat completed work or rewrite files that already contain the intended changes. Continue from the first incomplete action.';
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;
    // Adopt the id on first save so every later save updates the SAME
    // session (immediate mid-run saves must not create duplicates).
    final id = await chatSessionStore.save(
      existingId: _sessionId,
      title: _sessionTitle,
      messages: List.of(_messages),
      isProject: _agentMode,
      activity: _activitySnapshot(),
    );
    if (id.isNotEmpty && _sessionId == null) {
      _sessionId = id;
    }
  }

  Future<void> _openChatHistory() async {
    final allSessions = await chatSessionStore.load();
    final sessions = allSessions.where((s) => s.isProject == _agentMode).toList();
    if (!mounted) return;
    Object? sheetResult;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
        decoration: const BoxDecoration(
          color: AppTheme.navyPanel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppTheme.border)),
        ),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 14, bottom: 12),
              decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)),
            ),
            Row(children: [
              const SizedBox(width: 20),
              const Expanded(
                child: Text('Chats', style: TextStyle(color: AppTheme.text, fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Delete all chats',
                icon: const Icon(Icons.delete_sweep_outlined, color: AppTheme.muted),
                onPressed: sessions.isEmpty
                    ? null
                    : () async {
                        await chatSessionStore.clearAll();
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
              ),
            ]),
            const SizedBox(height: 4),
            Flexible(
              child: sessions.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No saved chats yet.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.muted)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: sessions.length,
                      itemBuilder: (context, i) {
                        final s = sessions[i];
                        final isCurrent = s.id == _sessionId;
                        return ListTile(
                          leading: Icon(
                            isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                            color: isCurrent ? AppTheme.glowAccent : AppTheme.muted,
                          ),
                          title: Text(s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                          subtitle: Text(
                            '${s.messages.length} messages · ${s.time.toLocal().month}/${s.time.toLocal().day}',
                            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.muted),
                            onPressed: () async {
                              await chatSessionStore.remove(s.id);
                              if (!sheetContext.mounted) return;
                              Navigator.pop(sheetContext);
                            },
                          ),
                          onTap: () {
                            sheetResult = s;
                            Navigator.pop(sheetContext);
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    final chosen = sheetResult;
    if (chosen is ChatSession) {
      setState(() {
        _sessionId = chosen.id;
        _messages
          ..clear()
          ..addAll(chosen.messages);
        _pending.clear();
        // Swap in the chosen conversation's task activity (or none).
        _timeline.clear();
        _taskStart = null;
        _taskEnd = null;
        _agentState = AgentTaskState.idle;
        _agentError = null;
        _restoreActivity(chosen.activity);
      });
      await _saveSession();
      _scrollDown();
    }
  }

  Future<void> _newChat() async {
    if (_messages.isNotEmpty) await _saveSession();
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _pending.clear();
      _sessionId = null;
      _taskId = null;
      _lastAgentRequest = null;
      _resumeContext = null;
      _agentMode = false;
      _timeline.clear();
      _taskStart = null;
      _taskEnd = null;
      _agentState = AgentTaskState.idle;
      _agentError = null;
    });
    _push('system', 'New chat. Chat Mode is active and no project is selected.');
  }

  /// Re-open the previous thread without losing the current one (it is
  /// saved first). Used by the "Continue previous conversation" card.
  Future<void> _resumePrevious() async {
    if (_recentSessions.isEmpty) return;
    await _saveSession(); // keep the current thread if it has content
    final chosen = _recentSessions.first;
    if (!mounted) return;
    setState(() {
      _sessionId = chosen.id;
      _messages
        ..clear()
        ..addAll(chosen.messages);
      _pending.clear();
      _recentSessions = const [];
      // Restore this conversation's task activity (if it had any).
      _timeline.clear();
      _taskStart = null;
      _taskEnd = null;
      _agentState = AgentTaskState.idle;
      _agentError = null;
      _restoreActivity(chosen.activity);
    });
    _scrollDown();
  }

  /// One-tap retry of the last agent task after a failure or stop.
  void _retryLast() {
    final text = _lastAgentRequest;
    if (text == null || _busy) return;
    if (!_agentMode) setState(() => _agentMode = true);
    _agentSend(text, resume: _resumeContext != null);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    if (_agentMode) return _agentSend(text);
    final image = _pendingImage;
    final attachmentName = _pendingAttachmentName ?? _pendingImageName;
    final attachmentKind = _pendingAttachmentKind ?? (image == null ? null : 'image');
    final attachmentContent = _pendingAttachment;
    setState(() {
      _messages.add(ChatMessage(
        role: 'user',
        content: text,
        imageDataUrl: image,
        hasImage: image != null,
        attachmentName: attachmentName,
        attachmentKind: attachmentKind,
      ));
      _busy = true;
      _clearAttachmentState();
    });
    _input.clear();
    // Persist immediately (same mid-run-back-out protection as agent mode).
    unawaited(_saveSession());

    // Inject attached file content (from Home or the chat paperclip) once.
    var effectiveRequest = text;
    if (attachmentContent != null) {
      final clipped = attachmentContent.length > 12000
          ? '${attachmentContent.substring(0, 12000)}\n… (truncated)'
          : attachmentContent;
      effectiveRequest = 'Attached file "$attachmentName":\n```\n$clipped\n```\n\n$text';
      setState(() {
        _clearAttachmentState();
      });
    }

    try {
      final context = agentService.buildGeneralContext(request: effectiveRequest);
      final history = _messages.length > 10
          ? _messages.sublist(_messages.length - 10)
          : _messages;
      final messages = <ChatMessage>[
        const ChatMessage(role: 'system', content: AgentService.systemPrompt),
        ChatMessage(role: 'user', content: context),
        ...history.map((m) => ChatMessage(
              role: m.role == 'system' ? 'assistant' : m.role,
              content: m.content,
              // Keep attached images so the vision format actually reaches
              // the API (ApiClient sends image_url parts for these).
              imageDataUrl: m.imageDataUrl,
            )),
      ];

      final settings = await settingsStore.load();
      String reply;
      if (settings.streaming) {
        final buf = StringBuffer();
        // Provider router: streams through the highest-priority capable
        // provider and falls back down the configured chain.
        await for (final piece in aiRouter.streamWithFallback(messages)) {
          buf.write(piece);
          if (!mounted) return; // user left the screen — stop stream updates
          setState(() => _streamBuf = buf.toString());
        }
        reply = buf.toString();
        if (!mounted) return;
        setState(() => _streamBuf = null);
      } else {
        reply = await aiRouter.chatWithFallback(messages);
      }
      if (!mounted) return;

      final parsed = AgentService.parseReply(reply);
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: parsed.explanation.isEmpty ? '(model reply contained only change blocks)' : parsed.explanation));
        _pending = parsed.changes;
      });
      _scrollDown();
      await _saveSession();
    } on ApiException catch (e) {
      // Keep the text in the composer so one tap on send retries the
      // request (conversation-level retry).
      if (mounted) _input.text = text;
      _push('system', '${e.message}\nTap send to retry.', isError: true);
    } on ProjectException catch (e) {
      if (mounted) _input.text = text;
      _push('system', '${e.message}\nTap send to retry.', isError: true);
    } catch (e) {
      if (mounted) _input.text = text;
      _push('system', 'Unexpected error: $e\nTap send to retry.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollDown();
    }
  }

  void _push(String role, String content, {bool isError = false}) {
    if (!mounted) return; // async caller may outlive the screen
    setState(() => _messages.add(ChatMessage(role: role, content: content, isError: isError)));
    _scrollDown();
  }

  // ==================================================================
  // Autonomous agent flow
  // ==================================================================

  Future<void> _agentSend(String text, {bool resume = false}) async {
    final image = _pendingImage;
    final attachmentName = _pendingAttachmentName ?? _pendingImageName;
    final attachmentKind = _pendingAttachmentKind ?? (image == null ? null : 'image');
    final attachmentContent = _pendingAttachment;
    setState(() {
      if (!resume) {
        _messages.add(ChatMessage(
          role: 'user',
          content: text,
          imageDataUrl: image,
          hasImage: image != null,
          attachmentName: attachmentName,
          attachmentKind: attachmentKind,
        ));
      }
      _busy = true;
      _agentState = AgentTaskState.running;
      _agentError = null;
      _lastAgentRequest = text;
      if (!resume) {
        _taskId = DateTime.now().microsecondsSinceEpoch.toString();
        _timeline.clear();
        _resumeContext = null;
        _taskStart = DateTime.now(); // real start — drives the elapsed label
      }
      _taskEnd = null;
      _recentSessions = const [];
      if (!resume) _clearAttachmentState();
    });
    _input.clear();
    // Persist the task text IMMEDIATELY — backing out mid-run must not
    // erase it (the final save only happens if the run completes on-screen).
    unawaited(_saveSession());

    var effectiveRequest = resume ? _resumePrompt() : text;
    if (attachmentContent != null) {
      final clipped = attachmentContent.length > 12000
          ? '${attachmentContent.substring(0, 12000)}\n… (truncated)'
          : attachmentContent;
      effectiveRequest = '$text\n\n(Attached file "$attachmentName":\n$clipped\n)';
      setState(() {
        _clearAttachmentState();
      });
    }

    final loop = AgentLoop(
      // Provider router: automatic/manual selection + bounded fallback
      // across every configured provider/key.
      backend: aiRouter,
      registry: ToolRegistry(
        projects: projectService,
        github: githubService,
        repoStore: githubProjectStore,
      ),
      projects: projectService,
      mode: _approvalMode,
      maxRounds: 10,
    );
    _activeLoop = loop;

    _eventSub = loop.events.listen((e) {
      if (!mounted) return;
      setState(() {
        if (e is StepStarted) {
          _timeline.add(StepEntry(e.step));
        } else if (e is StepFinished) {
          // Replace the in-flight entry with the finished step object.
          final i = _timeline
              .indexWhere((en) => en is StepEntry && en.step.id == e.step.id);
          if (i >= 0) {
            _timeline[i] = StepEntry(e.step);
          } else {
            _timeline.add(StepEntry(e.step));
          }
          _updateResumeContext();
          // Continuous persistence: every REAL finished step is saved at
          // once, so navigating away can never lose the activity history.
          unawaited(_saveSession());
        }
      });
      _scrollDown();
    });
    _thoughtSub = loop.thoughts.listen((t) {
      if (!mounted) return;
      setState(() {
        // Append as a reasoning card, deduplicating identical repeats.
        final last = _timeline.isEmpty ? null : _timeline.last;
        if (last is ReasoningEntry && last.text == t.text) return;
        _timeline.add(ReasoningEntry(t.text));
      });
    });
    _approvalSub = loop.approvals.listen((a) async {
      final approved = await _askApproval(a.tool, a.args);
      loop.resolveApproval(a.tool, _approvalKey(a.tool, a.args), approved);
    });

    // The outcome stream is the SINGLE source of truth for the final state.
    // It fires exactly once (completed / failed / cancelled); the completer
    // below makes _agentSend wait for it even when loop.run() resolves
    // first, so no path can leave the UI in RUNNING.
    final outcomeDone = Completer<void>();
    _outcomeSub = loop.outcome.listen((o) {
      if (!outcomeDone.isCompleted) outcomeDone.complete();
      if (!mounted) return;
      setState(() {
        _agentState = o.state;
        if (o.state == AgentTaskState.failed) _agentError = o.message;
        _taskEnd = DateTime.now(); // real end — freezes the elapsed label
        _updateResumeContext(
          interruptedAction: o.state == AgentTaskState.failed ? o.message : null,
        );
      });
      if (o.state == AgentTaskState.completed) {
        _push('assistant', o.message);
      } else if (o.state == AgentTaskState.failed) {
        _push('system', '✕ Task failed — ${o.message}', isError: true);
      } else if (o.state == AgentTaskState.cancelled) {
        _push('system', '⏹ Task stopped.');
      }
      _scrollDown();
    });

    try {
      final prior = _messages.length > 10
          ? _messages.sublist(_messages.length - 10)
          : _messages;
      // Belt-and-braces: even if a backend ignored cancellation, this
      // timeout guarantees _agentSend terminates. Each step is bounded by
      // the loop's step watchdog; 30 min covers ~10 worst-case steps.
      await loop.run(
        effectiveRequest,
        priorHistory: prior.sublist(0, prior.length - 1), // exclude this turn
      ).timeout(const Duration(minutes: 30), onTimeout: () => '');
      // Wait for the outcome event so the final state and banner are applied
      // in the same tick; the loop guarantees exactly one outcome.
      await outcomeDone.future.timeout(const Duration(seconds: 2),
          onTimeout: () {
        // Defensive: an outcome should always arrive; if it somehow didn't,
        // force a terminal state so the UI can never stay RUNNING/STOPPING.
        if (mounted && !_agentState.isFinal) {
          setState(() {
            _agentState = _agentState == AgentTaskState.stopping
                ? AgentTaskState.cancelled
                : AgentTaskState.failed;
            if (_agentState == AgentTaskState.failed) {
              _agentError = 'The agent finished without reporting a result.';
            }
          });
        }
      });
      await _saveSession();
    } on StateError {
      // loop.run() re-entry guard — cannot happen from this UI path.
      _push('system', 'An agent task is already running.', isError: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _agentState = AgentTaskState.failed;
          _agentError = '$e';
          _taskEnd = DateTime.now();
        });
        _push('system', '✕ Task failed — $e', isError: true);
      }
    } finally {
      _eventSub?.cancel();
      _thoughtSub?.cancel();
      _approvalSub?.cancel();
      _outcomeSub?.cancel();
      _eventSub = null;
      _thoughtSub = null;
      _approvalSub = null;
      _outcomeSub = null;
      _activeLoop = null;
      if (mounted) {
        setState(() {
          _busy = false;
          // Absolute last resort: no path may leave a non-final state here.
          if (!_agentState.isFinal) {
            _agentState = _agentState == AgentTaskState.stopping
                ? AgentTaskState.cancelled
                : AgentTaskState.failed;
          }
        });
      }
      _scrollDown();
    }
  }

  Future<bool> _askApproval(String tool, Map<String, dynamic> args) async {
    if (!mounted) return false;
    final target = (args['path'] ?? args['name'] ?? args['command'] ?? '') as String;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface2,
        title: Text('Allow $tool?', style: const TextStyle(fontSize: 17)),
        content: Text(
          'The agent wants to run "$tool" on:\n$target',
          style: const TextStyle(color: AppTheme.muted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _cancelAgent() {
    final loop = _activeLoop;
    if (loop == null) return;
    // Immediate UI feedback: STOPPING disables Stop and shows the banner.
    if (mounted) setState(() => _agentState = AgentTaskState.stopping);
    loop.cancel();
    // The loop aborts its in-flight HTTP / subprocess synchronously; give
    // it one event-loop turn to finalize, then force CANCELLED in the UI
    // if the acknowledgment hasn't arrived (defensive — should not happen).
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted || _agentState.isFinal) return;
      if (_agentState == AgentTaskState.stopping) {
        setState(() => _agentState = AgentTaskState.cancelled);
        _push('system', '⏹ Task stopped.');
      }
    });
  }

  void _cycleApprovalMode() {
    setState(() {
      _approvalMode = switch (_approvalMode) {
        AgentMode.auto => AgentMode.askBeforeChanges,
        AgentMode.askBeforeChanges => AgentMode.planOnly,
        AgentMode.planOnly => AgentMode.auto,
      };
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (_approvalMode) {
        AgentMode.auto => 'Agent mode: AUTO — edits and commits run without asking.',
        AgentMode.askBeforeChanges => 'Agent mode: ASK — every file change needs your approval.',
        AgentMode.planOnly => 'Agent mode: PLAN ONLY — analysis without modifications.',
      }),
      duration: const Duration(seconds: 2),
    ));
  }

  String get _modeLabel => switch (_approvalMode) {
        AgentMode.auto => 'AUTO',
        AgentMode.askBeforeChanges => 'ASK',
        AgentMode.planOnly => 'PLAN',
      };

  void _scrollDown() {
    // Do not interrupt manual scrolling or an older-message view. Image
    // decoding and streaming updates are ordinary list updates, not scroll
    // targets; only follow new content when already near the bottom.
    if (_manualScrollActive || !_userNearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_manualScrollActive || !_userNearBottom || !_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<void> _openDiff(int index) async {
    final change = _pending[index];
    final before = change.isNew ? '' : (projectService.readFile(change.path) ?? '');
    final diff = change.kind == 'delete'
        ? [for (final l in before.split('\n')) DiffLine('del', l)]
        : projectService.diffLines(before, change.after);
    final approved = await Navigator.pushNamed(context, '/diff',
        arguments: {'path': change.path, 'kind': change.kind, 'diff': diff}) as bool?;
    if (approved == true) {
      final full = ProposedChange(
          kind: change.kind, path: change.path, before: before, after: change.after, diff: diff, isNew: change.isNew);
      agentService.applyChange(full);
      setState(() => _pending.removeAt(index));
      _push('system', 'Applied ${change.kind} to ${change.path}. Undo it with the ↺ button above.');
    } else {
      _push('system', 'Change to ${change.path} rejected — nothing was modified.');
    }
  }

  /// Export the open project and hand the ZIP to the Android share sheet
  /// (user picks Save to Files / Drive / Send to…).
  Future<void> _downloadZip() async {
    if (projectService.projectName == null) return;
    _push('system', 'Packing ${projectService.projectName}…');
    try {
      final path = await projectService.exportZip();
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(path)],
        subject: '${projectService.projectName} — CodeFexa export',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
      _push('system', '✓ Project packed — choose where to save it in the share sheet.');
    } catch (e) {
      _push('system', 'Could not create the ZIP: $e', isError: true);
    }
  }

  Future<void> _publishToGitHub() async {
    final repo = await githubProjectStore.load();
    if (repo == null) {
      _push('system', 'Connect and import a GitHub repository first from Integrations → GitHub.', isError: true);
      return;
    }
    try {
      final message = await githubService.publishChanges(repo, agentService.history);
      _push('system', message);
    } on GitHubException catch (e) {
      _push('system', e.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_agentMode ? 'Project Chat' : 'Chat'), actions: [
        IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: 'Chats (history)', onPressed: _openChatHistory),
        IconButton(icon: const Icon(Icons.add_comment_outlined), tooltip: 'New chat', onPressed: _busy ? null : _newChat),
        if (_agentMode && projectService.projectName != null)
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download project as ZIP',
            onPressed: _downloadZip,
          ),
        IconButton(icon: const Icon(Icons.cloud_upload), tooltip: 'Publish confirmed changes to GitHub', onPressed: _publishToGitHub),
        IconButton(icon: const Icon(Icons.undo), tooltip: 'Undo latest change', onPressed: () {
          final rec = agentService.undoLast();
          _push('system', rec == null ? 'Nothing to undo.' : 'Undone: ${rec.kind} ${rec.path}');
        }),
        IconButton(icon: const Icon(Icons.cleaning_services), tooltip: 'Clear this chat', onPressed: () => setState(() { _messages.clear(); _pending.clear(); _sessionId = null; })),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            Expanded(
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('Chat'), icon: Icon(Icons.chat_bubble_outline, size: 16)),
                  ButtonSegment<bool>(value: true, label: Text('Project'), icon: Icon(Icons.code, size: 16)),
                ],
                selected: {_agentMode},
                onSelectionChanged: _busy ? null : (selection) => _setProjectMode(selection.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(width: 8),
            Text(_agentMode ? 'Project Mode' : 'Chat Mode',
                style: TextStyle(color: _agentMode ? AppTheme.glowAccent : AppTheme.muted, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is UserScrollNotification) {
                _manualScrollActive = true;
                _userNearBottom = notification.metrics.extentAfter <= 120;
              } else if (notification is ScrollEndNotification) {
                _manualScrollActive = false;
                _userNearBottom = notification.metrics.extentAfter <= 120;
              }
              return false;
            },
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              children: [
              if (_messages.isEmpty)
                Text(!_agentMode
                    ? 'Chat Mode is ready. Ask anything, study a topic, or attach a file to discuss it.\n\nProject files are not used unless you switch to Project Mode.'
                    : 'Project Mode is active. Coding instructions can inspect and modify the open project.\n\nUse Chat Mode for normal questions and study conversations.',
                    style: TextStyle(color: AppTheme.muted)),
              if (_messages.isEmpty && _recentSessions.isNotEmpty)
                _ResumeCard(
                  sessions: _recentSessions,
                  onResume: _resumePrevious,
                  onDismiss: () => setState(() => _recentSessions = const []),
                ),
              for (final m in _messages) _bubble(m),
              if (_timeline.isNotEmpty || _agentState != AgentTaskState.idle)
                AgentActivityPanel(
                  timeline: _timeline,
                  state: _agentState,
                  errorMessage: _agentError,
                  startedAt: _taskStart,
                  endedAt: _taskEnd,
                  onCancel: _agentState == AgentTaskState.running
                      ? _cancelAgent
                      : null,
                  onRetry: (_agentState == AgentTaskState.failed ||
                          _agentState == AgentTaskState.cancelled)
                      ? _retryLast
                      : null,
                  onPreview: _agentState == AgentTaskState.completed
                      ? () => openProjectPreview(context)
                      : null,
                ),
              if (_streamBuf != null) _bubble(ChatMessage(role: 'assistant', content: '$_streamBuf▍')),
              if (_busy &&
                  _streamBuf == null &&
                  _timeline.isEmpty &&
                  _agentState == AgentTaskState.idle)
                const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
              for (var i = 0; i < _pending.length; i++) _pendingCard(i),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_hasPendingAttachment) ...[
                Row(children: [
                  if (_pendingImage != null)
                    Builder(builder: (context) {
                      final comma = _pendingImage!.indexOf(',');
                      final bytes = comma >= 0 ? base64Decode(_pendingImage!.substring(comma + 1)) : null;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: bytes == null ? const Icon(Icons.image, size: 28, color: AppTheme.glowAccent) : Image.memory(bytes, width: 32, height: 32, fit: BoxFit.cover),
                      );
                    })
                  else
                    Icon(_pendingAttachmentKind == 'pdf' ? Icons.picture_as_pdf : _pendingAttachmentKind == 'code' ? Icons.code : Icons.insert_drive_file, size: 22, color: AppTheme.glowAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_pendingImageName ?? _pendingAttachmentName}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16, color: AppTheme.muted),
                    onPressed: _clearAttachments,
                  ),
                ]),
                const SizedBox(height: 4),
              ],
              Row(children: [
                IconButton(
                  tooltip: 'Attach image, PDF, or file',
                  icon: const Icon(Icons.attach_file, color: AppTheme.muted),
                  onPressed: _busy ? null : _pickAttachment,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(color: AppTheme.text),
                    cursorColor: AppTheme.glowAccent,
                    decoration: InputDecoration(
                      hintText: _agentMode
                          ? (projectService.projectName == null
                              ? 'No project selected — open one from Projects…'
                              : 'Give the agent a task…')
                      : 'Ask or request a change…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.arrow_upward),
                ),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                // Secondary explicit Project toggle.
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _setProjectMode(!_agentMode),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.code,
                          size: 14,
                          color: _agentMode ? AppTheme.glowAccent : AppTheme.muted),
                      const SizedBox(width: 4),
                      Text('Project',
                          style: TextStyle(
                              fontSize: 11,
                              color: _agentMode ? AppTheme.glowAccent : AppTheme.muted,
                              fontWeight: _agentMode ? FontWeight.w600 : FontWeight.w400)),
                    ]),
                  ),
                ),
                // Approval-mode chip (visible in agent mode).
                if (_agentMode)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _busy ? null : _cycleApprovalMode,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(switch (_approvalMode) {
                          AgentMode.auto => Icons.bolt,
                          AgentMode.askBeforeChanges => Icons.help_outline,
                          AgentMode.planOnly => Icons.plagiarism_outlined,
                        }, size: 14, color: AppTheme.muted),
                        const SizedBox(width: 4),
                        Text(_modeLabel,
                            style: const TextStyle(fontSize: 11, color: AppTheme.muted)),
                      ]),
                    ),
                  ),
                // ▶ Live preview of the open project — static web projects
                // render fully on-device; unsupported types say so honestly.
                if (_agentMode && projectService.projectName != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => openProjectPreview(context),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.play_circle_outline,
                            size: 14, color: AppTheme.muted),
                        SizedBox(width: 4),
                        Text('Preview',
                            style: TextStyle(
                                fontSize: 11, color: AppTheme.muted)),
                      ]),
                    ),
                  ),
                const Spacer(),
                Text(
                  !_agentMode || projectService.projectName == null
                      ? 'no project'
                      : '${projectService.projectName}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 10.5),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: isUser ? AppTheme.accent.withOpacity(.25) : (m.isError ? AppTheme.err.withOpacity(.15) : AppTheme.surface2),
          border: Border.all(color: m.isError ? AppTheme.err : AppTheme.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (m.hasImage && m.imageDataUrl != null) ...[
            Builder(builder: (context) {
              // Data URL: data:image/png;base64,<payload>
              final comma = m.imageDataUrl!.indexOf(',');
              final bytes = comma >= 0 && comma < m.imageDataUrl!.length - 1
                  ? base64Decode(m.imageDataUrl!.substring(comma + 1))
                  : null;
              if (bytes == null) return const SizedBox.shrink();
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  bytes,
                  width: 220,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              );
            }),
            const SizedBox(height: 8),
          ] else if (m.hasImage)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.image, size: 14, color: AppTheme.muted),
                SizedBox(width: 4),
                Text('Image sent (not shown after restart)',
                    style: TextStyle(color: AppTheme.muted, fontSize: 11)),
              ]),
            ),
          if (isUser)
            Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m.attachmentName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(m.attachmentKind == 'pdf' ? Icons.picture_as_pdf : m.attachmentKind == 'image' ? Icons.image : Icons.insert_drive_file, size: 14, color: AppTheme.glowAccent),
                    const SizedBox(width: 5),
                    Flexible(child: Text(m.attachmentName!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.glowAccent, fontSize: 12))),
                  ]),
                ),
              _ExpandableUserMessage(
                content: m.content,
                color: m.isError ? AppTheme.err : AppTheme.text,
              ),
            ]))
          else
            _AssistantBody(content: m.content, isError: m.isError),
        ]),
      ),
    );
  }

  Widget _pendingCard(int i) {
    final c = _pending[i];
    return Card(
      color: AppTheme.warn.withOpacity(.12),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(c.kind == 'write' ? Icons.edit : Icons.delete, color: AppTheme.warn),
        title: Text('${c.kind == 'write' ? 'Modify' : 'Delete'} ${c.path}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(c.isNew ? 'New file' : 'Existing file — review the diff before applying', style: TextStyle(color: AppTheme.muted)),
        trailing: FilledButton(child: const Text('Review diff'), onPressed: () => _openDiff(i)),
      ),
    );
  }
}

/// Visual-only collapsing for long user messages. The complete [content]
/// remains in the ChatMessage and is still sent to/persisted by the model;
/// only this presentation starts collapsed when reopened.
class _ExpandableUserMessage extends StatefulWidget {
  final String content;
  final Color color;

  const _ExpandableUserMessage({required this.content, required this.color});

  @override
  State<_ExpandableUserMessage> createState() => _ExpandableUserMessageState();
}

class _ExpandableUserMessageState extends State<_ExpandableUserMessage> {
  static const _maxCollapsedLines = 5;
  static const _longMessageCharacters = 900;
  bool _expanded = false;

  bool get _isLong {
    final lines = '\n'.allMatches(widget.content).length + 1;
    return lines > _maxCollapsedLines || widget.content.length > _longMessageCharacters;
  }

  @override
  Widget build(BuildContext context) {
    final text = SelectableText(
      widget.content,
      maxLines: !_isLong || _expanded ? null : _maxCollapsedLines,
      style: TextStyle(color: widget.color),
    );
    if (!_isLong) return text;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      text,
      const SizedBox(height: 4),
      InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Text(
            _expanded ? 'Show less' : 'Show more',
            style: const TextStyle(
              color: AppTheme.glowAccent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Assistant message body with markdown-lite rendering: fenced ``` blocks
/// become monospace cards with a copy button; the rest renders as text.
class _AssistantBody extends StatelessWidget {
  final String content;
  final bool isError;

  const _AssistantBody({required this.content, required this.isError});

  @override
  Widget build(BuildContext context) {
    final blocks = <({String? lang, String code, String before})>[];
    final re = RegExp(r'```(\w*)\n([\s\S]*?)```');
    var cursor = 0;
    for (final m in re.allMatches(content)) {
      blocks.add((
        lang: m.group(1)!.isEmpty ? null : m.group(1),
        code: (m.group(2) ?? '').replaceFirst(RegExp(r'\n$'), ''),
        before: content.substring(cursor, m.start),
      ));
      cursor = m.end;
    }
    final rest = content.substring(cursor);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (blocks.isEmpty)
        _MarkdownText(text: content, color: isError ? AppTheme.err : AppTheme.text)
      else ...[
        for (final b in blocks) ...[
          if (b.before.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _MarkdownText(text: b.before.trim(), color: isError ? AppTheme.err : AppTheme.text),
            ),
          _CodeBlock(lang: b.lang, code: b.code),
        ],
        if (rest.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _MarkdownText(text: rest.trim(), color: isError ? AppTheme.err : AppTheme.text),
          ),
      ],
    ]);
  }
}

/// Markdown-lite renderer for assistant prose: headings (#…), bullets
/// ("* " or "- "), numbered items, **bold**, *italic*, and `inline code`.
/// AI models emit Markdown heavily; rendering it keeps replies readable
/// instead of showing raw ### and ** markers.
class _MarkdownText extends StatelessWidget {
  final String text;
  final Color color;

  const _MarkdownText({required this.text, required this.color});

  static final _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _bulletRe = RegExp(r'^\s*[-*•]\s+(.*)$');
  static final _numberedRe = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');
  static final _inlineRe = RegExp(r'(\*\*([^*]+)\*\*)|(\*([^*]+)\*)|(`([^`]+)`)');

  TextSpan _inline(String line) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inlineRe.allMatches(line)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: line.substring(cursor, m.start)));
      }
      if (m.group(2) != null) {
        spans.add(TextSpan(
            text: m.group(2), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
            text: m.group(4), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else if (m.group(6) != null) {
        spans.add(TextSpan(
          text: m.group(6),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            color: AppTheme.glowAccent,
            backgroundColor: AppTheme.bg,
          ),
        ));
      }
      cursor = m.end;
    }
    if (cursor < line.length) spans.add(TextSpan(text: line.substring(cursor)));
    return TextSpan(style: TextStyle(color: color), children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    for (final line in text.split('\n')) {
      final heading = _headingRe.firstMatch(line);
      final bullet = _bulletRe.firstMatch(line);
      final numbered = _numberedRe.firstMatch(line);

      if (heading != null) {
        final level = heading.group(1)!.length;
        widgets.add(Padding(
          padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 10, bottom: 2),
          child: SelectableText.rich(
            _inline(heading.group(2) ?? ''),
            style: TextStyle(
              color: color,
              fontSize: level <= 2 ? 16 : 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ));
      } else if (bullet != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(width: 10),
            Text('•  ', style: TextStyle(color: color)),
            Expanded(
              child: SelectableText.rich(
                _inline(bullet.group(1) ?? ''),
                style: TextStyle(color: color, fontSize: 14, height: 1.45),
              ),
            ),
          ]),
        ));
      } else if (numbered != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(width: 6),
            SizedBox(
              width: 22,
              child: Text('${numbered.group(1)}.',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: SelectableText.rich(
                _inline(numbered.group(2) ?? ''),
                style: TextStyle(color: color, fontSize: 14, height: 1.45),
              ),
            ),
          ]),
        ));
      } else if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
      } else {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: SelectableText.rich(
            _inline(line),
            style: TextStyle(color: color, fontSize: 14, height: 1.45),
          ),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
  }
}

/// Copyable monospace code card inside an assistant reply.
class _CodeBlock extends StatelessWidget {
  final String? lang;
  final String code;

  const _CodeBlock({required this.lang, required this.code});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: 10),
          Text(lang ?? 'code', style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
          const Spacer(),
          if (lang != null && const ['html', 'htm'].contains(lang!.toLowerCase())) ...[
            // When a project is open, offer the FULL project preview (the
            // agent's written files, with its CSS/JS/assets) first — the
            // inline snippet preview stays available as a second button.
            if (projectService.rootPath != null) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Preview project (index.html)',
                icon: const Icon(Icons.open_in_new, size: 16, color: AppTheme.glowAccent),
                onPressed: () {
                  final candidates = [
                    'index.html',
                    'src/index.html',
                    'public/index.html',
                    'pages/index.html',
                  ];
                  String? entry;
                  for (final c in candidates) {
                    if (projectService.readFile(c) != null) {
                      entry = c;
                      break;
                    }
                  }
                  if (entry != null) {
                    openHtmlPreview(context, path: entry);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('No index.html found in the project — open a page from the Explorer first.'),
                        duration: Duration(seconds: 2)));
                  }
                },
              ),
            ],
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Preview this code block',
              icon: const Icon(Icons.play_arrow, size: 17, color: AppTheme.ok),
              onPressed: () => openHtmlPreview(context, rawHtml: code),
            ),
          ],
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy code',
            icon: const Icon(Icons.copy, size: 15, color: AppTheme.muted),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Code copied'), duration: Duration(seconds: 1)));
              }
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: _SyntaxHighlight(code: code, language: lang),
        ),
      ]),
    );
  }
}

/// One rule set per language: compiled regex + the ordered kind of each
/// capture group (group i+1 corresponds to kinds[i]).
class _LangRules {
  final RegExp re;
  final List<String> kinds;
  const _LangRules(this.re, this.kinds);
}

/// ChatGPT-style syntax highlighting for code blocks: a regex tokenizer with
/// per-language rules (comment style, HTML tags) and a One Dark-inspired
/// palette — keywords purple, types yellow, strings green, numbers orange,
/// functions blue, comments muted italic.
class _SyntaxHighlight extends StatelessWidget {
  final String code;
  final String? language;

  const _SyntaxHighlight({required this.code, required this.language});

  static const _keywordColor = Color(0xFFC678DD);
  static const _typeColor = Color(0xFFE5C07B);
  static const _stringColor = Color(0xFF98C379);
  static const _numberColor = Color(0xFFD19A66);
  static const _commentColor = Color(0xFF8B949E);
  static const _funcColor = Color(0xFF61AFEF);
  static const _tagColor = Color(0xFFE06C75);

  /// Union of common keywords across Dart/JS/TS/Java/Kotlin/Go/Python/C/C#.
  /// A stray keyword from another language is visually harmless.
  static const _keywords = [
    'abstract','as','assert','async','await','base','break','case','catch',
    'class','const','continue','covariant','default','deferred','do','dynamic',
    'else','enum','export','extends','extension','external','factory','false',
    'final','finally','for','function','get','if','implements','import','in',
    'inline','interface','is','late','library','let','mixin','new','null','on',
    'operator','override','part','private','protected','public','required',
    'rethrow','return','sealed','set','show','static','super','switch','sync',
    'this','throw','true','try','typedef','typeof','val','var','void','when',
    'where','while','with','yield','def','elif','except','lambda','pass',
    'raise','del','global','nonlocal','struct','impl','fn','match','use','pub',
    'package','end','then','elsif','unless','nil','echo','foreach','elseif',
    'include','namespace','using','template','typename','and','or','not',
  ];

  static final _cache = <String, _LangRules>{};

  static _LangRules _rulesFor(String? lang) {
    final key = (lang ?? '').trim().toLowerCase();
    return _cache.putIfAbsent(key, () => _build(key));
  }

  static _LangRules _build(String l) {
    const hashLangs = {
      'python','py','sh','bash','zsh','shell','yaml','yml','ruby','rb','toml',
      'perl','r','makefile','dockerfile','ini','properties','conf','ps1'
    };
    const markupLangs = {'html','xml','svg','vue'};
    final stringRule = [
      r'"""[\s\S]*?"""',
      r"'''[\s\S]*?'''",
      r'"(?:\\.|[^"\\\n])*"',
      r"'(?:\\.|[^'\\\n])*'",
    ].join('|');
    final commentRule = markupLangs.contains(l)
        ? r'<!--[\s\S]*?-->'
        : hashLangs.contains(l)
            ? r'#[^\n]*'
            : r'//[^\n]*|/\*[\s\S]*?\*/';
    final kinds = <String, String>{
      'comment': commentRule,
      'string': stringRule,
      'number':
          r'\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b',
      'annot': r'@[A-Za-z_]\w*',
      'keyword': '\\b(?:${_keywords.join('|')})\\b',
      'type': r'\b[A-Z][A-Za-z0-9_]*\b',
      'func': r'\b[a-z_]\w*(?=\s*\()',
      if (markupLangs.contains(l)) 'tag': r'</?[a-zA-Z][\w-]*',
    };
    final names = kinds.keys.toList();
    final re = RegExp(kinds.values.map((p) => '($p)').join('|'));
    return _LangRules(re, names);
  }

  TextSpan _span() {
    final rules = _rulesFor(language);
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in rules.re.allMatches(code)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: code.substring(cursor, m.start)));
      }
      String? kind;
      for (var i = 0; i < rules.kinds.length; i++) {
        if (m.group(i + 1) != null) {
          kind = rules.kinds[i];
          break;
        }
      }
      final style = switch (kind) {
        'comment' => const TextStyle(
            color: _commentColor, fontStyle: FontStyle.italic),
        'string' => const TextStyle(color: _stringColor),
        'number' => const TextStyle(color: _numberColor),
        'annot' => const TextStyle(color: _typeColor),
        'keyword' => const TextStyle(color: _keywordColor),
        'type' => const TextStyle(color: _typeColor),
        'func' => const TextStyle(color: _funcColor),
        'tag' => const TextStyle(color: _tagColor),
        _ => null,
      };
      spans.add(TextSpan(text: m[0], style: style));
      cursor = m.end;
    }
    if (cursor < code.length) {
      spans.add(TextSpan(text: code.substring(cursor)));
    }
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      _span(),
      style: const TextStyle(
          fontFamily: 'monospace', fontSize: 12, height: 1.5, color: AppTheme.text),
    );
  }
}

/// On a fresh chat (entered from Home), offers to reopen the previous
/// conversation instead of making the user dig through the history sheet —
/// the standard chatbot continuity pattern.
class _ResumeCard extends StatelessWidget {
  final List<ChatSession> sessions;
  final VoidCallback onResume;
  final VoidCallback onDismiss;

  const _ResumeCard({
    required this.sessions,
    required this.onResume,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final s = sessions.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history, size: 15, color: AppTheme.glowAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Continue "${s.title}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 15, color: AppTheme.muted),
            onPressed: onDismiss,
            tooltip: 'Dismiss',
          ),
        ]),
        Text(
          '${s.messages.length} messages · ${s.time.toLocal().month}/${s.time.toLocal().day}',
          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.surface,
              foregroundColor: AppTheme.glowAccent,
              side: const BorderSide(color: AppTheme.border),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: onResume,
            icon: const Icon(Icons.chat_bubble_outline, size: 14),
            label: const Text('Continue conversation'),
          ),
        ),
      ]),
    );
  }
}
