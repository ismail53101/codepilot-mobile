import 'package:flutter/material.dart';

import '../github_service.dart';
import '../main.dart';
import '../theme.dart';

class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key});
  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  final _token = TextEditingController();
  List<GitHubRepo> _repos = [];
  GitHubRepo? _selected;
  String? _message;
  bool _busy = false;
  bool _hidden = true;

  @override
  void initState() {
    super.initState();
    _loadSelected();
  }

  Future<void> _loadSelected() async {
    final repo = await githubProjectStore.load();
    if (mounted) setState(() => _selected = repo);
  }

  Future<void> _connect() async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _message = 'Enter a GitHub personal access token.');
      return;
    }
    setState(() { _busy = true; _message = null; });
    try {
      await githubService.saveToken(token);
      final repos = await githubService.listRepos();
      if (!mounted) return;
      setState(() { _repos = repos; _message = 'Connected. Select a repository below.'; });
      _token.clear();
    } on GitHubException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() { _busy = true; _message = null; });
    try {
      final repos = await githubService.listRepos();
      if (mounted) setState(() => _repos = repos);
    } on GitHubException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(GitHubRepo repo) async {
    setState(() { _busy = true; _message = 'Downloading ${repo.fullName}…'; });
    try {
      await githubService.importRepo(repo, projectService);
      await githubProjectStore.save(repo);
      if (mounted) setState(() => _message = 'Imported ${repo.fullName}. Open AI Chat to work on it.');
    } on GitHubException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } on ProjectException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await githubService.deleteToken();
    await githubProjectStore.clear();
    if (mounted) setState(() { _repos = []; _selected = null; _message = 'GitHub disconnected.'; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('GitHub Integration'), actions: [
          IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _busy ? null : _disconnect, icon: const Icon(Icons.link_off)),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Connect GitHub', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            const SizedBox(height: 8),
            Text('Use a GitHub token with repository Contents read/write access. It is stored only in Android secure storage.', style: TextStyle(color: AppTheme.muted, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(controller: _token, obscureText: _hidden, decoration: InputDecoration(labelText: 'Personal access token', hintText: 'github_pat_…', suffixIcon: IconButton(icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hidden = !_hidden)))),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(Icons.login), label: Text(_busy ? 'Working…' : 'Connect and load repositories')),
          ]))),
          if (_selected != null) Card(color: AppTheme.surface2, child: ListTile(leading: const Icon(Icons.cloud_done, color: AppTheme.ok), title: Text(_selected!.fullName), subtitle: Text('Default branch: ${_selected!.defaultBranch}'))),
          if (_message != null) Padding(padding: const EdgeInsets.all(12), child: Text(_message!, style: TextStyle(color: _message!.contains('failed') || _message!.contains('Enter') ? AppTheme.err : AppTheme.ok))),
          if (_repos.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Repositories', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            const SizedBox(height: 8),
            for (final repo in _repos) Card(child: ListTile(leading: Icon(repo.privateRepo ? Icons.lock : Icons.public, color: AppTheme.accent), title: Text(repo.fullName), subtitle: Text('branch: ${repo.defaultBranch}'), trailing: FilledButton(onPressed: _busy ? null : () => _import(repo), child: const Text('Import')))),
          ],
          const SizedBox(height: 12),
          Text('After importing, use prompts in AI Chat. Review each proposed change before applying it, then use “Publish to GitHub” to commit the confirmed changes.', style: TextStyle(color: AppTheme.muted, fontSize: 13)),
        ]),
      );
}
