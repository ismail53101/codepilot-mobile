import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_service.dart';
import '../api_client.dart';
import '../github_service.dart';
import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../stores.dart';
import '../theme.dart';

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
  final List<ChatMessage> _messages = [];
  List<ProposedChange> _pending = [];
  bool _busy = false;
  bool _restored = false;
  String? _streamBuf;
  String? _sessionId;
  // Content of a file attached on Home (route argument), injected once.
  String? _pendingAttachment;
  String? _pendingAttachmentName;
  // Image attached in-chat (base64 data URL) — sent via vision format.
  String? _pendingImage;
  String? _pendingImageName;

  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

  /// Pick an image/code file mid-chat. Images go to the model as vision
  /// input; text files are inlined; ZIPs import as a project.
  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      final file = result?.files.single;
      if (file == null) return;
      final ext = file.extension?.toLowerCase() ?? '';

      if (ext == 'zip') {
        if (file.path == null) return;
        try {
          final message = await projectService.importZip(file.path!);
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not import ZIP: $e')));
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
        });
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
      });
    } catch (e) {
      _push('system', 'File picker unavailable: $e', isError: true);
    }
  }

  void _clearAttachments() {
    setState(() {
      _pendingAttachment = null;
      _pendingAttachmentName = null;
      _pendingImage = null;
      _pendingImageName = null;
    });
  }

  bool get _hasPendingAttachment =>
      _pendingAttachment != null || _pendingImage != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initFromRoute());
  }

  Future<void> _initFromRoute() async {
    if (!mounted) return;
    final arg = ModalRoute.of(context)?.settings.arguments;

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
    if (!_restored) {
      final sessions = await chatSessionStore.load();
      if (!mounted) return;
      setState(() {
        _restored = true;
        if (sessions.isNotEmpty) {
          _sessionId = sessions.first.id;
          _messages.addAll(sessions.first.messages);
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

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;
    await chatSessionStore.save(
      existingId: _sessionId,
      title: _sessionTitle,
      messages: List.of(_messages),
    );
  }

  Future<void> _openChatHistory() async {
    final sessions = await chatSessionStore.load();
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
    });
    _push('system', 'New chat. The previous conversation is saved under Chats.');
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final image = _pendingImage;
    setState(() {
      _messages.add(ChatMessage(
        role: 'user',
        content: text,
        imageDataUrl: image,
        hasImage: image != null,
      ));
      _busy = true;
      _pendingImage = null;
      _pendingImageName = null;
    });
    _input.clear();

    // Inject attached file content (from Home or the chat paperclip) once.
    var effectiveRequest = text;
    final attachmentContent = _pendingAttachment;
    final attachmentName = _pendingAttachmentName;
    if (attachmentContent != null) {
      final clipped = attachmentContent.length > 12000
          ? '${attachmentContent.substring(0, 12000)}\n… (truncated)'
          : attachmentContent;
      effectiveRequest = 'Attached file "$attachmentName":\n```\n$clipped\n```\n\n$text';
      setState(() {
        _pendingAttachment = null;
        _pendingAttachmentName = null;
      });
    }

    try {
      final context = projectService.projectName == null
          ? agentService.buildGeneralContext(request: effectiveRequest)
          : agentService.buildContext(request: effectiveRequest);
      final history = _messages.length > 10
          ? _messages.sublist(_messages.length - 10)
          : _messages;
      final messages = <ChatMessage>[
        const ChatMessage(role: 'system', content: AgentService.systemPrompt),
        ChatMessage(role: 'user', content: context),
        ...history.map((m) => ChatMessage(role: m.role == 'system' ? 'assistant' : m.role, content: m.content)),
      ];

      final settings = await settingsStore.load();
      String reply;
      if (settings.streaming) {
        final buf = StringBuffer();
        await for (final piece in apiClient.chatStream(messages)) {
          buf.write(piece);
          if (!mounted) return; // user left the screen — stop stream updates
          setState(() => _streamBuf = buf.toString());
        }
        reply = buf.toString();
        if (!mounted) return;
        setState(() => _streamBuf = null);
      } else {
        reply = await apiClient.chat(messages);
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
      _push('system', e.message, isError: true);
    } on ProjectException catch (e) {
      _push('system', e.message, isError: true);
    } catch (e) {
      _push('system', 'Unexpected error: $e', isError: true);
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

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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
      appBar: AppBar(title: Text('Chat · ${projectService.projectName ?? 'general'}'), actions: [
        IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: 'Chats (history)', onPressed: _openChatHistory),
        IconButton(icon: const Icon(Icons.add_comment_outlined), tooltip: 'New chat', onPressed: _busy ? null : _newChat),
        IconButton(icon: const Icon(Icons.cloud_upload), tooltip: 'Publish confirmed changes to GitHub', onPressed: _publishToGitHub),
        IconButton(icon: const Icon(Icons.undo), tooltip: 'Undo latest change', onPressed: () {
          final rec = agentService.undoLast();
          _push('system', rec == null ? 'Nothing to undo.' : 'Undone: ${rec.kind} ${rec.path}');
        }),
        IconButton(icon: const Icon(Icons.cleaning_services), tooltip: 'Clear this chat', onPressed: () => setState(() { _messages.clear(); _pending.clear(); _sessionId = null; })),
      ]),
      body: Column(children: [
        if (_pendingAttachmentName != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              const Icon(Icons.attach_file, size: 16, color: AppTheme.glowAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Attached: $_pendingAttachmentName',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16, color: AppTheme.muted),
                onPressed: () => setState(() {
                  _pendingAttachment = null;
                  _pendingAttachmentName = null;
                }),
              ),
            ]),
          ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            children: [
              if (_messages.isEmpty)
                Text(projectService.projectName == null
                    ? 'Ask anything about coding, architecture, APIs, debugging, or how to build your app.\n\nImport a project or connect GitHub when you want CodePilot to inspect and edit files.\n\n📎 Attach images or code files with the paperclip.'
                    : 'Ask things like:\n• Explain this project\n• Where is the API configured?\n• Fix the Flutter build error\n• Create a new screen\n\n📎 Attach images or files with the paperclip.',
                    style: TextStyle(color: AppTheme.muted)),
              for (final m in _messages) _bubble(m),
              if (_streamBuf != null) _bubble(ChatMessage(role: 'assistant', content: '$_streamBuf▍')),
              if (_busy && _streamBuf == null) const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
              for (var i = 0; i < _pending.length; i++) _pendingCard(i),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_hasPendingAttachment) ...[
                Row(children: [
                  Icon(
                    _pendingImage != null ? Icons.image : Icons.description,
                    size: 16,
                    color: AppTheme.glowAccent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Attached: ${_pendingImageName ?? _pendingAttachmentName}',
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
                  tooltip: 'Attach image or file',
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
                    decoration: const InputDecoration(
                      hintText: 'Ask or request a change…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.arrow_upward),
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
            Flexible(child: SelectableText(m.content, style: TextStyle(color: m.isError ? AppTheme.err : AppTheme.text)))
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
        SelectableText(content, style: TextStyle(color: isError ? AppTheme.err : AppTheme.text))
      else ...[
        for (final b in blocks) ...[
          if (b.before.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(b.before.trim(), style: TextStyle(color: isError ? AppTheme.err : AppTheme.text)),
            ),
          _CodeBlock(lang: b.lang, code: b.code),
        ],
        if (rest.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(rest.trim(), style: TextStyle(color: isError ? AppTheme.err : AppTheme.text)),
          ),
      ],
    ]);
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
          child: SelectableText(code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5, color: AppTheme.text)),
        ),
      ]),
    );
  }
}
