import 'package:flutter/material.dart';

import '../main.dart';
import '../stores.dart';
import '../theme.dart';

/// Persistent session history with separate Chat and Project views.
class SearchHistoryScreen extends StatefulWidget {
  const SearchHistoryScreen({super.key});

  @override
  State<SearchHistoryScreen> createState() => _SearchHistoryScreenState();
}

class _SearchHistoryScreenState extends State<SearchHistoryScreen> {
  bool _projectHistory = false;
  bool _loading = true;
  String _query = '';
  List<ChatSession> _chatHistory = [];
  List<ChatSession> _projectHistoryItems = [];

  List<ChatSession> get _selectedHistory => _projectHistory ? _projectHistoryItems : _chatHistory;

  List<ChatSession> get _visibleHistory {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _selectedHistory;
    return _selectedHistory.where((s) => s.title.toLowerCase().contains(q) || s.messages.any((m) => m.content.toLowerCase().contains(q))).toList();
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final sessions = await chatSessionStore.load();
    if (!mounted) return;
    setState(() {
      _chatHistory = sessions.where((s) => !s.isProject).toList();
      _projectHistoryItems = sessions.where((s) => s.isProject).toList();
      _loading = false;
    });
  }

  Future<void> _clearSelected() async {
    final label = _projectHistory ? 'project history' : 'chat history';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Clear $label?'),
        content: Text('This will not delete ${_projectHistory ? 'chat' : 'project'} history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) {
      await chatSessionStore.clearMode(_projectHistory);
      await _refresh();
    }
  }

  Future<void> _delete(ChatSession session) async {
    await chatSessionStore.remove(session.id);
    await _refresh();
  }

  void _open(ChatSession session) {
    Navigator.pushNamed(context, '/chat', arguments: {'sessionId': session.id});
  }

  String _dateLabel(DateTime time) {
    final local = time.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    return '$mm/$dd/${local.year} · $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleHistory;
    final title = _projectHistory ? 'Project History' : 'Chat History';
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('Search History'),
        actions: [
          if (!_loading && _selectedHistory.isNotEmpty)
            IconButton(icon: const Icon(Icons.delete_sweep_outlined), tooltip: 'Clear $title', onPressed: _clearSelected),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.chat_bubble_outline, size: 16), label: Text('Chat History')),
                    ButtonSegment(value: true, icon: Icon(Icons.code, size: 16), label: Text('Project History')),
                  ],
                  selected: {_projectHistory},
                  onSelectionChanged: (selection) => setState(() { _projectHistory = selection.first; _query = ''; }),
                  showSelectedIcon: false,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(alignment: Alignment.centerLeft, child: Text(title, style: TextStyle(color: _projectHistory ? AppTheme.glowAccent : AppTheme.accent, fontSize: 17, fontWeight: FontWeight.w700))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: _projectHistory ? 'Search projects...' : 'Search chats...', isDense: true),
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(child: Text(_projectHistory ? 'No project history yet' : 'No chat history yet', style: const TextStyle(color: AppTheme.muted)))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 2, 14, 20),
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final session = visible[index];
                          return Dismissible(
                            key: ValueKey(session.id),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) => _delete(session),
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(color: AppTheme.err.withOpacity(.15), borderRadius: BorderRadius.circular(14)),
                              child: const Icon(Icons.delete_outline, color: AppTheme.err),
                            ),
                            child: Container(
                              decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
                              child: ListTile(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                leading: Icon(_projectHistory ? Icons.code : Icons.chat_bubble_outline, color: _projectHistory ? AppTheme.glowAccent : AppTheme.accent),
                                title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
                                subtitle: Text(_dateLabel(session.time), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                                trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
                                onTap: () => _open(session),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
