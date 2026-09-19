import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../theme.dart';

/// Project Explorer: full file tree, open files, project-wide search entry.
class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key});

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  final _search = TextEditingController();
  List<FileNode> _nodes = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _nodes = projectService.fileTree();
        _error = null;
      });
    } on ProjectException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _openFile(String path) {
    Navigator.pushNamed(context, '/preview', arguments: path);
  }

  void _runSearch() {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    Navigator.pushNamed(context, '/search', arguments: q);
  }

  @override
  Widget build(BuildContext context) {
    final name = projectService.projectName;
    return Scaffold(
      appBar: AppBar(
        title: Text('Explorer · ${name ?? 'no project'}'),
        actions: [
          if (name != null)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Download project as ZIP',
              onPressed: () => Navigator.pushNamed(context, '/export'),
            ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(icon: const Icon(Icons.chat), tooltip: 'AI Chat', onPressed: () => Navigator.pushNamed(context, '/chat')),
        ],
      ),
      body: name == null
          ? _empty(context)
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(children: [
                  Expanded(child: TextField(
                    controller: _search,
                    onSubmitted: (_) => _runSearch(),
                    decoration: const InputDecoration(hintText: 'Search across the whole project…', isDense: true),
                  )),
                  IconButton(icon: const Icon(Icons.search, color: AppTheme.accent), onPressed: _runSearch),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Align(alignment: Alignment.centerLeft, child: Text('${_nodes.length} entries · ${projectService.detectType()}', style: TextStyle(color: AppTheme.muted, fontSize: 12))),
              ),
              const SizedBox(height: 4),
              Expanded(child: _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.err)))
                  : ListView.builder(
                      itemCount: _nodes.length,
                      itemBuilder: (context, i) {
                        final n = _nodes[i];
                        final depth = n.path.split('/').length - 1;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.only(left: 12.0 + depth * 14, right: 12),
                          leading: Icon(n.isDir ? Icons.folder : _iconFor(n.name), size: 20, color: n.isDir ? AppTheme.accent : AppTheme.muted),
                          title: Text(n.name, style: const TextStyle(fontSize: 14)),
                          trailing: n.isDir ? null : Text(_fmtSize(n.size), style: TextStyle(color: AppTheme.muted, fontSize: 11)),
                          onTap: () => n.isDir ? null : _openFile(n.path),
                        );
                      },
                    )),
            ]),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.folder_off, size: 48, color: AppTheme.muted),
      const SizedBox(height: 12),
      const Text('No project is open.'),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: () => Navigator.pushNamed(context, '/import'), icon: const Icon(Icons.upload_file), label: const Text('Import Project')),
    ]));
  }

  static IconData _iconFor(String name) {
    if (name.endsWith('.dart')) return Icons.flutter_dash;
    if (name.endsWith('.json') || name.endsWith('.yaml') || name.endsWith('.yml')) return Icons.settings_suggest;
    if (name.endsWith('.md')) return Icons.description;
    if (name.endsWith('.html')) return Icons.code;
    if (name.endsWith('.css')) return Icons.style;
    if (name.endsWith('.js') || name.endsWith('.ts') || name.endsWith('.jsx') || name.endsWith('.tsx')) return Icons.javascript;
    if (name.endsWith('.py')) return Icons.terminal;
    if (name.endsWith('.java') || name.endsWith('.kt') || name.endsWith('.gradle')) return Icons.android;
    if (name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.svg')) return Icons.image;
    return Icons.insert_drive_file;
  }

  static String _fmtSize(int bytes) =>
      bytes < 1024 ? '$bytes B' : bytes < 1048576 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB';
}
