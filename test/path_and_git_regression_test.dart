import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:codepilot_mobile/github_service.dart';
import 'package:codepilot_mobile/project_service.dart';
import 'package:codepilot_mobile/stores.dart';
import 'package:codepilot_mobile/tool_registry.dart';

/// Redirects path_provider to an isolated temp directory.
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// Records Git-Data commit calls instead of touching api.github.com.
class _RecordingGitHub extends GitHubService {
  _RecordingGitHub(super.store);

  final List<Map<String, List<int>?>> commits = [];
  Object? failWith;

  @override
  Future<({String sha, String htmlUrl})> commitTree({
    required GitHubRepo repo,
    required String branch,
    required String message,
    required Map<String, List<int>?> files,
  }) async {
    final failure = failWith;
    if (failure is GitHubException) throw failure;
    commits.add(files);
    return (
      sha: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      htmlUrl: 'https://github.com/${repo.fullName}/commit/deadbeef',
    );
  }
}

/// A GitHub service that reproduces a REAL api.github.com failure.
class _FailingGitHub extends GitHubService {
  _FailingGitHub(super.store);

  @override
  Future<({String sha, String htmlUrl})> commitTree({
    required GitHubRepo repo,
    required String branch,
    required String message,
    required Map<String, List<int>?> files,
  }) async {
    throw const GitHubException('Bad credentials (HTTP 401)');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsStub;

  setUp(() {
    docsStub = Directory.systemTemp.createTempSync('path_git_regr');
    PathProviderPlatform.instance = _FakePathProvider(docsStub.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (docsStub.existsSync()) docsStub.deleteSync(recursive: true);
  });

  /// A REAL legacy GitHub-zipball import as produced by older builds:
  /// the repository content lives inside `owner-repo-sha/`, hidden markers
  /// sit at the project root next to it.
  Future<ProjectService> newLegacyWrappedProject() async {
    final root = Directory(
        p.join(docsStub.path, 'projects', 'legacy-import'));
    final wrapper = Directory(
        p.join(root.path, 'ismail53101-codepilot-mobile-bfa1b2e'));
    final file = File(p.join(
        wrapper.path, 'lib', 'screens', 'chat_screen.dart'));
    file.createSync(recursive: true);
    file.writeAsStringSync('class ChatScreen {\n  // TODO chat\n}\n');
    File(p.join(wrapper.path, 'README.md'))
        .writeAsStringSync('# demo repo\n');
    File(p.join(root.path, '.codepilot_project'))
        .writeAsStringSync('legacy-import', flush: true);
    final svc = ProjectService();
    await svc.openProject('legacy-import');
    return svc;
  }

  group('canonical path resolution', () {
    test('wrapperDirName detects the legacy zipball layout', () async {
      final svc = await newLegacyWrappedProject();
      expect(svc.wrapperDirName, 'ismail53101-codepilot-mobile-bfa1b2e');
      expect(svc.contentRootPath, endsWith('ismail53101-codepilot-mobile-bfa1b2e'));
    });

    test('wrapperDirName is null for flat projects', () async {
      final root = Directory(p.join(docsStub.path, 'projects', 'flat'));
      final f = File(p.join(root.path, 'lib', 'main.dart'));
      f.createSync(recursive: true);
      f.writeAsStringSync('void main() {}\n');
      File(p.join(root.path, '.codepilot_project')).writeAsStringSync('flat');
      final svc = ProjectService();
      await svc.openProject('flat');
      expect(svc.wrapperDirName, isNull);
      expect(svc.contentRootPath, root.path);
    });

    test('normalizeProjectPath strips the wrapper prefix AND keeps bare form',
        () async {
      final svc = await newLegacyWrappedProject();
      expect(
        svc.normalizeProjectPath(
            'ismail53101-codepilot-mobile-bfa1b2e/lib/screens/chat_screen.dart'),
        'lib/screens/chat_screen.dart',
      );
      expect(
        svc.normalizeProjectPath('lib/screens/chat_screen.dart'),
        'lib/screens/chat_screen.dart',
      );
    });

    test('normalizeProjectPath rejects traversal, absolute and empty paths',
        () async {
      final svc = await newLegacyWrappedProject();
      expect(svc.normalizeProjectPath('../../etc/passwd'), isNull);
      expect(svc.normalizeProjectPath('lib/../../../etc/passwd'), isNull);
      expect(svc.normalizeProjectPath('/etc/passwd'), isNull);
      expect(svc.normalizeProjectPath(''), isNull);
      expect(svc.normalizeProjectPath('.'), isNull);
    });

    test('normalizeProjectPath drops a project-name prefix only when the '
        'stripped path exists (never clobbers a real folder)', () async {
      // Project literally named my-app with a nested lib/main.dart.
      final root = Directory(p.join(docsStub.path, 'projects', 'my-app'));
      final f = File(p.join(root.path, 'lib', 'main.dart'));
      f.createSync(recursive: true);
      f.writeAsStringSync('void main() {}\n');
      File(p.join(root.path, '.codepilot_project')).writeAsStringSync('my-app');
      final svc = ProjectService();
      await svc.openProject('my-app');

      expect(svc.normalizeProjectPath('my-app/lib/main.dart'),
          'lib/main.dart');
      // A REAL top-level folder named my-app is never stripped.
      Directory(p.join(root.path, 'my-app')).createSync();
      expect(svc.normalizeProjectPath('my-app/lib/main.dart'),
          'my-app/lib/main.dart');
    });

    test('fileTree and search report repository-relative paths', () async {
      final svc = await newLegacyWrappedProject();
      final paths = [for (final n in svc.fileTree()) n.path];
      expect(paths, contains('lib/screens/chat_screen.dart'));
      expect(paths, isNot(contains(
          'ismail53101-codepilot-mobile-bfa1b2e/lib/screens/chat_screen.dart')));
      final hits = svc.search('ChatScreen');
      expect(hits, hasLength(1));
      expect(hits.single.path, 'lib/screens/chat_screen.dart');
    });

    test('detectType sees the real project files through the wrapper',
        () async {
      final svc = await newLegacyWrappedProject();
      expect(svc.detectType(), 'Unknown'); // fixture has no marker files
      final pubspec = File(p.join(svc.contentRoot.path, 'pubspec.yaml'));
      pubspec.writeAsStringSync('name: demo\n');
      expect(svc.detectType(), 'Flutter');
    });
  });

  group('agent tool flow: search → read → patch → read', () {
    test('the exact reported bug: search hit path resolves for read and patch',
        () async {
      final svc = await newLegacyWrappedProject();
      final registry = ToolRegistry(
        projects: svc,
        github: _RecordingGitHub(SettingsStore()),
        repoStore: GitHubProjectStore(SettingsStore()),
      );

      // 1. search_code finds the file.
      final search =
          await registry.execute('search_code', {'query': 'ChatScreen'});
      expect(search, contains('lib/screens/chat_screen.dart'));

      // 2. read_file accepts BOTH the bare and the wrapper-prefixed form
      //    (legacy search results / model habits) and returns the content.
      final bare = await registry
          .execute('read_file', {'path': 'lib/screens/chat_screen.dart'});
      expect(bare, contains('class ChatScreen'));

      final prefixed = await registry.execute('read_file', {
        'path': 'ismail53101-codepilot-mobile-bfa1b2e/lib/screens/chat_screen.dart',
      });
      expect(prefixed, bare);

      // 3. patch_file with the prefixed path patches the SAME file.
      final patched = await registry.execute('patch_file', {
        'path':
            'ismail53101-codepilot-mobile-bfa1b2e/lib/screens/chat_screen.dart',
        'old_text': '// TODO chat',
        'new_text': '// implemented!',
      });
      expect(patched, startsWith('OK: patched'));

      // 4. re-read (bare this time) shows the patch — one file, one truth.
      final reread = await registry
          .execute('read_file', {'path': 'lib/screens/chat_screen.dart'});
      expect(reread, contains('// implemented!'));
      expect(reread, isNot(contains('// TODO chat')));
      expect(
        File(p.join(svc.contentRoot.path, 'lib', 'screens', 'chat_screen.dart'))
            .readAsStringSync(),
        contains('// implemented!'),
      );
    });

    test('traversal and absolute paths are refused before any disk access',
        () async {
      final svc = await newLegacyWrappedProject();
      final registry = ToolRegistry(
        projects: svc,
        github: _RecordingGitHub(SettingsStore()),
        repoStore: GitHubProjectStore(SettingsStore()),
      );
      expect(await registry.execute('read_file', {'path': '../../etc/passwd'}),
          startsWith('ERROR'));
      expect(await registry.execute('read_file', {'path': '/etc/passwd'}),
          startsWith('ERROR'));
      expect(
        await registry.execute('write_file',
            {'path': 'a/../../escaped.txt', 'content': 'x'}),
        startsWith('ERROR'),
      );
      expect(File(p.join(docsStub.path, 'escaped.txt')).existsSync(), isFalse);
    });
  });

  group('git status / diff against the baseline', () {
    test('clean after import, M after edit, exact repository-relative path',
        () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();

      var changes = await svc.changedFilesSinceBaseline();
      expect(changes, isEmpty);

      svc.writeFile('lib/screens/chat_screen.dart',
          'class ChatScreen {\n  // implemented!\n}\n');
      changes = await svc.changedFilesSinceBaseline();

      expect(changes, hasLength(1));
      expect(changes.single.status, 'M');
      expect(changes.single.path, 'lib/screens/chat_screen.dart');
    });

    test('legacy baseline keys are migrated, not reported as A+D noise',
        () async {
      final svc = await newLegacyWrappedProject();
      // A legacy manifest recorded hashes under the wrapper-prefixed path
      // and included marker files.
      final current = File(
              p.join(svc.contentRoot.path, 'lib', 'screens', 'chat_screen.dart'))
          .readAsStringSync();
      final legacyHash =
          current.hashCode.toRadixString(36); // legacy hashing scheme value
      await svc.updateManifest({
        'baselineHashes': {
          'ismail53101-codepilot-mobile-bfa1b2e/lib/screens/chat_screen.dart':
              legacyHash,
          '.codepilot_manifest.json': 'whatever',
          '.codepilot_project': 'whatever',
        },
      });

      // Same content under its new canonical key → NO change reported;
      // marker entries are dropped instead of shown as A+D.
      final changes = await svc.changedFilesSinceBaseline();
      expect(changes, isEmpty);
    });

    test('unmodified content is NOT reported as changed (real sha-1 diff)',
        () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      // Touch the file (same content) — must NOT be a false positive.
      File(p.join(svc.contentRoot.path, 'lib', 'screens', 'chat_screen.dart'))
          .setLastModifiedSync(DateTime.now());
      final changes = await svc.changedFilesSinceBaseline();
      expect(changes, isEmpty);
    });

    test('deleted files report D, new files report A', () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      svc.deleteFile('README.md');
      svc.writeFile('lib/new.dart', 'new\n');
      final changes = await svc.changedFilesSinceBaseline();
      final byStatus = {for (final c in changes) c.status: c.path};
      expect(byStatus['D'], 'README.md');
      expect(byStatus['A'], 'lib/new.dart');
    });
  });

  group('git_commit / git_push through the registry', () {
    Future<ToolRegistry> registryWithLinkedRepo(
        ProjectService svc, GitHubService github) async {
      final store = SettingsStore();
      await store.saveGitHubProject('ismail53101', 'codepilot-mobile', 'main');
      return ToolRegistry(
        projects: svc,
        github: github,
        repoStore: GitHubProjectStore(store, projects: svc),
      );
    }

    test('a clean tree refuses to commit — nothing is sent to GitHub',
        () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      final github = _RecordingGitHub(SettingsStore());
      final registry = await registryWithLinkedRepo(svc, github);

      final result =
          await registry.execute('git_commit', {'message': 'no-op attempt'});
      expect(result, startsWith('NOTHING TO COMMIT'));
      expect(github.commits, isEmpty); // no API call was made
    });

    test('commit sends ONLY the changed files with repository-relative paths '
        'and refreshes the baseline', () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      // One modification + one deletion + one addition.
      svc.writeFile('lib/screens/chat_screen.dart', 'class Patched {}\n');
      svc.deleteFile('README.md');
      svc.writeFile('lib/new_file.dart', 'new\n');

      final github = _RecordingGitHub(SettingsStore());
      final registry = await registryWithLinkedRepo(svc, github);

      final result =
          await registry.execute('git_commit', {'message': 'feature work'});
      expect(result, startsWith('OK: commit deadbeef'));
      expect(result, contains('M lib/screens/chat_screen.dart'));
      expect(result, contains('D README.md'));
      expect(result, contains('A lib/new_file.dart'));

      expect(github.commits, hasLength(1));
      final payload = github.commits.single;
      expect(payload.keys.toSet(),
          {'lib/screens/chat_screen.dart', 'README.md', 'lib/new_file.dart'});
      // Binary-safe payload: raw bytes (base64-upstream), not decoded text.
      expect(payload['lib/screens/chat_screen.dart'], 'class Patched {}\n'.codeUnits);
      expect(payload['README.md'], isNull); // deletion marker
      expect(payload['lib/new_file.dart'], 'new\n'.codeUnits);
      // CodePilot's own bookkeeping never enters the repository.
      expect(payload.keys.any((k) => k.startsWith('.codepilot_')), isFalse);
      expect(
          payload.keys.any((k) => k.startsWith('ismail53101-')), isFalse);

      // Baseline refreshed → the working tree is now clean (git diff empty).
      final after = await svc.changedFilesSinceBaseline();
      expect(after, isEmpty);
    });

    test('a failed commit surfaces the exact GitHub error and is honest',
        () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      svc.writeFile('lib/screens/chat_screen.dart', 'changed\n');

      final registry = await registryWithLinkedRepo(svc, _FailingGitHub(
          SettingsStore()));
      final result =
          await registry.execute('git_commit', {'message': 'should fail'});
      expect(result, startsWith('ERROR'));
      expect(result, contains('Bad credentials (HTTP 401)'));
      // The failure is NOT reported as a commit: manifest stays empty.
      final manifest = await svc.loadManifest();
      expect(manifest.containsKey('lastCommitSha'), isFalse);
    });

    test('git_push pushes real changes and refuses an empty push', () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      final github = _RecordingGitHub(SettingsStore());
      final registry = await registryWithLinkedRepo(svc, github);

      final clean = await registry
          .execute('git_push', {'message': 'empty push'});
      expect(clean, startsWith('NOTHING TO PUSH'));

      svc.writeFile('lib/screens/chat_screen.dart', 'pushed!\n');
      final result =
          await registry.execute('git_push', {'message': 'push work'});
      expect(result, startsWith('OK: commit deadbeef'));
      expect(github.commits.single.keys, ['lib/screens/chat_screen.dart']);
    });

    test('git_status reports the linked remote and the real diff', () async {
      final svc = await newLegacyWrappedProject();
      await svc.snapshotBaseline();
      final github = _RecordingGitHub(SettingsStore());
      final registry = await registryWithLinkedRepo(svc, github);

      svc.writeFile('lib/screens/chat_screen.dart', 'changed\n');
      final status = await registry.execute('git_status', {});
      expect(status, contains('remote: ismail53101/codepilot-mobile'));
      expect(status, contains('M  lib/screens/chat_screen.dart'));
    });
  });

  group('fresh GitHub-zipball imports are flattened at import time', () {
    test('importZip of an owner-repo-sha zipball produces bare paths',
        () async {
      // Build a real GitHub-style zipball: single top folder owner-repo-sha.
      final archive = Archive()
        ..addFile(ArchiveFile('ismail53101-codepilot-mobile-12cea2d/', 0, ''))
        ..addFile(ArchiveFile(
            'ismail53101-codepilot-mobile-12cea2d/lib/main.dart',
            'void main() {}\n'.length,
            'void main() {}\n'))
        ..addFile(ArchiveFile('ismail53101-codepilot-mobile-12cea2d/README.md',
            '# hi\n'.length, '# hi\n'));
      final zipPath = p.join(docsStub.path, 'ball.zip');
      File(zipPath)
          .writeAsBytesSync(ZipEncoder().encode(archive)!, flush: true);

      final svc = ProjectService();
      await svc.importZip(zipPath, name: 'codepilot-mobile');

      expect(svc.wrapperDirName, isNull); // wrapper dropped at import
      final paths = [for (final n in svc.fileTree()) n.path];
      expect(paths, containsAll(['lib/main.dart', 'README.md']));
      // The baseline is recorded under the SAME bare keys → clean tree.
      final changes = await svc.changedFilesSinceBaseline();
      expect(changes, isEmpty);
      // The repository snapshot is publish-ready: bare, no wrapper prefix.
      final snapshot = svc.repositorySnapshot();
      expect(snapshot.keys.toSet(), {'lib/main.dart', 'README.md'});
    });

    test('a plain ZIP (no wrapper folder) still imports unchanged', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('app/main.py', 'print(1)\n'.length, 'print(1)\n'))
        ..addFile(ArchiveFile('app/util.py', 'x = 1\n'.length, 'x = 1\n'));
      final zipPath = p.join(docsStub.path, 'plain.zip');
      File(zipPath)
          .writeAsBytesSync(ZipEncoder().encode(archive)!, flush: true);

      final svc = ProjectService();
      await svc.importZip(zipPath, name: 'plain-app');
      final paths = [for (final n in svc.fileTree()) n.path];
      expect(paths, containsAll(['app/main.py', 'app/util.py']));
      expect(await svc.changedFilesSinceBaseline(), isEmpty);
    });
  });
}
