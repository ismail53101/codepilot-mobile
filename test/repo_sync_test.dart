import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:codepilot_mobile/github_service.dart';
import 'package:codepilot_mobile/project_service.dart';
import 'package:codepilot_mobile/stores.dart';

/// Redirects path_provider to an isolated temp directory.
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsStub;

  setUp(() {
    // Redirect path_provider to an isolated temp dir for this test.
    docsStub = Directory.systemTemp.createTempSync('repo_sync_test');
    PathProviderPlatform.instance = _FakePathProvider(docsStub.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (docsStub.existsSync()) docsStub.deleteSync(recursive: true);
  });

  /// Real ProjectService rooted in the temp dir.
  Future<ProjectService> newProject(String name,
      {Map<String, String> files = const {}}) async {
    final dir = Directory(p.join(docsStub.path, 'projects', name));
    dir.createSync(recursive: true);
    for (final e in files.entries) {
      File(p.join(dir.path, e.key))
        ..createSync(recursive: true)
        ..writeAsStringSync(e.value);
    }
    final svc = ProjectService();
    await svc.openProject(name);
    return svc;
  }

  group('linkGitHubRepo + resolveForActiveProject', () {
    test('linking writes the canonical manifest fields', () async {
      final svc = await newProject('demo');
      await svc.linkGitHubRepo('ismail53101', 'codepilot-mobile',
          branch: 'main');
      final m = await svc.loadManifest();
      expect(m['gitRepository'], 'ismail53101/codepilot-mobile');
      expect(m['gitBranch'], 'main');
    });

    test('resolveForActiveProject without projects falls back to prefs',
        () async {
      final store = SettingsStore();
      await store.saveGitHubProject('octocat', 'hello', 'main');
      final repoStore = GitHubProjectStore(store); // no projects injected
      final repo = await repoStore.resolveForActiveProject();
      expect(repo!.fullName, 'octocat/hello');
    });

    test('snapshotFiles excludes CodePilot metadata but keeps project files',
        () async {
      final svc = await newProject('demo', files: {
        'index.html': '<html></html>',
        'lib/main.dart': 'void main() {}',
      });
      await svc.updateManifest({'note': 'x'});
      final snap = svc.snapshotFiles();
      expect(snap.keys, containsAll(['index.html', 'lib/main.dart']));
      expect(snap.keys, isNot(contains('.codepilot_manifest.json')));
      expect(snap.keys, isNot(contains('.codepilot_project')));
    });

    test('snapshotFiles preserves codefexa_logo.png as raw bytes', () async {
      final svc = await newProject('binary-demo');
      final png = <int>[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0xff, 0x00, 0x80,
      ];
      final file = File(p.join(
          svc.root.path, 'android/app/src/main/res/drawable/codefexa_logo.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(png);

      final snapshot = svc.snapshotFiles();
      expect(snapshot['android/app/src/main/res/drawable/codefexa_logo.png'],
          orderedEquals(png));
      expect(file.readAsBytesSync(), orderedEquals(png));
      await expectLater(svc.changedFilesSinceBaseline(), completes);
    });
  });

  group('manifest round-trip with null (stale-link clearing)', () {
    test('updateManifest can clear the git link', () async {
      final svc = await newProject('demo');
      await svc.linkGitHubRepo('o', 'r', branch: 'b');
      await svc.updateManifest({'gitRepository': null, 'gitBranch': null});
      final m = await svc.loadManifest();
      expect(m.containsKey('gitRepository') && m['gitRepository'] != null,
          isFalse);
    });
  });

  group('zipball recovery against a real project folder', () {
    test('recovered repo matches the imported layout', () async {
      final svc = await newProject('codepilot-mobile');
      Directory(p.join(svc.root.path, 'ismail53101-codepilot-mobile-12cea2d'))
          .createSync();
      final recovered = githubRepoFromZipballLayout(svc.rootEntryNames);
      expect(recovered!.fullName, 'ismail53101/codepilot-mobile');
    });
  });

  // Silence unused import warnings for jsonEncode in stricter analyzers.
  test('json helper smoke', () {
    expect(jsonEncode({'a': 1}), '{"a":1}');
  });
}
