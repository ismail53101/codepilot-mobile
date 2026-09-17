import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../theme.dart';

/// Search Results screen: full-text search across the open project.
class SearchResultsScreen extends StatefulWidget {
  const SearchResultsScreen({super.key});

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  late TextEditingController _query;
  List<SearchHit> _hits = [];
  bool _searched = false;
  bool _regex = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final arg = ModalRoute.of(context)?.settings.arguments;
    _query = TextEditingController(text: arg is String ? arg : '');
    if (arg is String && arg.isNotEmpty) _run();
  }

  void _run() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    try {
      setState(() {
        _hits = projectService.search(q, regex: _regex);
        _searched = true;
        _error = null;
      });
    } on ProjectException catch (e) {
      setState(() { _error = e.message; _searched = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search Results')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Row(children: [
          Expanded(child: TextField(
            controller: _query,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(hintText: _regex ? 'Regular expression…' : 'Search text…', isDense: true,
              prefixIcon: IconButton(icon: Icon(_regex ? Icons.code : Icons.text_fields, color: _regex ? AppTheme.accent : AppTheme.muted),
                tooltip: 'Toggle regex', onPressed: () => setState(() => _regex = !_regex))),
          )),
          IconButton(icon: const Icon(Icons.search, color: AppTheme.accent), onPressed: _run),
        ])),
        if (projectService.projectName == null)
          Padding(padding: const EdgeInsets.all(12), child: Text('No project open — import one first.', style: TextStyle(color: AppTheme.err)))
        else if (_error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: AppTheme.err)))
        else if (_searched)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Align(alignment: Alignment.centerLeft, child: Text('${_hits.length} matches in ${_hits.map((h) => h.path).toSet().length} files', style: TextStyle(color: AppTheme.muted, fontSize: 12)))),
        Expanded(child: _hits.isEmpty
            ? (_searched ? Center(child: Text('No matches.', style: TextStyle(color: AppTheme.muted))) : const SizedBox.shrink())
            : ListView.builder(
                itemCount: _hits.length,
                itemBuilder: (context, i) {
                  final h = _hits[i];
                  return ListTile(
                    dense: true,
                    title: Text('${h.path}:${h.line}', style: TextStyle(color: AppTheme.accent, fontSize: 12, fontFamily: 'monospace')),
                    subtitle: Text(h.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    onTap: () => Navigator.pushNamed(context, '/preview', arguments: {'path': h.path, 'line': h.line}),
                  );
                },
              )),
      ]),
    );
  }
}
