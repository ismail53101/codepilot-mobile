import 'package:flutter/material.dart';

import '../main.dart';
import '../stores.dart';
import '../theme.dart';

/// Search History screen: recent searches recorded from the Home command
/// bar. Tap to run a search again, swipe to remove, or clear everything.
class SearchHistoryScreen extends StatefulWidget {
  const SearchHistoryScreen({super.key});

  @override
  State<SearchHistoryScreen> createState() => _SearchHistoryScreenState();
}

class _SearchHistoryScreenState extends State<SearchHistoryScreen> {
  List<SearchHistoryEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final entries = await searchHistoryStore.load();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _rerun(SearchHistoryEntry entry) async {
    await searchHistoryStore.add(entry.query); // bump to top
    if (!mounted) return;
    final noProject = projectService.projectName == null;
    Navigator.pushNamed(context, noProject ? '/chat' : '/search',
        arguments: entry.query);
  }

  Future<void> _remove(int index) async {
    await searchHistoryStore.removeAt(index);
    await _refresh();
  }

  Future<void> _clearAll() async {
    await searchHistoryStore.clear();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('Search History'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? ListView(children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(children: [
                      Icon(Icons.history, size: 56, color: AppTheme.muted),
                      SizedBox(height: 12),
                      Text('No recent searches',
                          style: TextStyle(
                              color: AppTheme.text,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      SizedBox(height: 6),
                      Text(
                          'Searches you run from the Home command bar will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted)),
                    ]),
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return Dismissible(
                      key: ValueKey('${entry.query}:${entry.time.millisecondsSinceEpoch}'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _remove(index),
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: AppTheme.err.withOpacity(.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child:
                            const Icon(Icons.delete_outline, color: AppTheme.err),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          leading: const Icon(Icons.history,
                              color: AppTheme.glowAccent),
                          title: Text(entry.query,
                              style: const TextStyle(
                                  color: AppTheme.text, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(entry.timeLabel,
                              style: const TextStyle(
                                  color: AppTheme.muted, fontSize: 11)),
                          trailing: const Icon(Icons.chevron_right,
                              color: AppTheme.muted),
                          onTap: () => _rerun(entry),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
