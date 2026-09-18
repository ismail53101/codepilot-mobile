import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Settings screen: API provider status, storage info, change history.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _provider = 'xKiro';
  String _model = '';
  String? _keyHint;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final s = await settingsStore.load();
    final key = await settingsStore.readApiKey();
    if (!mounted) return;
    setState(() {
      _provider = s.providerName;
      _model = s.modelId;
      _keyHint = key == null || key.isEmpty ? null : maskKey(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final changes = agentService.recentChanges(limit: 50);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: ListTile(
          leading: Icon(Icons.key, color: _keyHint == null ? AppTheme.muted : AppTheme.ok),
          title: const Text('Custom API Provider'),
          subtitle: Text(_keyHint == null
              ? 'Add your API key (none stored)'
              : '$_provider · $_model · key $_keyHint'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.pushNamed(context, '/api');
            _loadStatus();
          },
        )),
        Card(child: ListTile(
          leading: const Icon(Icons.upload_file, color: AppTheme.accent),
          title: const Text('Import Project'),
          subtitle: const Text('Load a project ZIP into the local workspace'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pushNamed(context, '/import'),
        )),
        Card(child: ListTile(
          leading: const Icon(Icons.save_alt, color: AppTheme.accent),
          title: const Text('Export Project'),
          subtitle: const Text('Re-zip the modified project and share it'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pushNamed(context, '/export'),
        )),
        const SizedBox(height: 16),
        Text('Change history (${changes.length})', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (changes.isEmpty) Text('No changes recorded this session.', style: TextStyle(color: AppTheme.muted)),
        for (final c in changes) Card(child: ListTile(
          dense: true,
          leading: Icon(c.undone ? Icons.undo : (c.kind == 'write' ? Icons.edit : Icons.delete),
              color: c.undone ? AppTheme.muted : (c.kind == 'write' ? AppTheme.warn : AppTheme.err)),
          title: Text('${c.kind} · ${c.path}', overflow: TextOverflow.ellipsis),
          subtitle: Text(c.undone ? 'undone' : c.time.toIso8601String(), style: TextStyle(color: AppTheme.muted, fontSize: 11)),
        )),
        Row(children: [
          OutlinedButton.icon(onPressed: () {
            final rec = agentService.undoLast();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(rec == null ? 'Nothing to undo.' : 'Undone: ${rec.kind} ${rec.path}')));
          }, icon: const Icon(Icons.undo), label: const Text('Undo latest change')),
        ]),
        const SizedBox(height: 16),
        Card(color: AppTheme.surface2, child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('About CodePilot Mobile', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text('AI coding agent for Android. Works with any OpenAI-compatible API '
              '(default: xKiro, qwen/qwen3.7-flash:free). Projects are imported from ZIP '
              'and stored locally; all file operations are real and sandboxed inside the '
              'project directory. Build commands that need the Flutter/Android toolchain '
              'are routed to GitHub Actions — the app never fakes a build result.',
              style: TextStyle(fontSize: 13)),
        ]))),
      ]),
    );
  }
}
