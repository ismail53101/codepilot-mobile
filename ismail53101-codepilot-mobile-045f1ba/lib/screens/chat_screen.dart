import 'package:flutter/material.dart';

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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Applied ${change.kind} to ${change.path}')));
      }
    }
  }

  void _openPreview(String html) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PreviewScreen(rawHtml: html)),
    );
  }

  List<String> _extractHtmlBlocks(String text) {
    final blocks = <String>[];
    // Match 