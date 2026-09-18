import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../github_service.dart';
import '../theme.dart';
import '../widgets/signin_sheets.dart';

class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key});
  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  final _token = TextEditingController();
  List<GitHubRepo> _repos = [];
  GitHubRepo? _selected;
  String? _emailIdentity;
  String? _ghLogin;
  String? _ghAvatarUrl;
  String? _message;
  bool _busy = false;
  bool _hidden = true;

  /// Whether a GitHub token exists in secure storage.
  bool get _ghConnected => _ghLogin != null;

  @override
  void initState() {
    super.initState();
    _loadSelected();
  }

  Future<void> _loadSelected() async {
    final repo = await githubProjectStore.load();
    final email = await settingsStore.readEmailIdentity();
    var login = (await settingsStore.loadGitHubIdentity())['login'];
    // Token present but identity missing (e.g. old install): re-verify once.
    if (login == null) {
      final token = await githubService.readToken();
      if (token != null && token.isNotEmpty) {
        try {
          final identity = await githubService.fetchAuthenticatedUser();
          await settingsStore.saveGitHubIdentity(identity.login, identity.avatarUrl);
          login = identity.login;
        } on GitHubException {
          // Bad/expired token — leave disconnected; user can sign in again.
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _selected = repo;
      _emailIdentity = email;
      _ghLogin = login;
    });
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
      final identity = await githubService.fetchAuthenticatedUser();
      await settingsStore.saveGitHubIdentity(identity.login, identity.avatarUrl);
      final repos = await githubService.listRepos();
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _ghLogin = identity.login;
        _ghAvatarUrl = identity.avatarUrl;
        _message = 'Connected as ${identity.login}.';
      });
      _token.clear();
    } on GitHubException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// GitHub device flow: shows the one-time code in-app (big), copies it and
  /// opens github.com/login/device where the user pastes it.
  Future<void> _connectWithGitHub() async {
    setState(() { _busy = true; _message = null; });
    try {
      final connected = await GitHubDeviceFlowSheet.show(context);
      if (!connected) {
        if (mounted) setState(() => _message = null);
        return;
      }
      final identity = await settingsStore.loadGitHubIdentity();
      final repos = await githubService.listRepos();
      if (mounted) {
        setState(() {
          _repos = repos;
          _ghLogin = identity['login'];
          _ghAvatarUrl = identity['avatarUrl'];
          _message = 'GitHub connected as ${identity['login'] ?? 'user'}.';
        });
      }
    } on GitHubException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// CodePilot email sign-in: one-time code by email. Links the address to
  /// the app (does not authorize GitHub API access — use "Sign in with
  /// GitHub" for repository access).
  Future<void> _connectWithEmail() async {
    setState(() { _busy = true; _message = null; });
    try {
      final verified = await EmailOtpSheet.show(context);
      if (verified) {
        final email = await settingsStore.readEmailIdentity();
        if (mounted) {
          setState(() {
            _emailIdentity = email;
            _message = 'Email verified: $email';
          });
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showSigninOptions() async {
    final emailAvailable = emailOtpService.isAvailable;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.navyPanel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppTheme.border)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text('Sign in',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.text, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            _SigninOption(
              icon: Icons.code,
              title: 'Sign in with GitHub',
              subtitle: 'Authorize your GitHub account with a one-time code',
              enabled: true,
              onTap: () => Navigator.pop(context, 'github'),
            ),
            const SizedBox(height: 10),
            _SigninOption(
              icon: Icons.alternate_email,
              title: 'Sign in with email',
              subtitle: emailAvailable
                  ? 'We will email you a one-time code'
                  : 'Email sign-in is not configured on this build',
              enabled: emailAvailable,
              onTap: emailAvailable ? () => Navigator.pop(context, 'email') : null,
            ),
          ]),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'github') {
      await _connectWithGitHub();
    } else if (choice == 'email') {
      await _connectWithEmail();
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
    await settingsStore.clearEmailIdentity();
    await settingsStore.clearGitHubIdentity();
    if (mounted) {
      setState(() {
        _repos = [];
        _selected = null;
        _emailIdentity = null;
        _ghLogin = null;
        _ghAvatarUrl = null;
        _message = 'Disconnected.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('GitHub Integration'), actions: [
          IconButton(
              onPressed: (_busy || !_ghConnected) ? null : _refresh,
              icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _busy ? null : _disconnect, icon: const Icon(Icons.link_off)),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          // ---- Connection state card: Disconnected / Connecting / Connected
          Card(
            color: AppTheme.surface2,
            child: ListTile(
              leading: _ghConnected
                  ? CircleAvatar(
                      backgroundColor: AppTheme.navyPanel,
                      backgroundImage:
                          _ghAvatarUrl != null ? NetworkImage(_ghAvatarUrl!) : null,
                      child: _ghAvatarUrl == null
                          ? const Icon(Icons.person, color: AppTheme.muted, size: 20)
                          : null,
                    )
                  : const Icon(Icons.link_off, color: AppTheme.muted),
              title: Text(
                _ghConnected ? 'Connected' : 'Disconnected',
                style: TextStyle(
                  color: _ghConnected ? AppTheme.ok : AppTheme.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                _ghConnected
                    ? 'Signed in as $_ghLogin'
                    : _busy
                        ? 'Connecting…'
                        : 'Sign in to access your repositories',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
              trailing: _ghConnected
                  ? const Icon(Icons.check_circle, color: AppTheme.ok)
                  : FilledButton(
                      onPressed: _busy ? null : _showSigninOptions,
                      child: const Text('Sign in')),
            ),
          ),
          if (_selected != null) Card(color: AppTheme.surface2, child: ListTile(leading: const Icon(Icons.cloud_done, color: AppTheme.ok), title: Text(_selected!.fullName), subtitle: Text('Default branch: ${_selected!.defaultBranch}'))),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Connect GitHub', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            const SizedBox(height: 8),
            Text('Sign in securely with the device flow. Your authorization token is stored only in Android secure storage.', style: TextStyle(color: AppTheme.muted, fontSize: 13)),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _busy ? null : _showSigninOptions, icon: const Icon(Icons.login), label: Text(_busy ? 'Working…' : 'Sign in')),
            if (!_ghConnected) ...[
              const SizedBox(height: 12),
              const Center(child: Text('or connect with a token', style: TextStyle(fontSize: 12))),
              const SizedBox(height: 8),
              TextField(controller: _token, obscureText: _hidden, decoration: InputDecoration(labelText: 'Personal access token', hintText: 'github_pat_…', suffixIcon: IconButton(icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hidden = !_hidden)))),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(Icons.login), label: Text(_busy ? 'Working…' : 'Connect and load repositories')),
            ],
          ]))),
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

/// One row of the sign-in method chooser sheet.
class _SigninOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  const _SigninOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? AppTheme.text : AppTheme.muted;
    return Material(
      color: enabled ? AppTheme.surface : AppTheme.surface2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: enabled ? AppTheme.border : Colors.transparent),
          ),
          child: Row(children: [
            Icon(icon, color: enabled ? AppTheme.glowAccent : AppTheme.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: AppTheme.muted, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.muted),
          ]),
        ),
      ),
    );
  }
}
