import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Home screen: project selector, command bar, quick actions, recent changes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _command = TextEditingController();
  List<String> _projects = [];
  String? _current;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final projects = await projectService.listProjects();
    setState(() {
      _projects = projects;
      _current = projectService.projectName;
    });
  }

  Future<void> _switchProject(String? name) async {
    if (name == null) return;
    await projectService.openProject(name);
    await _refresh();
    if (mounted) setState(() {});
  }

  void _runCommand(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    if (projectService.projectName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open or import a project first.')));
      return;
    }
    // Route obvious search-style requests to search; everything else to chat.
    final lower = text.toLowerCase();
    final isSearch = lower.startsWith('find') || lower.startsWith('where') ||
        lower.contains('search for');
    if (isSearch) {
      final query = text
          .replaceFirst(RegExp(r'^(find|where is|search for)\s*', caseSensitive: false), '')
          .trim();
      Navigator.pushNamed(context, '/search', arguments: query);
    } else {
      Navigator.pushNamed(context, '/chat', arguments: text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = agentService.recentChanges(limit: 5);
    return Scaffold(
      appBar: AppBar(
        title: const Text('CodePilot'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.pushNamed(context, '/settings')),
          IconButton(icon: const Icon(Icons.key), tooltip: 'API provider', onPressed: () => Navigator.pushNamed(context, '/api')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          // 1. Project selector
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.folder_open, color: AppTheme.accent),
                const SizedBox(width: 8),
                Expanded(child: DropdownButtonFormField<String>(
                  value: _current,
                  hint: const Text('Select project'),
                  items: [for (final p in _projects) DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))],
                  onChanged: _switchProject,
                  decoration: const InputDecoration(isDense: true),
                )),
              ]),
              if (_current != null) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Type: ${projectService.detectType()}', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
              ),
            ]),
          )),
          const SizedBox(height: 12),
          // 2. AI command bar
          TextField(
            controller: _command,
            onSubmitted: _runCommand,
            decoration: InputDecoration(
              hintText: 'e.g. "Find the login screen" or "Explain this project"',
              prefixIcon: const Icon(Icons.bolt, color: AppTheme.accent),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _runCommand(_command.text)),
            ),
          ),
          const SizedBox(height: 12),
          // Quick actions grid
          GridView.count(
            crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.6,
            children: [
              _action(context, Icons.upload_file, 'Import ZIP', '/import'),
              _action(context, Icons.folder, 'Explorer', '/explorer'),
              _action(context, Icons.chat, 'AI Chat', '/chat'),
              _action(context, Icons.search, 'Search', '/search'),
              _action(context, Icons.build, 'Build', '/build'),
              _action(context, Icons.save_alt, 'Export ZIP', '/export'),
            ],
          ),
          const SizedBox(height: 16),
          // 5. Recent changes
          Text('Recent changes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (changes.isEmpty)
            Text('No changes yet in this session.', style: TextStyle(color: AppTheme.muted)),
          for (final c in changes) Card(child: ListTile(
            dense: true,
            leading: Icon(c.undone ? Icons.undo : (c.kind == 'write' ? Icons.edit : Icons.delete),
                color: c.undone ? AppTheme.muted : (c.kind == 'write' ? AppTheme.warn : AppTheme.err)),
            title: Text('${c.kind} · ${c.path}', overflow: TextOverflow.ellipsis),
            subtitle: Text('${c.time.hour.toString().padLeft(2, '0')}:${c.time.minute.toString().padLeft(2, '0')}:${c.time.second.toString().padLeft(2, '0')}${c.undone ? ' · undone' : ''}',
                style: TextStyle(color: AppTheme.muted)),
          )),
          Row(children: [
            OutlinedButton.icon(onPressed: () {
              final rec = agentService.undoLast();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(rec == null ? 'Nothing to undo.' : 'Undone: ${rec.kind} ${rec.path}')));
              setState(() {});
            }, icon: const Icon(Icons.undo), label: const Text('Undo latest')),
          ]),
        ]),
      ),
    );
  }

  Widget _action(BuildContext context, IconData icon, String label, String route) {
    return OutlinedButton(
      onPressed: () => Navigator.pushNamed(context, route),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: AppTheme.accent), const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 13)),
      ]),
    );
  }
}
