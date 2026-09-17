import 'package:flutter/material.dart';

import '../agent_service.dart';
import '../api_client.dart';
import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../theme.dart';

/// AI Coding Chat screen: command bar + streaming chat + confirm/diff flow.
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
  String? _streamBuf;

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    if (projectService.projectName == null) {
      _push('system', 'Open or import a project first (Home → Import Project).', isError: true);
      return;
    }
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _busy = true;
    });
    _input.clear();

    try {
      final context = agentService.buildContext(request: text);
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
          setState(() => _streamBuf = buf.toString());
        }
        reply = buf.toString();
        setState(() => _streamBuf = null);
      } else {
        reply = await apiClient.chat(messages);
      }

      final parsed = AgentService.parseReply(reply);
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: parsed.explanation.isEmpty ? '(model reply contained only change blocks)' : parsed.explanation));
        _pending = parsed.changes;
      });
      _scrollDown();
    } on ApiException catch (e) {
      _push('system', e.message, isError: true);
    } on ProjectException catch (e) {
      _push('system', e.message, isError: true);
    } catch (e) {
      _push('system', 'Unexpected error: $e', isError: true);
    } finally {
      setState(() => _busy = false);
      _scrollDown();
    }
  }

  void _push(String role, String content, {bool isError = false}) {
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
      _push('system', 'Applied ${change.kind} to ${change.path}. Undo is available on the Home screen.');
    } else {
      _push('system', 'Change to ${change.path} rejected — nothing was modified.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Chat · ${projectService.projectName ?? 'no project'}'), actions: [
        IconButton(icon: const Icon(Icons.undo), tooltip: 'Undo latest change', onPressed: () {
          final rec = agentService.undoLast();
          _push('system', rec == null ? 'Nothing to undo.' : 'Undone: ${rec.kind} ${rec.path}');
        }),
        IconButton(icon: const Icon(Icons.cleaning_services), tooltip: 'Clear chat', onPressed: () => setState(() { _messages.clear(); _pending.clear(); })),
      ]),
      body: Column(children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            children: [
              if (_messages.isEmpty)
                Text('Ask things like:\n• Explain this project\n• Where is the API configured?\n• Fix the Flutter build error\n• Create a new screen',
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
            child: Row(children: [
              Expanded(child: TextField(controller: _input, minLines: 1, maxLines: 4, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Ask or request a change…'))),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
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
        child: SelectableText(m.content, style: TextStyle(color: m.isError ? AppTheme.err : AppTheme.text)),
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
