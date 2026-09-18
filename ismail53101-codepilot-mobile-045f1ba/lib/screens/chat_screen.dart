import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_service.dart';
import '../api_client.dart';
import '../main.dart';
import '../models.dart';
import '../theme.dart';
import 'preview_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is Map) {
      final query = arg['query'] as String? ?? '';
      final attachmentName = arg['attachmentName'] as String?;
      final attachmentContent = arg['attachmentContent'] as String?;
      if (query.isNotEmpty || attachmentContent != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _send(query, attachmentName: attachmentName, attachmentContent: attachmentContent);
        });
      }
    }
  }

  Future<void> _send(String text, {String? attachmentName, String? attachmentContent}) async {
    if (text.trim().isEmpty && attachmentContent == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _messages.add(ChatMessage(role: 'user', content: text, attachmentName: attachmentName));
    });
    _controller.clear();
    _scrollToBottom();

    try {
      final reply = await apiClient.chat(
        text,
        projectContext: agentService.buildContext(),
        attachmentName: attachmentName,
        attachmentContent: attachmentContent,
      );
      final parsed = AgentService.parseReply(reply);
      setState(() {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: parsed.explanation,
          changes: parsed.changes,
        ));
      });
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = 'Chat failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _applyChange(ProposedChange change) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apply ${change.kind} to ${change.path}?'),
        content: Text(change.kind == 'write'
            ? 'This will overwrite the file.'
            : 'This will delete the file.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (confirmed == true) {
      agentService.applyChange(change);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Applied ${change.kind} to ${change.path}')));
    }
  }

  void _openPreview(String html) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PreviewScreen(rawHtml: html)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length + (_loading ? 1 : 0) + (_error != null ? 1 : 0),
            itemBuilder: (ctx, i) {
              if (_error != null && i == _messages.length + (_loading ? 1 : 0)) {
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!, style: const TextStyle(color: AppTheme.err)),
                );
              }
              if (_loading && i == _messages.length) {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final msg = _messages[i];
              return _MessageBubble(
                message: msg,
                onApply: _applyChange,
                onPreview: _openPreview,
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(hintText: 'Ask or request a change...'),
                onSubmitted: (v) => _send(v),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _loading ? null : () => _send(_controller.text),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<ProposedChange> onApply;
  final ValueChanged<String> onPreview;

  const _MessageBubble({required this.message, required this.onApply, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? AppTheme.navyPanel : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (message.attachmentName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                const Icon(Icons.attach_file, size: 14),
                const SizedBox(width: 4),
                Text(message.attachmentName!, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          Text(message.content, style: TextStyle(color: isUser ? Colors.white : Colors.black)),
          if (message.changes != null)
            ...message.changes!.map((c) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(
                      child: Text('${c.kind.toUpperCase()} ${c.path}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
                    FilledButton.tonal(
                      onPressed: () => onApply(c),
                      child: const Text('Apply'),
                    ),
                  ]),
                )),
          // Detect HTML code blocks and offer preview
          ..._extractHtmlBlocks(message.content).map((html) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonalIcon(
                  onPressed: () => onPreview(html),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Preview HTML'),
                ),
              )),
        ]),
      ),
    );
  }

  List<String> _extractHtmlBlocks(String text) {
    final blocks = <String>[];
    final regex = RegExp(r'