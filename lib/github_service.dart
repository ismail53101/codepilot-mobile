import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'project_service.dart';
import 'stores.dart';

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
