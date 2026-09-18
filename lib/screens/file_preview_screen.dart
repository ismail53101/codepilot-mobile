import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// File Preview screen: read-only file content with optional line highlight.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({super.key});

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  String _path = '';
  String? _content;
  String? _error;
  final _scroll = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is String) _load(arg);
    if (arg is Map) {
      final map = arg;
      _load(map['path'] as String, highlightLine: map['line'] as int?);
    }
  }

  void _load(String path, {int? highlightLine}) {
    setState(() { _path = path; });
    try {
      final content = projectService.readFile(path);
      if (content == null) {
        setState(() => _error = 'File not found: $path');
        return;
      }
      setState(() { _content = content; _error = null; });
      if (highlightLine != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients) return;
          // ~20px per line, jump near the target line
          final target = ((highlightLine - 6) * 20.0).clamp(0.0, _scroll.position.maxScrollExtent);
          _scroll.jumpTo(target);
        });
      }
    } on ProjectException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_path.split('/').last, style: const TextStyle(fontSize: 16)), actions: [
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy file content',
          onPressed: _content == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: _content!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('File content copied'), duration: Duration(seconds: 1)));
                  }
                },
        ),
        IconButton(
          icon: const Icon(Icons.chat),
          tooltip: 'Ask AI about this file',
          onPressed: _content == null
              ? null
              : () => Navigator.pushNamed(context, '/chat', arguments: {
                    'query': 'Explain the file $_path',
                    'attachmentName': _path,
                    'attachmentContent': _content!,
                  }),
        ),
      ]),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.err)))
          : _content == null
              ? const Center(child: CircularProgressIndicator())
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                    child: Text(_path, style: TextStyle(color: AppTheme.muted, fontSize: 12, fontFamily: 'monospace'))),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text('${_content!.split('\n').length} lines · ${_content!.length} chars', style: TextStyle(color: AppTheme.muted, fontSize: 11))),
                  const SizedBox(height: 4),
                  Expanded(child: Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFF0A0D12), border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
                    child: SingleChildScrollView(controller: _scroll, child: SelectableText(_content!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5))),
                  )),
                ]),
    );
  }
}
