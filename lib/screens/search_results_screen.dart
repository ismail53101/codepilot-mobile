import 'package:flutter/material.dart';
import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../stores.dart';
import '../theme.dart';

/// General Search searches saved conversations. File search is available only
/// when explicitly requested with {fileSearch: true} from Project Mode.
class SearchResultsScreen extends StatefulWidget {
  const SearchResultsScreen({super.key});
  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  late final TextEditingController _query;
  List<ChatSession> _conversations = [];
  List<SearchHit> _hits = [];
  bool _searched = false;
  bool _fileSearch = false;
  bool _regex = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final arg = ModalRoute.of(context)?.settings.arguments;
    _fileSearch = arg is Map && arg['fileSearch'] == true;
    final initial = arg is String ? arg : arg is Map ? arg['query'] as String? : null;
    _query = TextEditingController(text: initial ?? '');
    if (initial != null && initial.isNotEmpty) _run();
  }

  Future<void> _run() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    try {
      if (_fileSearch) {
        setState(() {
          _hits = projectService.search(q, regex: _regex);
          _searched = true;
          _error = null;
        });
      } else {
        final all = await chatSessionStore.load();
        final needle = q.toLowerCase();
        final matches = all.where((s) {
          if (s.title.toLowerCase().contains(needle)) return true;
          return s.messages.any((m) => m.content.toLowerCase().contains(needle));
        }).toList();
        if (!mounted) return;
        setState(() {
          _conversations = matches;
          _searched = true;
          _error = null;
        });
      }
    } on ProjectException catch (e) {
      if (mounted) setState(() { _error = e.message; _searched = true; });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _fileSearch ? 'Search in Files' : 'Search Conversations';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(children: [
            Expanded(child: TextField(
              controller: _query,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(
                hintText: _fileSearch ? 'Find in project…' : 'Search chats and messages…',
                isDense: true,
                prefixIcon: _fileSearch
                    ? IconButton(
                        icon: Icon(_regex ? Icons.code : Icons.text_fields,
                            color: _regex ? AppTheme.accent : AppTheme.muted),
                        tooltip: 'Toggle regex',
                        onPressed: () => setState(() => _regex = !_regex),
                      )
                    : const Icon(Icons.search, color: AppTheme.muted),
              ),
            )),
            IconButton(icon: const Icon(Icons.search, color: AppTheme.accent), onPressed: _run),
          ]),
        ),
        if (_fileSearch && projectService.projectName == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No project selected — open a project first.', style: TextStyle(color: AppTheme.err)),
          )
        else if (_error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: AppTheme.err)))
        else if (_searched)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _fileSearch
                    ? '${_hits.length} matches in ${_hits.map((h) => h.path).toSet().length} files'
                    : '${_conversations.length} conversations found',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ),
          ),
        Expanded(child: _fileSearch ? _fileResults() : _conversationResults()),
      ]),
    );
  }

  Widget _conversationResults() {
    if (!_searched) return const Center(child: Text('Search your conversations.', style: TextStyle(color: AppTheme.muted)));
    if (_conversations.isEmpty) return const Center(child: Text('No conversations found.', style: TextStyle(color: AppTheme.muted)));
    return ListView.separated(
      itemCount: _conversations.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = _conversations[i];
        return ListTile(
          leading: Icon(s.isProject ? Icons.code : Icons.chat_bubble_outline, color: AppTheme.glowAccent),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${s.time.toLocal().month}/${s.time.toLocal().day} · ${s.messages.length} messages', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          onTap: () => Navigator.pushNamed(context, '/chat', arguments: {'sessionId': s.id}),
        );
      },
    );
  }

  Widget _fileResults() {
    if (!_searched) return const Center(child: Text('Search files in the selected project.', style: TextStyle(color: AppTheme.muted)));
    if (_hits.isEmpty) return const Center(child: Text('No matches.', style: TextStyle(color: AppTheme.muted)));
    return ListView.builder(
      itemCount: _hits.length,
      itemBuilder: (context, i) {
        final h = _hits[i];
        return ListTile(
          dense: true,
          title: Text('${h.path}:${h.line}', style: const TextStyle(color: AppTheme.accent, fontSize: 12, fontFamily: 'monospace')),
          subtitle: Text(h.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          onTap: () => Navigator.pushNamed(context, '/preview', arguments: {'path': h.path, 'line': h.line}),
        );
      },
    );
  }
}
