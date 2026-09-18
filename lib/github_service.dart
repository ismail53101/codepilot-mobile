import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'project_service.dart';
import 'stores.dart';

const githubOAuthClientId = 'Ov23liNr0y5Ux3jdEoYq';

/// Resend email service used for the email-OTP sign-in option. The key is
/// read from the environment; without it the email option reports itself as
/// unavailable instead of failing at runtime.
class EmailOtpService {
  static const _endpoint = 'https://api.resend.com/emails';
  static const _codeLength = 6;
  static const _codeValidity = Duration(minutes: 10);

  final Map<String, ({String code, DateTime expires})> _pending = {};

  String? _apiKey() {
    const key = String.fromEnvironment(
      'RESEND_API_KEY',
      defaultValue: '',
    );
    if (key.isNotEmpty) return key;
    final envKey = Platform.environment['RESEND_API_KEY'];
    return (envKey == null || envKey.isEmpty) ? null : envKey;
  }

  /// Whether the email-OTP option can be offered. UI hides it when false.
  bool get isAvailable => _apiKey() != null;

  String _generateCode() {
    final rnd = Random.secure();
    return List.generate(_codeLength, (_) => rnd.nextInt(10)).join();
  }

  /// Sends a fresh 6-digit OTP to [email]. Returns the code only on test
  /// environments ("test:") so widget tests never touch the network.
  Future<({bool ok, String? error})> sendCode(String email, {bool testMode = false}) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty || !trimmed.contains('@')) {
      return (ok: false, error: 'Enter a valid email address.');
    }
    final code = _generateCode();
    if (testMode) {
      _pending[trimmed] = (code: code, expires: DateTime.now().add(_codeValidity));
      return (ok: true, error: null);
    }
    final key = _apiKey();
    if (key == null) {
      return (ok: false, error: 'Email sign-in is not configured on this build.');
    }
    try {
      final response = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'from': 'CodePilot <onboarding@resend.dev>',
          'to': [trimmed],
          'subject': 'Your CodePilot sign-in code',
          'html': _otpEmailHtml(code),
        }),
      );
      if (response.statusCode == 200) {
        _pending[trimmed] = (code: code, expires: DateTime.now().add(_codeValidity));
        return (ok: true, error: null);
      } else {
        return (ok: false, error: _resendError(response));
      }
    } on SocketException {
      return (ok: false, error: 'No network connection. Try again.');
    }
  }

  /// Verifies [code] for [email]. On success the code is consumed.
  Future<({bool ok, String? error})> verifyCode(String email, String code) async {
    final trimmed = email.trim();
    final entry = _pending[trimmed];
    if (entry == null) {
      return (ok: false, error: 'Request a new code first.');
    }
    if (DateTime.now().isAfter(entry.expires)) {
      _pending.remove(trimmed);
      return (ok: false, error: 'That code expired. Request a new one.');
    }
    if (entry.code != code.trim()) {
      return (ok: false, error: 'Incorrect code. Check the email and try again.');
    }
    _pending.remove(trimmed);
    return (ok: true, error: null);
  }

  String _otpEmailHtml(String code) {
    return '''
<!DOCTYPE html>
<html>
  <body style="margin:0;padding:24px;background:#0d1117;font-family:sans-serif;">
    <div style="max-width:420px;margin:0 auto;background:#161b22;border:1px solid #30363d;border-radius:12px;padding:28px;text-align:center;">
      <h2 style="color:#e6edf3;margin:0 0 8px;">CodePilot sign-in</h2>
      <p style="color:#8b949e;font-size:13px;margin:0 0 20px;">Use this code to finish signing in:</p>
      <div style="font-size:32px;font-weight:700;letter-spacing:8px;color:#3b82f6;">$code</div>
      <p style="color:#8b949e;font-size:12px;margin:20px 0 0;">This code expires in 10 minutes. If you didn't request it, you can ignore this email.</p>
    </div>
  </body>
  </html>
''';
  }

  String _resendError(http.Response response) {
    try {
      final json = jsonDecode(response.body) as Map;
      return json['message'] as String? ??
          'Could not send the email (HTTP ${response.statusCode}).';
    } catch (_) {
      return 'Could not send the email (HTTP ${response.statusCode}).';
    }
  }
}

class GitHubException implements Exception {
  final String message;
  const GitHubException(this.message);
  @override
  String toString() => message;
}

class GitHubRepo {
  final String owner;
  final String name;
  final String defaultBranch;
  final bool privateRepo;

  const GitHubRepo({required this.owner, required this.name, required this.defaultBranch, required this.privateRepo});

  factory GitHubRepo.fromJson(Map<String, dynamic> json) => GitHubRepo(
        owner: (json['owner'] as Map?)?['login'] as String? ?? '',
        name: json['name'] as String? ?? '',
        defaultBranch: json['default_branch'] as String? ?? 'main',
        privateRepo: json['private'] as bool? ?? false,
      );

  String get fullName => '$owner/$name';
}

/// GitHub REST integration. The token is kept in Android secure storage.
class GitHubService {
  final SettingsStore store;
  GitHubService(this.store);

  Future<String?> readToken() => store.readGitHubToken();
  Future<void> saveToken(String token) => store.writeGitHubToken(token);
  Future<void> deleteToken() => store.deleteGitHubToken();

  /// Starts GitHub's OAuth device flow. The caller displays the user_code and
  /// opens verification_uri in a browser; this method polls until authorized.
  Future<({String userCode, String verificationUri, String deviceCode})> startDeviceFlow() async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('https://github.com/login/device/code'),
            headers: const {'Accept': 'application/json'},
            body: {'client_id': githubOAuthClientId, 'scope': 'repo read:user'},
          )
          .timeout(const Duration(seconds: 20));
    } on SocketException {
      throw const GitHubException('No network connection. Check Wi-Fi/data and try again.');
    } on http.ClientException catch (e) {
      throw GitHubException(
          'Could not reach github.com to start sign-in. Check your network (a VPN or proxy may block GitHub) and try again.\nDetail: ${e.message}');
    } on HttpException {
      throw const GitHubException('Connection to github.com failed. Try again.');
    } on TimeoutException {
      throw const GitHubException('github.com took too long to respond. Try again.');
    }
    if (response.statusCode != 200) throw GitHubException(_error(response));
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw GitHubException(
          'Unexpected response from GitHub (HTTP ${response.statusCode}).');
    }
    return (
      userCode: (data['user_code'] as String?) ?? '',
      verificationUri: (data['verification_uri'] as String?) ?? 'https://github.com/login/device',
      deviceCode: (data['device_code'] as String?) ?? '',
    );
  }

  /// Polls GitHub's token endpoint until the user finishes authorization.
  ///
  /// Android networking notes:
  /// - Every request gets an explicit [timeout]; the browser keeps the app in
  ///   the background, so requests must never hang forever.
  /// - A single transient transport failure (ClientException "Software caused
  ///   connection abort", SocketException, HttpException) is retried after a
  ///   short pause instead of killing the whole flow — the OS network stack
  ///   routinely drops idle sockets while the app is backgrounded.
  /// - Honors GitHub's `interval` (and `+1s` extra for slow_down) so polling
  ///   is never aggressive.
  /// - [isCancelled] is checked between every step; when the sheet closes the
  ///   caller flips it and the loop returns promptly instead of running on in
  ///   the background.
  /// - On success the token is stored in secure storage and verified against
  ///   `GET /user` before the flow reports connected.
  Future<({String login, String? avatarUrl})> completeDeviceFlow(
    String deviceCode, {
    required Future<bool> Function() isCancelled,
    void Function(String status)? onStatus,
  }) async {
    var interval = const Duration(seconds: 5); // GitHub default
    const maxAttempts = 120; // ~10 min at the default interval

    Future<http.Response?> pollOnce() async {
      try {
        final response = await http
            .post(
              Uri.parse('https://github.com/login/oauth/access_token'),
              headers: const {'Accept': 'application/json'},
              body: {
                'client_id': githubOAuthClientId,
                'device_code': deviceCode,
                'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              },
            )
            .timeout(const Duration(seconds: 20));
        return response;
      } on http.ClientException {
        return null; // transient transport failure — caller retries
      } on SocketException {
        return null;
      } on HttpException {
        return null;
      } on TimeoutException {
        return null; // slow network — treat like any other transient failure
      }
    }

    var consecutiveTransportFailures = 0;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (await isCancelled()) return (login: '', avatarUrl: null);

      final response = await pollOnce();
      if (await isCancelled()) return (login: '', avatarUrl: null);

      if (response == null) {
        consecutiveTransportFailures++;
        if (consecutiveTransportFailures > 6) {
          throw const GitHubException(
              'Connection to github.com keeps failing. Check your network (VPN/proxy can block GitHub) and try again.');
        }
        onStatus?.call('Connection hiccup — retrying…');
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      consecutiveTransportFailures = 0;

      final Map<String, dynamic> data;
      try {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } on FormatException {
        throw GitHubException(
            'Unexpected response from GitHub (HTTP ${response.statusCode}).');
      }

      final token = data['access_token'] as String?;
      if (token != null && token.isNotEmpty) {
        await saveToken(token);
        onStatus?.call('Verifying your GitHub account…');
        return await fetchAuthenticatedUser();
      }

      final error = data['error'] as String?;
      switch (error) {
        case 'authorization_pending':
          break; // expected while the user is authorizing
        case 'slow_down':
          interval += const Duration(seconds: 5); // GitHub: +5s on slow_down
          break;
        case 'expired_token':
          throw const GitHubException(
              'The device code expired. Start sign-in again to get a new code.');
        case 'access_denied':
          throw const GitHubException(
              'Authorization was cancelled on github.com. Start again when ready.');
        case 'incorrect_client_credentials':
          throw const GitHubException(
              'The app\'s GitHub client ID is invalid or was revoked. Report this bug.');
        case 'incorrect_device_code':
          throw const GitHubException(
              'GitHub rejected the device code. Start sign-in again.');
        case 'device_flow_disabled':
          throw const GitHubException(
              'The GitHub App does not allow device sign-in. Report this bug.');
        default:
          if (error != null) {
            throw GitHubException('GitHub error: $error');
          }
        // No error and no token: malformed body — keep polling a little.
      }

      await Future.delayed(interval);
    }
    throw const GitHubException(
        'GitHub authorization timed out. Start again and enter the new code.');
  }

  /// Verifies the stored token by asking GitHub who it belongs to. Returns
  /// the authenticated login and avatar URL (non-secret; safe to display).
  Future<({String login, String? avatarUrl})> fetchAuthenticatedUser() async {
    final headers = await _auth();
    try {
      final response = await http
          .get(Uri.parse('https://api.github.com/user'), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw GitHubException(_error(response));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        login: (data['login'] as String?) ?? 'github-user',
        avatarUrl: data['avatar_url'] as String?,
      );
    } on SocketException {
      throw const GitHubException('No network connection while verifying the token.');
    } on HttpException {
      throw const GitHubException('Connection to api.github.com failed while verifying the token.');
    } on TimeoutException {
      throw const GitHubException('github.com verification timed out. Try again.');
    }
  }

  Future<Map<String, String>> _auth() async {
    final token = await readToken();
    if (token == null || token.trim().isEmpty) {
      throw const GitHubException('Connect GitHub with a personal access token first.');
    }
    return {'Authorization': 'Bearer ${token.trim()}', 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'};
  }

  Future<List<GitHubRepo>> listRepos() async {
    final headers = await _auth();
    final response = await http.get(Uri.parse('https://api.github.com/user/repos?per_page=100&sort=updated'), headers: headers);
    if (response.statusCode != 200) throw GitHubException(_error(response));
    final data = jsonDecode(response.body) as List;
    return [for (final item in data) GitHubRepo.fromJson(item as Map<String, dynamic>)];
  }

  Future<String> importRepo(GitHubRepo repo, ProjectService projects) async {
    final headers = await _auth();
    final response = await http.get(Uri.parse('https://api.github.com/repos/${repo.owner}/${repo.name}/zipball/${Uri.encodeComponent(repo.defaultBranch)}'), headers: headers);
    if (response.statusCode != 200) throw GitHubException(_error(response));
    final temp = await getTemporaryDirectory();
    final zip = File(p.join(temp.path, '${repo.owner}_${repo.name}.zip'));
    await zip.writeAsBytes(response.bodyBytes, flush: true);
    return projects.importZip(zip.path, name: repo.name);
  }

  Future<String> publishChanges(GitHubRepo repo, List<ChangeRecord> changes) async {
    final headers = await _auth();
    var published = 0;
    for (final change in changes.where((c) => !c.undone)) {
      final endpoint = Uri.parse('https://api.github.com/repos/${repo.owner}/${repo.name}/contents/${_encodePath(change.path)}');
      final existing = await http.get(endpoint, headers: headers);
      String? sha;
      if (existing.statusCode == 200) sha = (jsonDecode(existing.body) as Map)['sha'] as String?;
      if (change.kind == 'delete') {
        if (sha == null) continue;
        final body = {'message': 'CodePilot: delete ${change.path}', 'sha': sha, 'branch': repo.defaultBranch};
        final response = await http.delete(endpoint, headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body));
        if (response.statusCode != 200) throw GitHubException(_error(response));
      } else {
        final content = change.contentAfter ?? '';
        final body = {'message': 'CodePilot: update ${change.path}', 'content': base64Encode(utf8.encode(content)), 'branch': repo.defaultBranch, if (sha != null) 'sha': sha};
        final response = await http.put(endpoint, headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body));
        if (response.statusCode != 200 && response.statusCode != 201) throw GitHubException(_error(response));
      }
      published++;
    }
    return published == 0 ? 'No confirmed changes to publish.' : 'Published $published change${published == 1 ? '' : 's'} to ${repo.fullName}.';
  }

  String _encodePath(String path) => path.split('/').map(Uri.encodeComponent).join('/');

  String _error(http.Response response) {
    try {
      final json = jsonDecode(response.body) as Map;
      return json['message'] as String? ?? 'GitHub request failed (HTTP ${response.statusCode}).';
    } catch (_) {
      return 'GitHub request failed (HTTP ${response.statusCode}).';
    }
  }
}

class GitHubProjectStore {
  static const _owner = 'github_repo_owner';
  static const _name = 'github_repo_name';
  static const _branch = 'github_repo_branch';

  final SettingsStore store;
  GitHubProjectStore(this.store);

  Future<GitHubRepo?> load() async {
    final values = await store.loadGitHubProject();
    if (values['owner'] == null || values['name'] == null) return null;
    return GitHubRepo(owner: values['owner']!, name: values['name']!, defaultBranch: values['branch'] ?? 'main', privateRepo: false);
  }

  Future<void> save(GitHubRepo repo) => store.saveGitHubProject(repo.owner, repo.name, repo.defaultBranch);
  Future<void> clear() => store.clearGitHubProject();
}

// Keep keys centralized so the secure settings implementation stays private.
const githubOwnerKey = GitHubProjectStore._owner;
const githubNameKey = GitHubProjectStore._name;
const githubBranchKey = GitHubProjectStore._branch;
