import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
          'from': 'CodeFexa Mobile <onboarding@resend.dev>',
          'to': [trimmed],
          'subject': 'Your CodeFexa Mobile sign-in code',
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
      <h2 style="color:#e6edf3;margin:0 0 8px;">CodeFexa Mobile sign-in</h2>
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

/// Derives repository identity from an ALREADY-IMPORTED GitHub zipball
/// layout, so an existing project is recognized as connected without
/// re-importing.
///
/// GitHub zipballs extract a single root folder named
/// `<owner>-<repo>-<short-sha>` (e.g. `ismail53101-codepilot-mobile-12cea2d`),
/// and [ProjectService.importZip] keeps that folder as the project's only
/// top-level entry. A project whose root contains exactly one such folder is
/// therefore an imported GitHub repository. Parsing is heuristic because the
/// owner/repo/sha parts share one separator: the last hyphen segment must be
/// a plausible git sha (7–40 hex chars), the first segment is the owner and
/// the rest is the repo name. Returns null when the layout does not match,
/// so callers fall back to the honest "not connected" state — never a fake.
GitHubRepo? githubRepoFromZipballLayout(List<String> rootEntryNames,
    {String branch = 'main'}) {
  if (rootEntryNames.length != 1) return null; // zipball imports wrap ALL files
  final parts = rootEntryNames.single.split('-');
  if (parts.length < 3) return null; // owner-repo-sha needs 3+ segments
  final sha = parts.last;
  if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(sha)) {
    return null;
  }
  final owner = parts.first;
  final repoName = parts.sublist(1, parts.length - 1).join('-');
  if (owner.isEmpty || repoName.isEmpty) return null;
  return GitHubRepo(
      owner: owner, name: repoName, defaultBranch: branch, privateRepo: false);
}

/// GitHub REST integration. The token is kept in Android secure storage.
class GitHubService {
  static const _publishRequestTimeout = Duration(seconds: 30);
  final SettingsStore store;

  /// Injectable HTTP client for tests. When null, a fresh client is created
  /// per request and closed afterwards.
  final http.Client? httpClient;
  GitHubService(this.store, {this.httpClient});

  Future<String?> readToken() => store.readGitHubToken();
  Future<void> saveToken(String token) => store.writeGitHubToken(token);
  Future<void> deleteToken() => store.deleteGitHubToken();

  /// Sends [fn] on a short-lived client with a hard timeout. Every GitHub
  /// request in this class goes through here so client lifetime and timeout
  /// handling exist in exactly one place.
  Future<http.Response> _send(Future<http.Response> Function(http.Client c) fn,
      {Duration timeout = _publishRequestTimeout}) async {
    final client = httpClient ?? http.Client();
    try {
      return await fn(client).timeout(timeout);
    } finally {
      client.close();
    }
  }

  Future<http.Response> _get(Uri url, Map<String, String> headers,
          {Duration? timeout}) =>
      _send((c) => c.get(url, headers: headers),
          timeout: timeout ?? _publishRequestTimeout);

  Future<http.Response> _post(Uri url, Map<String, String> headers,
          {Object? body, Duration? timeout}) =>
      _send((c) => c.post(url, headers: headers, body: body),
          timeout: timeout ?? _publishRequestTimeout);

  Future<http.Response> _patch(Uri url, Map<String, String> headers,
          {Object? body, Duration? timeout}) =>
      _send((c) => c.patch(url, headers: headers, body: body),
          timeout: timeout ?? _publishRequestTimeout);

  Future<http.Response> _put(Uri url, Map<String, String> headers,
          {Object? body, Duration? timeout}) =>
      _send((c) => c.put(url, headers: headers, body: body),
          timeout: timeout ?? _publishRequestTimeout);

  Future<http.Response> _delete(Uri url, Map<String, String> headers,
          {Object? body, Duration? timeout}) =>
      _send((c) => c.delete(url, headers: headers, body: body),
          timeout: timeout ?? _publishRequestTimeout);

  // ==================================================================
  // OAuth device flow
  // ==================================================================

  /// Starts GitHub's OAuth device flow. The caller displays the user_code and
  /// opens verification_uri in a browser; this method polls until authorized.
  Future<({String userCode, String verificationUri, String deviceCode})> startDeviceFlow() async {
    const deviceUrl = 'https://github.com/login/device/code';
    final http.Response response;
    try {
      response = await _post(
        Uri.parse(deviceUrl),
        const {'Accept': 'application/json'},
        // `workflow` is REQUIRED for committing .github/workflows/* files:
        // without it GitHub's Git Data API rejects POST /git/trees with a
        // misleading HTTP 404 — exactly the "Publish FAILED … git/trees 404"
        // report. The repo scope alone is not enough for workflow paths.
        body: {
          'client_id': githubOAuthClientId,
          'scope': 'repo workflow read:user',
        },
        timeout: const Duration(seconds: 20),
      );
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
    // HTTP 404 here means GitHub does not recognize the OAuth app's
    // client_id (deleted/revoked app, or device flow disabled) — GitHub
    // answers {"error":"Not Found"} with NO "message" key, which used to
    // render as the meaningless "GitHub request failed (HTTP 404)."
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'POST', url: deviceUrl));
    }
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

    const tokenUrl = 'https://github.com/login/oauth/access_token';

    Future<http.Response?> pollOnce() async {
      try {
        final response = await _post(
          Uri.parse(tokenUrl),
          const {'Accept': 'application/json'},
          body: {
            'client_id': githubOAuthClientId,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
          timeout: const Duration(seconds: 20),
        );
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
            // Covers hard HTTP failures (404 {"error":"Not Found"} from a
            // revoked/unknown client_id, 5xx, …) with the REAL status and
            // GitHub's error text — never an endless silent poll.
            final desc = data['error_description'] as String?;
            throw GitHubException(
                'GitHub sign-in failed: $error${desc == null ? '' : ' — $desc'} '
                '(HTTP ${response.statusCode}). If this keeps happening, sign '
                'out and sign in again.');
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
      const userUrl = 'https://api.github.com/user';
      final response = await _get(Uri.parse(userUrl), headers,
          timeout: const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw GitHubException(_error(response, method: 'GET', url: userUrl));
      }
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

  /// Repositories of the authenticated user: GET /user/repos (paginated,
  /// up to [maxPages] × 100). Includes member/collaborator repos so imports
  /// work for org repositories the user has write access to.
  Future<List<GitHubRepo>> listRepos({int maxPages = 3}) async {
    final headers = await _auth();
    const urlBase = 'https://api.github.com/user/repos';
    final repos = <GitHubRepo>[];
    var page = 1;
    while (page <= maxPages) {
      final response = await _get(
          Uri.parse('$urlBase?per_page=100&sort=updated&page=$page'),
          headers);
      if (response.statusCode != 200) {
        throw GitHubException(
            _error(response, method: 'GET', url: '$urlBase (page $page)'));
      }
      final data = jsonDecode(response.body) as List;
      repos.addAll([
        for (final item in data) GitHubRepo.fromJson(item as Map<String, dynamic>)
      ]);
      if (data.length < 100) break;
      page++;
    }
    return repos;
  }

  /// Creates a repository for the AUTHENTICATED user:
  /// POST /user/repos — the only endpoint that works for the OAuth user
  /// token this app stores (org-scoped creation needs a different grant).
  /// Requires the `repo` (or `public_repo`) scope. Returns the created repo
  /// with its real default_branch so the caller can persist it.
  Future<GitHubRepo> createRepository({
    required String name,
    required bool isPrivate,
    String? description,
    String? defaultBranch,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const GitHubException('Repository name cannot be empty.');
    }
    if (RegExp(r'[^A-Za-z0-9._-]').hasMatch(trimmed)) {
      throw const GitHubException(
          'Repository name may only contain letters, numbers, ".", "_" and "-".');
    }
    final headers = await _auth()..['Content-Type'] = 'application/json';
    const url = 'https://api.github.com/user/repos';
    final body = {
      'name': trimmed,
      'private': isPrivate,
      'auto_init': false,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
      if (defaultBranch != null && defaultBranch.trim().isNotEmpty)
        'default_branch': defaultBranch.trim(),
    };
    final response = await _post(Uri.parse(url), headers, body: jsonEncode(body));
    // 201 = created. Anything else is a REAL failure (422 name exists,
    // 401/403 scope problem, 404 stale client) — surfaced verbatim.
    if (response.statusCode != 201) {
      throw GitHubException(_error(response, method: 'POST', url: url));
    }
    return GitHubRepo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Fetch the repository's real metadata (default branch, existence).
  /// Used after recovering owner/name from an imported zipball layout so
  /// publishes target the branch GitHub actually reports. Throws
  /// [GitHubException] when the API is unreachable or the repo is gone.
  Future<GitHubRepo> fetchRepoDetails(GitHubRepo repo) async {
    final headers = await _auth();
    final url =
        'https://api.github.com/repos/${repo.owner}/${repo.name}';
    final response = await _get(Uri.parse(url), headers);
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'GET', url: url));
    }
    return GitHubRepo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String> importRepo(GitHubRepo repo, ProjectService projects) async {
    final headers = await _auth();
    final url =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/zipball/${Uri.encodeComponent(repo.defaultBranch)}';
    final response = await _get(Uri.parse(url), headers,
        timeout: const Duration(seconds: 120));
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'GET', url: url));
    }
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
      final existing = await _get(endpoint, headers);
      String? sha;
      if (existing.statusCode == 200) sha = (jsonDecode(existing.body) as Map)['sha'] as String?;
      if (change.kind == 'delete') {
        if (sha == null) continue;
        final body = {'message': 'CodeFexa: delete ${change.path}', 'sha': sha, 'branch': repo.defaultBranch};
        final response = await _delete(endpoint, {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body));
        if (response.statusCode != 200) throw GitHubException(_error(response, method: 'DELETE', url: endpoint));
      } else {
        final content = change.contentAfter ?? '';
        final body = {'message': 'CodeFexa: update ${change.path}', 'content': base64Encode(utf8.encode(content)), 'branch': repo.defaultBranch, if (sha != null) 'sha': sha};
        final response = await _put(endpoint, {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body));
        if (response.statusCode != 200 && response.statusCode != 201) {
          throw GitHubException(_error(response, method: 'PUT', url: endpoint));
        }
      }
      published++;
    }
    return published == 0 ? 'No confirmed changes to publish.' : 'Published $published change${published == 1 ? '' : 's'} to ${repo.fullName}.';
  }

  String _encodePath(String path) => path.split('/').map(Uri.encodeComponent).join('/');

  // ==================================================================
  // Error transparency
  // ==================================================================

  /// Human message for a failed GitHub response. GitHub has TWO error body
  /// shapes: api.github.com uses `{"message": "…"}` while the github.com
  /// OAuth endpoints use `{"error": "…", "error_description": "…"}` — the
  /// device-flow 404 for a bad client_id is exactly `{"error":"Not Found"}`
  /// with no `message`, which used to degrade to the bare
  /// "GitHub request failed (HTTP 404)." with the endpoint and cause hidden.
  /// This surfaces the HTTP status, the request method + endpoint, and
  /// GitHub's own message verbatim. Exposed for tests.
  @visibleForTesting
  static String describeApiError(int statusCode, String body,
      {String? method, Object? url}) {
    final where = (method != null && url != null) ? ' [$method $url]' : '';
    String? detail;
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final m = json['message'];
        final e = json['error'];
        if (m is String && m.trim().isNotEmpty) {
          detail = m.trim();
        } else if (e is String && e.trim().isNotEmpty) {
          detail = e.trim();
          final d = json['error_description'];
          if (d is String && d.trim().isNotEmpty) detail = '$detail — ${d.trim()}';
        }
      }
    } catch (_) {
      // Non-JSON body — handled below as a raw snippet.
    }
    final hint = statusCode == 404
        ? ' The resource may not exist, or the app\'s GitHub connection is '
            'stale — sign out and sign in again if this keeps happening.'
        : '';
    if (detail == null || detail.isEmpty) {
      if (body.trim().isEmpty) {
        return 'GitHub request failed (HTTP $statusCode) — no response body.$where$hint';
      }
      final trimmedBody = body.trim();
      final snippet = trimmedBody.length > 180
          ? '${trimmedBody.substring(0, 180)}…'
          : trimmedBody;
      return 'GitHub request failed (HTTP $statusCode). Response: $snippet$where$hint';
    }
    return 'GitHub: $detail (HTTP $statusCode)$where$hint';
  }

  String _error(http.Response response, {String? method, Object? url}) =>
      describeApiError(response.statusCode, response.body, method: method, url: url);

  // ==================================================================
  // Real Git Data API: branches, commits, pull requests, CI status.
  // This is a REAL git commit — a tree + commit object created via the
  // GitHub Git database API — not one Contents-API file PUT per file.
  // ==================================================================

  /// List branches of [repo] (name + sha), most relevant first.
  Future<List<({String name, String sha})>> listBranches(GitHubRepo repo) async {
    final headers = await _auth();
    final url =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/branches?per_page=100';
    final response = await _get(Uri.parse(url), headers);
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'GET', url: url));
    }
    final data = jsonDecode(response.body) as List;
    return [
      for (final b in data)
        (
          name: (b as Map)['name'] as String,
          sha: b['commit']['sha'] as String,
        )
    ];
  }

  /// Create a branch at [fromSha] (defaults to the repo default branch head).
  Future<String> createBranch(GitHubRepo repo, String branchName,
      {String? fromSha}) async {
    final headers = await _auth()
      ..['Content-Type'] = 'application/json';
    var sha = fromSha;
    if (sha == null) {
      final refUrl =
          'https://api.github.com/repos/${repo.owner}/${repo.name}/git/ref/heads/${Uri.encodeComponent(repo.defaultBranch)}';
      final head = await _get(Uri.parse(refUrl), headers);
      if (head.statusCode != 200) {
        throw GitHubException(_error(head, method: 'GET', url: refUrl));
      }
      sha = ((jsonDecode(head.body) as Map)['object'] as Map)['sha'] as String;
    }
    final refsUrl =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/git/refs';
    final response = await _post(Uri.parse(refsUrl), headers,
        body: jsonEncode({'ref': 'refs/heads/$branchName', 'sha': sha}));
    if (response.statusCode != 201) {
      final msg = _error(response, method: 'POST', url: refsUrl);
      if (response.statusCode == 422) {
        throw GitHubException('Branch "$branchName" already exists.');
      }
      throw GitHubException(msg);
    }
    return sha;
  }

  /// Create a blob for [bytes] and return its sha.
  Future<String> _createBlob(
      GitHubRepo repo, List<int> bytes, Map<String, String> headers) async {
    final url = 'https://api.github.com/repos/${repo.owner}/${repo.name}/git/blobs';
    final response = await _post(
      Uri.parse(url),
      headers,
      body: jsonEncode({
        // GitHub's Git Data API accepts base64 for both text and binary
        // blobs. Never decode project bytes as UTF-8 here: images,
        // archives, keystores, and native libraries must stay lossless.
        'content': base64Encode(bytes),
        'encoding': 'base64',
      }),
    );
    if (response.statusCode != 201) {
      throw GitHubException(_error(response, method: 'POST', url: url));
    }
    return (jsonDecode(response.body) as Map)['sha'] as String;
  }

  /// Create a REAL git commit on [branch] from a full working-tree snapshot.
  ///
  /// [files] maps every project file path to its current raw bytes (or null to
  /// delete it). The tree is built fresh from these entries so the pushed
  /// snapshot exactly matches the on-device workspace, including binaries.
  Future<({String sha, String htmlUrl})> commitTree({
    required GitHubRepo repo,
    required String branch,
    required String message,
    required Map<String, List<int>?> files,
  }) async {
    final headers = await _auth()
      ..['Content-Type'] = 'application/json';
    final base = 'https://api.github.com/repos/${repo.owner}/${repo.name}';

    // 1. Base commit + its tree.
    final refUrl = '$base/git/ref/heads/${Uri.encodeComponent(branch)}';
    final headResp = await _get(Uri.parse(refUrl), headers);
    if (headResp.statusCode != 200) {
      throw GitHubException(
          '${_error(headResp, method: 'GET', url: refUrl)} Branch "$branch" not '
          'found on ${repo.fullName} — create it first (create_branch).');
    }
    final baseSha =
        ((jsonDecode(headResp.body) as Map)['object'] as Map)['sha'] as String;
    final commitUrl = '$base/git/commits/$baseSha';
    final baseCommitResp = await _get(Uri.parse(commitUrl), headers);
    if (baseCommitResp.statusCode != 200) {
      throw GitHubException(_error(baseCommitResp, method: 'GET', url: commitUrl));
    }
    final baseTree = (jsonDecode(baseCommitResp.body) as Map)['tree']['sha'] as String;

    // 2. Build the new tree from the full file snapshot.
    final treeEntries = <Map<String, dynamic>>[];
    for (final entry in files.entries) {
      final path = entry.key;
      if (path == '.codepilot_manifest.json' || path == '.codepilot_project') {
        continue; // app-internal bookkeeping never enters the repo
      }
      if (entry.value == null) {
        treeEntries.add({
          'path': path,
          'mode': '100644',
          'type': 'blob',
          'sha': null,
        }); // deletion marker
      } else {
        final blobSha = await _createBlob(repo, entry.value!, headers);
        treeEntries.add({
          'path': path,
          'mode': '100644',
          'type': 'blob',
          'sha': blobSha,
        });
      }
    }
    final treeUrl = '$base/git/trees';
    final treeResp = await _post(Uri.parse(treeUrl), headers,
        body: jsonEncode({'base_tree': baseTree, 'tree': treeEntries}));
    if (treeResp.statusCode != 201) {
      var message = _error(treeResp, method: 'POST', url: treeUrl);
      // GitHub returns HTTP 404 for POST /git/trees when the tree touches
      // .github/workflows/* but the OAuth token lacks the `workflow` scope
      // (blob creation succeeds because blobs carry no path). Turn that
      // specific lie into the truth + the exact remediation.
      final touchesWorkflow = files.keys.any((path) =>
          path == '.github' ||
          path.startsWith('.github/') ||
          path.contains('/.github/'));
      if (treeResp.statusCode == 404 && touchesWorkflow) {
        message = 'GitHub rejected the commit because this sign-in token is '
            'missing the "workflow" permission needed to commit '
            '.github/workflows/ files. Fix: Integrations → GitHub → sign '
            'out, then sign in again (the new sign-in requests the '
            'workflow scope) and publish once more.\n$message';
      }
      throw GitHubException(message);
    }
    final newTree = (jsonDecode(treeResp.body) as Map)['sha'] as String;

    // 3. Commit object with the new tree.
    final commitsUrl = '$base/git/commits';
    final commitResp = await _post(Uri.parse(commitsUrl), headers,
        body: jsonEncode({'message': message, 'tree': newTree, 'parents': [baseSha]}));
    if (commitResp.statusCode != 201) {
      throw GitHubException(_error(commitResp, method: 'POST', url: commitsUrl));
    }
    final commit = jsonDecode(commitResp.body) as Map;
    final commitSha = commit['sha'] as String;

    // 4. Move the branch ref to the new commit — NEVER a force update.
    final refPatchUrl =
        '$base/git/refs/heads/${Uri.encodeComponent(branch)}';
    final refResp = await _patch(Uri.parse(refPatchUrl), headers,
        body: jsonEncode({'sha': commitSha, 'force': false}));
    if (refResp.statusCode != 200) {
      throw GitHubException(_error(refResp, method: 'PATCH', url: refPatchUrl));
    }

    return (
      sha: commitSha,
      htmlUrl:
          'https://github.com/${repo.owner}/${repo.name}/commit/$commitSha',
    );
  }

  /// Open a pull request from [head] into [base].
  Future<({int number, String url})> createPullRequest(
      GitHubRepo repo, String head, String base, String title,
      {String body = ''}) async {
    final headers = await _auth()
      ..['Content-Type'] = 'application/json';
    final url = 'https://api.github.com/repos/${repo.owner}/${repo.name}/pulls';
    final response = await _post(Uri.parse(url), headers,
        body: jsonEncode({'title': title, 'head': head, 'base': base, 'body': body}));
    if (response.statusCode != 201) {
      throw GitHubException(_error(response, method: 'POST', url: url));
    }
    final data = jsonDecode(response.body) as Map;
    return (number: data['number'] as int, url: data['html_url'] as String);
  }

  /// Latest CI run for [branch] (null when none yet).
  Future<({String status, String? conclusion, int runId, String url})?>
      latestRun(GitHubRepo repo, String branch) async {
    final headers = await _auth();
    final url =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/actions/runs?branch=${Uri.encodeComponent(branch)}&per_page=1';
    final response = await _get(Uri.parse(url), headers);
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'GET', url: url));
    }
    final runs = ((jsonDecode(response.body) as Map)['workflow_runs'] as List?) ?? const [];
    if (runs.isEmpty) return null;
    final run = runs.first as Map;
    return (
      status: run['status'] as String? ?? 'unknown',
      conclusion: run['conclusion'] as String?,
      runId: run['id'] as int,
      url: run['html_url'] as String? ?? '',
    );
  }

  /// Download the failed step of a CI run for error-driven repair.
  /// Returns the first ~6k chars of the failed job's log.
  Future<String> fetchFailureLog(GitHubRepo repo, int runId) async {
    final headers = await _auth();
    final jobsUrl =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/actions/runs/$runId/jobs';
    final jobsResp = await _get(Uri.parse(jobsUrl), headers,
        timeout: const Duration(seconds: 60));
    if (jobsResp.statusCode != 200) {
      throw GitHubException(_error(jobsResp, method: 'GET', url: jobsUrl));
    }
    final jobs = (jsonDecode(jobsResp.body) as Map)['jobs'] as List;
    Map? failed;
    for (final j in jobs) {
      if ((j as Map)['conclusion'] == 'failure') {
        failed = j;
        break;
      }
    }
    failed ??= jobs.isEmpty ? null : jobs.first as Map;
    if (failed == null) return 'No jobs found for this run.';
    final jobId = failed['id'] as int;
    final logUrl =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/actions/jobs/$jobId/logs';
    final logResp = await _get(Uri.parse(logUrl), headers,
        timeout: const Duration(seconds: 60));
    if (logResp.statusCode != 200) {
      return 'Could not download the log '
          '(${describeApiError(logResp.statusCode, logResp.body, method: 'GET', url: logUrl)})';
    }
    var log = logResp.body;
    if (log.length > 6000) {
      // Keep the tail — errors are usually at the end of a build log.
      log = '… (log truncated)…${log.substring(log.length - 6000)}';
    }
    return log;
  }

  /// Clone a repository into a new local project via the ZIP endpoint.
  Future<String> cloneRepo(GitHubRepo repo, ProjectService projects,
      {String? branch}) async {
    final headers = await _auth();
    final ref = branch ?? repo.defaultBranch;
    final url =
        'https://api.github.com/repos/${repo.owner}/${repo.name}/zipball/${Uri.encodeComponent(ref)}';
    final response = await _get(Uri.parse(url), headers,
        timeout: const Duration(seconds: 120));
    if (response.statusCode != 200) {
      throw GitHubException(_error(response, method: 'GET', url: url));
    }
    final temp = await getTemporaryDirectory();
    final zip = File(p.join(temp.path, '${repo.owner}_${repo.name}_$ref.zip'));
    await zip.writeAsBytes(response.bodyBytes, flush: true);
    final message = await projects.importZip(zip.path, name: repo.name);
    // Remember which remote this project came from (for push/PR later).
    await projects.updateManifest({
      'gitRepository': repo.fullName,
      'gitBranch': ref,
    });
    return message;
  }
}

class GitHubProjectStore {
  static const _owner = 'github_repo_owner';
  static const _name = 'github_repo_name';
  static const _branch = 'github_repo_branch';

  final SettingsStore store;

  /// Optional project service: when set, [resolveForActiveProject] can
  /// fall back to the ACTIVE PROJECT's own manifest link and recover the
  /// link from an imported zipball layout, keeping every consumer (publish
  /// button, agent git tools, Explorer) on one canonical source of truth.
  final ProjectService? projects;
  GitHubProjectStore(this.store, {this.projects});

  Future<GitHubRepo?> load() async {
    final values = await store.loadGitHubProject();
    if (values['owner'] == null || values['name'] == null) return null;
    return GitHubRepo(owner: values['owner']!, name: values['name']!, defaultBranch: values['branch'] ?? 'main', privateRepo: false);
  }

  Future<void> save(GitHubRepo repo) => store.saveGitHubProject(repo.owner, repo.name, repo.defaultBranch);
  Future<void> clear() => store.clearGitHubProject();

  /// CANONICAL repository for the ACTIVE PROJECT, tried in order:
  /// 1. The GitHub integration's saved repository — the user's most recent
  ///    explicit choice. It WINS and is written INTO the project manifest
  ///    automatically, so the active project's remote is always refreshed
  ///    to match the integration.
  /// 2. Recovery from an imported zipball layout (single visible root
  ///    folder `owner-repo-sha`) — verified against the API when possible
  ///    and persisted (integration prefs + project manifest) so the next
  ///    lookup is instant.
  /// 3. Nothing found: a stale project-manifest link (e.g. left over after
  ///    Integrations → disconnect) is cleared rather than trusted, and
  ///    null is returned. Callers show one honest "not connected" error.
  Future<GitHubRepo?> resolveForActiveProject() async {
    final svc = projects;
    if (svc == null || svc.projectName == null) return load();

    // 1. The integration's repository — sync it INTO the project manifest.
    final integration = await load();
    if (integration != null) {
      await svc.linkGitHubRepo(
          integration.owner, integration.name,
          branch: integration.defaultBranch);
      return integration;
    }

    // 2. Recover from the imported files themselves.
    final recovered =
        githubRepoFromZipballLayout(svc.rootEntryNames);
    if (recovered != null) {
      GitHubRepo verified = recovered;
      try {
        verified = await GitHubService(store).fetchRepoDetails(recovered);
      } on GitHubException {
        // Offline / token missing: the parsed identity is still the best
        // available truth — publish will surface a specific error if wrong.
      }
      await save(verified);
      await svc.linkGitHubRepo(
          verified.owner, verified.name,
          branch: verified.defaultBranch);
      return verified;
    }

    // 3. Genuinely no repository context — drop any stale project link.
    await svc.updateManifest({'gitRepository': null, 'gitBranch': null});
    return null;
  }

  /// Re-derive and persist the repository link for the active project.
  /// Called when returning from the GitHub integration screen or reopening
  /// a project, so switching repos in Integrations is reflected immediately.
  Future<GitHubRepo?> refreshLink() async {
    final svc = projects;
    if (svc == null || svc.projectName == null) return load();
    final integration = await load();
    if (integration != null) {
      await svc.linkGitHubRepo(
          integration.owner, integration.name,
          branch: integration.defaultBranch);
      return integration;
    }
    // No integration-level repo: drop a stale project link instead of
    // letting git tools report a repository that is no longer connected.
    final manifest = await svc.loadManifest();
    if (manifest['gitRepository'] != null) {
      await svc.updateManifest({'gitRepository': null, 'gitBranch': null});
    }
    return null;
  }
}

// Keep keys centralized so the secure settings implementation stays private.
const githubOwnerKey = GitHubProjectStore._owner;
const githubNameKey = GitHubProjectStore._name;
const githubBranchKey = GitHubProjectStore._branch;
