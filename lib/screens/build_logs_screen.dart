import 'dart:io';

import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Build Logs screen: analyze / dependency check / analysis / tests / APK.
///
/// Honesty policy: the Flutter toolchain and Android SDK/Gradle are NOT
/// available inside an Android app sandbox, so these commands are NOT faked.
/// Every action either (a) runs a real static check that is possible locally,
/// or (b) reports that the toolchain is unavailable and offers the GitHub
/// Actions remote-build path. Nothing reports success that did not happen.
class BuildLogsScreen extends StatefulWidget {
  const BuildLogsScreen({super.key});

  @override
  State<BuildLogsScreen> createState() => _BuildLogsScreenState();
}

class _BuildLogsScreenState extends State<BuildLogsScreen> {
  final List<String> _log = [];
  String? _status; // ok | failed | unavailable
  bool _busy = false;

  void _logLine(String s) => setState(() => _log.add(s));

  void _reset() => setState(() { _log.clear(); _status = null; });

  /// Real local checks that DO work on-device (pure file inspection).
  Future<void> _analyzeProject() async {
    _reset();
    setState(() { _busy = true; });
    try {
      final type = projectService.detectType();
      _logLine('Project type detected: $type');
      _logLine('Project name: ${projectService.projectName}');
      final nodes = projectService.fileTree();
      _logLine('Entries (build/cache dirs skipped): ${nodes.length}');
      final files = nodes.where((n) => !n.isDir).toList();
      _logLine('Files: ${files.length} · Dirs: ${nodes.length - files.length}');

      switch (type) {
        case 'Flutter':
          final pubspec = projectService.readFile('pubspec.yaml');
          final envKeys = (pubspec ?? '').split('\n').where((l) => l.contains('sdk:')).take(3).toList();
          _logLine('pubspec.yaml found. Environment constraints: ${envKeys.join(' | ')}');
          _logLine('test/ directory: ${Directory(projectService.root.path + '/test').existsSync() ? 'present' : 'missing'}');
          _logLine('lib/ directory: ${Directory(projectService.root.path + '/lib').existsSync() ? 'present' : 'missing'}');
          break;
        case 'Android':
          for (final f in ['build.gradle', 'build.gradle.kts', 'settings.gradle', 'gradle/wrapper/gradle-wrapper.properties']) {
            _logLine('$f: ${projectService.readFile(f) != null ? 'present' : 'missing'}');
          }
          break;
        case 'Python':
          for (final f in ['requirements.txt', 'pyproject.toml', 'main.py']) {
            _logLine('$f: ${projectService.readFile(f) != null ? 'present' : 'missing'}');
          }
          break;
        case 'Next.js' || 'React (Vite)' || 'Node.js':
          final pkg = projectService.readFile('package.json');
          _logLine('package.json found (${pkg?.length ?? 0} chars).');
          _logLine('node_modules: ${Directory(projectService.root.path + '/node_modules').existsSync() ? 'present' : 'missing (run dependency check on a machine with Node)'}');
          break;
        default:
          _logLine('No build system detected — static analysis only.');
      }
      _logLine('NOTE: on-device compile/toolchain commands are unavailable in the app sandbox.');
      _logLine('Use "Remote build (GitHub Actions)" below for a real APK.');
      setState(() => _status = 'ok');
    } on ProjectException catch (e) {
      _logLine('ERROR: ${e.message}');
      setState(() => _status = 'failed');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Dependency check: verifies lock/manifest presence and reports honestly
  /// that `flutter pub get` / `npm install` need the real toolchain.
  Future<void> _dependencyCheck() async {
    _reset();
    setState(() { _busy = true; });
    final type = projectService.detectType();
    final markers = switch (type) {
      'Flutter' => ['pubspec.yaml', 'pubspec.lock'],
      'Android' => ['build.gradle', 'gradle/wrapper/gradle-wrapper.properties'],
      'Next.js' || 'React (Vite)' || 'Node.js' => ['package.json', 'package-lock.json'],
      'Python' => ['requirements.txt', 'requirements.lock'],
      _ => <String>[],
    };
    for (final m in markers) {
      _logLine('$m: ${projectService.readFile(m) != null ? 'present' : 'missing'}');
    }
    if (markers.isEmpty) _logLine('No dependency manifest detected for type "$type".');
    _logLine('');
    _logLine('Dependency INSTALL commands require the real toolchain and cannot');
    _logLine('run inside the Android app. Run them remotely (GitHub Actions) or on a dev machine:');
    _logLine(switch (type) {
      'Flutter' => '  flutter pub get',
      'Next.js' || 'React (Vite)' || 'Node.js' => '  npm install',
      'Python' => '  pip install -r requirements.txt',
      'Android' => '  ./gradlew dependencies',
      _ => '  (project-specific)',
    });
    setState(() { _status = 'ok'; _busy = false; });
  }

  Future<void> _flutterAnalysis() async {
    _reset();
    if (projectService.detectType() != 'Flutter') {
      _logLine('ERROR: this project is not a Flutter project (no pubspec.yaml).');
      setState(() => _status = 'failed');
      return;
    }
    _logLine('flutter analyze requires the Flutter SDK, which is not available');
    _logLine('inside the Android app. Two real options:');
    _logLine(' 1. Push the project to GitHub and run the included Actions workflow.');
    _logLine(' 2. Run `flutter analyze` on a dev machine after Export.');
    _logLine('');
    _logLine('What WAS checked locally (real):');
    final lib = Directory(projectService.root.path + '/lib');
    if (lib.existsSync()) {
      final dartFiles = lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).length;
      _logLine('  Dart files under lib/: $dartFiles');
      for (final f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final content = f.readAsStringSync();
        if (content.contains('TODO') || content.contains('FIXME')) {
          _logLine('  ${f.path.split('/').last}: contains TODO/FIXME');
        }
      }
    } else {
      _logLine('  lib/ directory missing — not a valid Flutter app layout.');
      setState(() => _status = 'failed');
      return;
    }
    setState(() => _status = 'ok');
  }

  Future<void> _runTests() async {
    _reset();
    final testDir = Directory(projectService.root.path + '/test');
    if (!testDir.existsSync()) {
      _logLine('No test/ directory — nothing to run.');
      setState(() => _status = 'ok');
      return;
    }
    _logLine('Test files found:');
    for (final f in testDir.listSync(recursive: true).whereType<File>()) {
      _logLine('  ${f.path.split('/').last} (${f.lengthSync()} bytes)');
    }
    _logLine('');
    _logLine('Executing tests requires the project toolchain (flutter test /');
    _logLine('npm test / pytest) — unavailable inside the Android app sandbox.');
    _logLine('Run them via the included GitHub Actions workflow for real results.');
    setState(() => _status = 'ok');
  }

  Future<void> _buildApk() async {
    _reset();
    if (projectService.detectType() != 'Flutter') {
      _logLine('ERROR: APK build applies to Flutter projects only.');
      setState(() => _status = 'failed');
      return;
    }
    _logLine('`flutter build apk` needs the Flutter SDK + Android SDK, which do');
    _logLine('not run inside an Android app. THE BUILD WAS NOT RUN — no APK exists.');
    _logLine('');
    _logLine('Real paths to an APK:');
    _logLine(' 1. GitHub Actions (recommended):');
    _logLine('    a. Export ZIP → push to a GitHub repo');
    _logLine('    b. Add .github/workflows/flutter-build.yml (included in export notes)');
    _logLine('    c. Download app-debug.apk from the workflow artifacts');
    _logLine(' 2. Dev machine: flutter build apk --debug');
    setState(() => _status = 'unavailable');
  }

  Future<void> _remoteBuild() async {
    _reset();
    _logLine('GitHub Actions build — setup steps:');
    _logLine(' 1. Export the project (Home → Export ZIP).');
    _logLine(' 2. Push it to a GitHub repository.');
    _logLine(' 3. Add this workflow at .github/workflows/flutter-build.yml:');
    _logLine('');
    _logLine('    name: flutter-build');
    _logLine('    on: [push, workflow_dispatch]');
    _logLine('    jobs:');
    _logLine('      build:');
    _logLine('        runs-on: ubuntu-latest');
    _logLine('        steps:');
    _logLine('          - uses: actions/checkout@v4');
    _logLine('          - uses: subosito/flutter-action@v2');
    _logLine('            with: {flutter-version: "3.24.0"}');
    _logLine('          - run: flutter pub get');
    _logLine('          - run: flutter analyze');
    _logLine('          - run: flutter test');
    _logLine('          - run: flutter build apk --debug');
    _logLine('          - uses: actions/upload-artifact@v4');
    _logLine('            with: {name: app-debug-apk, path: build/app/outputs/flutter-apk/app-debug.apk}');
    _logLine('');
    _logLine(' 4. Download the APK from Actions → run → Artifacts.');
    setState(() => _status = 'ok');
  }

  @override
  Widget build(BuildContext context) {
    if (projectService.projectName == null) {
      return Scaffold(appBar: AppBar(title: const Text('Build')), body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('No project open.'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pushNamed(context, '/import'), child: const Text('Import Project')),
        ])));
    }
    final type = projectService.detectType();
    return Scaffold(
      appBar: AppBar(title: Text('Build · $type')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : _analyzeProject, child: const Text('Analyze project')),
          OutlinedButton(onPressed: _busy ? null : _dependencyCheck, child: const Text('Dependency check')),
          OutlinedButton(onPressed: _busy ? null : _flutterAnalysis, child: const Text('Flutter analysis')),
          OutlinedButton(onPressed: _busy ? null : _runTests, child: const Text('Run tests')),
          FilledButton(onPressed: _busy ? null : _buildApk, child: const Text('Build APK')),
          OutlinedButton.icon(onPressed: _busy ? null : _remoteBuild, icon: const Icon(Icons.cloud_upload), label: const Text('Remote build')),
        ])),
        if (_status != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child:
          Align(alignment: Alignment.centerLeft, child: _status == 'ok'
            ? const Text('✓ Completed', style: TextStyle(color: AppTheme.ok, fontWeight: FontWeight.w600))
            : _status == 'failed'
              ? const Text('✗ Failed', style: TextStyle(color: AppTheme.err, fontWeight: FontWeight.w600))
              : const Text('⚠ Toolchain unavailable — remote build required', style: TextStyle(color: AppTheme.warn, fontWeight: FontWeight.w600)))),
        Expanded(child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(10),
          width: double.infinity,
          decoration: BoxDecoration(color: const Color(0xFF0A0D12), border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
          child: _log.isEmpty
            ? Text('Press an action above. Real local checks run where possible; toolchain builds are routed to GitHub Actions.', style: TextStyle(color: AppTheme.muted))
            : SingleChildScrollView(child: SelectableText(_log.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)))),
        ),
      ]),
    );
  }
}
