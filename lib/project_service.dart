import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart' show Icons, IconData;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Local project workspace: ZIP import, file tree, read, full-text search,
/// and ZIP export. All operations run against a real directory on device.
class ProjectService {
  Directory? _root; // <appdocs>/projects/<name>
  String? _projectName;

  String? get projectName => _projectName;

  /// Absolute path of the open project root (for the terminal cwd).
  String? get rootPath => _root?.path;

  // ---------------- last-project persistence ----------------

  static const _kLastProject = 'last_project';

  /// Remember the open project so it survives app restarts.
  Future<void> _persistLastProject() async {
    final prefs = await SharedPreferences.getInstance();
    if (_projectName == null) {
      await prefs.remove(_kLastProject);
    } else {
      await prefs.setString(_kLastProject, _projectName!);
    }
  }

  /// Restore the previously opened project after an app restart.
  /// Returns true when a project was restored.
  Future<bool> restoreLastProject() async {
    if (_root != null) return true;
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kLastProject);
    if (name == null || name.isEmpty) return false;
    try {
      await openProject(name);
      return true;
    } on ProjectException {
      await prefs.remove(_kLastProject); // stale entry — clean up
      return false;
    }
  }

  // ---------------- agent workspace manifest ----------------

  /// The agent's working manifest, stored inside the project:
  /// plan, changed files, verification results, and the last commit.
  /// Written ONLY by real agent tool executions — the UI reads it to show
  /// what actually happened, never to fake activity.
  Future<Map<String, dynamic>> loadManifest() async {
    try {
      final f = File(p.join(root.path, '.codepilot_manifest.json'));
      if (!f.existsSync()) return {};
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> updateManifest(Map<String, dynamic> patch) async {
    final current = await loadManifest();
    current.addAll(patch);
    current['updatedAt'] = DateTime.now().toIso8601String();
    final f = File(p.join(root.path, '.codepilot_manifest.json'));
    f.writeAsStringSync(jsonEncode(current), flush: true);
  }

  /// Record one file change in the manifest's changed-file list.
  Future<void> recordChangeInManifest(String path, String kind) async {
    final m = await loadManifest();
    final changed = List<Map<String, dynamic>>.from(
        (m['changedFiles'] as List?)?.whereType<Map>().map(Map<String, dynamic>.from) ?? const []);
    changed.removeWhere((c) => c['path'] == path);
    changed.add({'path': path, 'kind': kind, 'time': DateTime.now().toIso8601String()});
    await updateManifest({'changedFiles': changed});
  }

  /// Compare working tree against the manifest's baseline hashes to produce
  /// a real git-status-like report (M = content differs, A = new, D = deleted).
  Future<List<GitFileChange>> changedFilesSinceBaseline() async {
    final m = await loadManifest();
    final baseline = Map<String, String>.from(m['baselineHashes'] as Map? ?? {});
    final out = <GitFileChange>[];
    final seen = <String>{};
    for (final node in fileTree()) {
      if (node.isDir || node.path == '.codepilot_manifest.json') continue;
      seen.add(node.path);
      final content = readFile(node.path);
      final hash = content == null ? '' : content.hashCode.toRadixString(36);
      if (!baseline.containsKey(node.path)) {
        out.add(GitFileChange(node.path, 'A'));
      } else if (baseline[node.path] != hash) {
        out.add(GitFileChange(node.path, 'M'));
      }
    }
    for (final path in baseline.keys) {
      if (!seen.contains(path)) out.add(GitFileChange(path, 'D'));
    }
    return out;
  }

  /// Snapshot current file hashes as the new baseline (after a commit).
  Future<void> snapshotBaseline() async {
    final hashes = <String, String>{};
    for (final node in fileTree()) {
      if (node.isDir || node.path == '.codepilot_manifest.json') continue;
      final content = readFile(node.path);
      if (content != null) hashes[node.path] = content.hashCode.toRadixString(36);
    }
    await updateManifest({'baselineHashes': hashes});
  }

  /// Directory where imported/created projects live.
  Future<Directory> projectsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'projects'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<String>> listProjects() async {
    final dir = await projectsDir();
    final names = <String>[];
    for (final e in dir.listSync()) {
      if (e is Directory && File(p.join(e.path, '.codepilot_project')).existsSync()) {
        names.add(p.basename(e.path));
      }
    }
    names.sort();
    return names;
  }

  /// Import a picked ZIP: extract into projects/<zipName or name>/.
  Future<String> importZip(String zipPath, {String? name}) async {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.isEmpty) throw const ProjectException('The ZIP file is empty.');

    // If the zip has a single top folder, use it as the project name.
    var top = <String>{};
    for (final f in archive) {
      final parts = f.name.split('/');
      if (parts.isNotEmpty && parts.first.isNotEmpty) top.add(parts.first);
    }
    final baseName = (name ??
            (top.length == 1 ? top.first : p.basenameWithoutExtension(zipPath)))
        .replaceAll(RegExp(r'[^\w\-. ]'), '_');
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, baseName));
    if (root.existsSync()) {
      throw ProjectException('A project named "$baseName" already exists.');
    }
    root.createSync(recursive: true);

    var count = 0;
    for (final f in archive) {
      final safe = _safeJoin(root.path, f.name);
      if (safe == null) continue; // zip-slip guard
      if (f.isFile) {
        final out = File(safe);
        out.createSync(recursive: true);
        out.writeAsBytesSync(f.content as List<int>);
        count++;
      } else {
        Directory(safe).createSync(recursive: true);
      }
    }
    File(p.join(root.path, '.codepilot_project'))
        .writeAsStringSync(baseName, flush: true);
    _root = root;
    _projectName = baseName;
    await _persistLastProject();
    await snapshotBaseline();
    return 'Imported $count files into "$baseName".';
  }

  /// Create an empty project (e.g. from "New project").
  Future<String> createProject(String name) async {
    final clean = _cleanProjectName(name);
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, clean));
    if (root.existsSync()) {
      throw ProjectException('A project named "$clean" already exists.');
    }
    root.createSync(recursive: true);
    _writeProjectMarker(root, clean, ProjectTemplate.blank);
    _root = root;
    _projectName = clean;
    await _persistLastProject();
    await snapshotBaseline();
    return clean;
  }

  String _cleanProjectName(String name) {
    final clean = name.replaceAll(RegExp(r'[^\w\-. ]'), '_').trim();
    if (clean.isEmpty) throw const ProjectException('Project name is empty.');
    return clean;
  }

  void _writeProjectMarker(Directory root, String name, ProjectTemplate t) {
    File(p.join(root.path, '.codepilot_project')).writeAsStringSync(
        jsonEncode({
          'name': name,
          'template': t.id,
          'created': DateTime.now().toIso8601String(),
        }),
        flush: true);
  }

  /// Create a REAL project workspace from a template: writes actual files
  /// the agent can immediately inspect and modify. GitHub is NOT involved.
  /// Create a real workspace from a template. [onProgress] reports real
  /// creation stages — every tick corresponds to files actually written,
  /// never a fake timer — so the UI can show a Manus-style build timeline.
  Future<String> createProjectFromTemplate(
      String name, ProjectTemplate template,
      {void Function(int done, int total, String currentPath)? onProgress}) async {
    final clean = _cleanProjectName(name);
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, clean));
    if (root.existsSync()) {
      throw ProjectException('A project named "$clean" already exists.');
    }
    root.createSync(recursive: true);
    final safeName = clean.replaceAll('_', ' ');

    final total = template.files.length + template.dirs.length;
    var done = 0;

    for (final f in template.files) {
      final out = resolveFileIn(root, f.path);
      out.createSync(recursive: true);
      out.writeAsStringSync(
          f.content.replaceAll('__PROJECT_NAME__', safeName),
          flush: true);
      done++;
      onProgress?.call(done, total, f.path);
      // Yield to the event loop between files so the progress UI animates
      // even for fast templates (real work drives every tick).
      await Future<void>.delayed(Duration.zero);
    }
    for (final d in template.dirs) {
      Directory(p.join(root.path, d)).createSync(recursive: true);
      done++;
      onProgress?.call(done, total, '$d/');
      await Future<void>.delayed(Duration.zero);
    }

    _writeProjectMarker(root, clean, template);
    _root = root;
    _projectName = clean;
    await _persistLastProject();
    await snapshotBaseline();
    return clean;
  }

  /// Open an existing project by name.
  Future<void> openProject(String name) async {
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, name));
    if (!root.existsSync()) throw ProjectException('Project "$name" not found.');
    _root = root;
    _projectName = name;
    await _persistLastProject();
  }

  /// Resolve a path inside an ARBITRARY root (used by templates).
  static File resolveFileIn(Directory root, String rel) {
    final normalized = p.normalize(rel);
    if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
      throw ProjectException('Path outside the project is not allowed: $rel');
    }
    return File(p.join(root.path, normalized));
  }

  /// Root of the open project; throws if none is open.
  Directory get root {
    final r = _root;
    if (r == null) throw const ProjectException('No project is open.');
    return r;
  }

  /// Resolve a relative path INSIDE the project; blocks ../ and absolute paths.
  File resolveFile(String rel) {
    final normalized = p.normalize(rel);
    if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
      throw ProjectException('Path outside the project is not allowed: $rel');
    }
    final f = File(p.join(root.path, normalized));
    final rootPath = p.normalize(root.path);
    final filePath = p.normalize(f.path);
    if (!p.isWithin(rootPath, filePath)) {
      throw ProjectException('Path outside the project is not allowed: $rel');
    }
    return f;
  }

  /// Full recursive file tree (files + dirs), relative paths, sorted.
  List<FileNode> fileTree() {
    final nodes = <FileNode>[];
    final rootPath = root.path;
    void walk(Directory d) {
      for (final e in d.listSync()) {
        final rel = p.relative(e.path, from: rootPath).replaceAll('\\', '/');
        final segs = rel.split('/');
        if (segs.any(_skipDirs.contains)) continue;
        if (e is Directory) {
          nodes.add(FileNode(path: rel, isDir: true));
          walk(e);
        } else if (e is File) {
          nodes.add(FileNode(path: rel, isDir: false, size: e.lengthSync()));
        }
      }
    }

    walk(root);
    nodes.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return nodes;
  }

  static const _skipDirs = {
    '.git', 'node_modules', 'build', '.dart_tool', '.gradle', '.idea',
    '__pycache__', '.venv', 'dist', '.next', 'Pods',
  };

  String? readFile(String rel) {
    final f = resolveFile(rel);
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  /// Write inside the project (used only by the confirmed agent flow).
  void writeFile(String rel, String content) {
    final f = resolveFile(rel);
    f.createSync(recursive: true);
    f.writeAsStringSync(content, flush: true);
  }

  void deleteFile(String rel) {
    final f = resolveFile(rel);
    if (f.existsSync()) f.deleteSync();
  }

  /// Rename/move a file (or directory) within the project. Returns the
  /// destination relative path.
  String moveFile(String from, String to) {
    final src = resolveFile(from);
    if (!src.existsSync()) {
      throw ProjectException('Not found: $from');
    }
    final dst = resolveFile(to);
    if (dst.existsSync()) {
      throw ProjectException('Destination already exists: $to');
    }
    dst.parent.createSync(recursive: true);
    final moved = src.renameSync(dst.path); // rename works for dirs too
    return p.relative(moved.path, from: root.path).replaceAll('\\', '/');
  }

  /// Direct children (one level) of a directory, relative paths.
  List<FileNode> listDir(String rel) {
    final dir = Directory(p.join(root.path, p.normalize(rel)));
    final rootPath = p.normalize(root.path);
    if (!p.isWithin(rootPath, p.normalize(dir.path))) {
      throw ProjectException('Path outside the project is not allowed: $rel');
    }
    if (!dir.existsSync()) {
      throw ProjectException('Directory not found: $rel');
    }
    final out = <FileNode>[];
    for (final e in dir.listSync()) {
      final r = p.relative(e.path, from: root.path).replaceAll('\\', '/');
      if (r.split('/').any(_skipDirs.contains)) continue;
      if (e is Directory) {
        out.add(FileNode(path: r, isDir: true));
      } else if (e is File) {
        out.add(FileNode(path: r, isDir: false, size: e.lengthSync()));
      }
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return out;
  }

  /// Full-text search across text files (case-insensitive substring or regex).
  List<SearchHit> search(String query, {bool regex = false}) {
    if (query.trim().isEmpty) return [];
    RegExp? re;
    if (regex) {
      try {
        re = RegExp(query, caseSensitive: false);
      } on FormatException {
        re = RegExp(RegExp.escape(query), caseSensitive: false);
      }
    }
    final hits = <SearchHit>[];
    for (final node in fileTree()) {
      if (node.isDir || node.size > 512 * 1024) continue;
      final f = File(p.join(root.path, node.path));
      String content;
      try {
        content = f.readAsStringSync();
      } catch (_) {
        continue; // binary or unreadable
      }
      if (_binary(content)) continue;
      final lines = content.split('\n');
      for (var i = 0; i < lines.length && hits.length < 300; i++) {
        final line = lines[i];
        final hit = re != null ? re.hasMatch(line) : line.toLowerCase().contains(query.toLowerCase());
        if (hit) hits.add(SearchHit(node.path, i + 1, line.trim().substring(0, line.trim().length.clamp(0, 200))));
      }
    }
    return hits;
  }

  bool _binary(String s) {
    final check = s.length > 512 ? s.substring(0, 512) : s;
    for (final ch in check.codeUnits) {
      if (ch < 9 || (ch > 13 && ch < 32)) return true;
    }
    return false;
  }

  /// Internal metadata / runtime files that must never appear in an
  /// exported ZIP.
  static const _internalFiles = {
    '.codepilot_exclude',
    '.codepilot_manifest.json',
    '.codepilot_project.json',
  };
  static const _internalDirs = {'.git'};

  /// Build the export archive in memory: the current state of every project
  /// file, minus internal metadata (manifest, marker, exclude list) and the
  /// .git directory. Returns the raw ZIP bytes for download/share.
  List<int> zipBytes() {
    final rootDir = root;
    final excludeFile = File(p.join(rootDir.path, '.codepilot_exclude'));
    final exclude = <String>{
      ..._internalFiles,
      if (excludeFile.existsSync())
        ...excludeFile
            .readAsLinesSync()
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty),
    };

    final archive = Archive();
    void addDir(Directory dir, String prefix) {
      for (final entity in dir.listSync(recursive: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_internalDirs.contains(name)) continue;
          addDir(entity, prefix.isEmpty ? name : '$prefix/$name');
        } else if (entity is File) {
          if (_internalFiles.contains(name)) continue; // metadata never exports
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          // Honor user exclusions (path or substring match, like before).
          if (exclude.any((pat) => rel == pat || rel.contains(pat))) continue;
          final bytes = entity.readAsBytesSync();
          archive.addFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }
    }

    addDir(rootDir, '');
    return ZipEncoder().encode(archive)!;
  }

  /// Export the project as a ZIP file on disk (Export screen). Skips
  /// internal metadata and .codepilot_exclude entries — the API key lives
  /// in secure storage and is never part of the project directory.
  Future<String> exportZip() async {
    final dir = await projectsDir();
    final outPath = p.join(dir.path, '${_projectName}_export.zip');
    File(outPath).writeAsBytesSync(zipBytes(), flush: true);
    return outPath;
  }

  /// Project type guess from marker files (for build screen + context).
  String detectType() {
    final has = (String f) => File(p.join(root.path, f)).existsSync();
    if (has('pubspec.yaml')) return 'Flutter';
    if (has('build.gradle') || has('build.gradle.kts')) return 'Android';
    if (has('package.json')) {
      if (has('next.config.js') || has('next.config.mjs')) return 'Next.js';
      if (has('vite.config.ts') || has('vite.config.js')) return 'React (Vite)';
      return 'Node.js';
    }
    if (has('requirements.txt') || has('pyproject.toml')) return 'Python';
    if (has('index.html')) return 'HTML/CSS/JS';
    return 'Unknown';
  }

  /// The project's git metadata: branch and HEAD commit, read from .git.
  /// Returns null when the project has no .git directory.
  ({String branch, String head})? gitInfo() {
    final gitDir = Directory(p.join(root.path, '.git'));
    if (!gitDir.existsSync()) return null;
    String? branch;
    String? head;
    final headFile = File(p.join(gitDir.path, 'HEAD'));
    if (headFile.existsSync()) {
      final raw = headFile.readAsStringSync().trim();
      final m = RegExp(r'ref: refs/heads/(.+)').firstMatch(raw);
      branch = m?.group(1);
      if (branch == null) {
        // Detached HEAD: the raw value is the commit sha itself.
        branch = raw.substring(0, raw.length.clamp(0, 12));
        head = raw;
      } else {
        final refFile = File(p.join(gitDir.path, 'refs', 'heads', branch));
        if (refFile.existsSync()) head = refFile.readAsStringSync().trim();
      }
    }
    if (head == null || head.isEmpty) {
      // Packed refs fallback (clone created by this app may pack refs).
      final packed = File(p.join(gitDir.path, 'packed-refs'));
      if (packed.existsSync()) {
        for (final line in packed.readAsLinesSync()) {
          if (line.contains('refs/heads/${branch ?? ''}')) {
            head = line.split(' ').first.trim();
            break;
          }
        }
      }
    }
    if (branch == null) return null;
    return (branch: branch, head: head == null || head.isEmpty ? 'unknown' : head);
  }

  /// Unified line diff between two strings.
  List<DiffLine> diffLines(String before, String after) {
    final b = before.isEmpty ? const <String>[] : before.split('\n');
    final a = after.isEmpty ? const <String>[] : after.split('\n');
    final out = <DiffLine>[];
    // LCS-based diff is overkill on-device for typical files; use a simple
    // marker-based approach: show removed block then added block per hunk.
    var i = 0, j = 0;
    while (i < b.length || j < a.length) {
      if (i < b.length && j < a.length && b[i] == a[j]) {
        out.add(DiffLine('same', b[i]));
        i++;
        j++;
        continue;
      }
      // find next common line to bound this hunk
      var bi = -1, aj = -1;
      outer:
      for (var k = j; k < (j + 20).clamp(0, a.length); k++) {
        for (var m = i; m < (i + 20).clamp(0, b.length); m++) {
          if (b[m] == a[k]) {
            bi = m;
            aj = k;
            break outer;
          }
        }
      }
      if (bi == -1) {
        for (; i < b.length; i++) {
          out.add(DiffLine('del', b[i]));
        }
        for (; j < a.length; j++) {
          out.add(DiffLine('add', a[j]));
        }
        break;
      }
      for (; i < bi; i++) {
        out.add(DiffLine('del', b[i]));
      }
      for (; j < aj; j++) {
        out.add(DiffLine('add', a[j]));
      }
    }
    return out;
  }
}

class ProjectException implements Exception {
  final String message;
  const ProjectException(this.message);
  @override
  String toString() => message;
}

/// Zip-slip guard: reject entry names that escape the extraction root.
String? _safeJoin(String rootPath, String entryName) {
  final normalized = p.normalize(entryName);
  if (p.isAbsolute(normalized) || normalized.startsWith('..')) return null;
  return p.join(rootPath, normalized);
}

// =====================================================================
// Project templates — real starter files, written to the workspace.
// =====================================================================

/// One starter file in a template.
class TemplateFile {
  final String path;
  final String content;
  const TemplateFile(this.path, this.content);
}

/// A project template: id, label, and the REAL files created on disk.
/// Add new templates by appending to [all] — no other change needed.
class ProjectTemplate {
  final String id;
  final String label;
  final String description;
  final IconData icon;
  final List<String> dirs;
  final List<TemplateFile> files;

  const ProjectTemplate({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    this.dirs = const [],
    this.files = const [],
  });

  static const blank = ProjectTemplate(
    id: 'blank',
    label: 'Blank Project',
    description: 'Empty workspace — start from scratch',
    icon: Icons.crop_square,
  );

  static const flutterApp = ProjectTemplate(
    id: 'flutter_app',
    label: 'Flutter App',
    description: 'pubspec + lib/main.dart counter app',
    icon: Icons.phone_android,
    dirs: ['lib', 'lib/screens', 'test'],
    files: [
      TemplateFile('pubspec.yaml', '''name: __PROJECT_NAME__
description: A Flutter project created with CodeFexa Mobile.
publish_to: "none"
version: 1.0.0+1

environment:
  sdk: ">=3.3.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
'''),
      TemplateFile('lib/main.dart', '''import 'package:flutter/material.dart';

void main() => runApp(const __PROJECT_NAME__App());

class __PROJECT_NAME__App extends StatelessWidget {
  const __PROJECT_NAME__App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '__PROJECT_NAME__',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('__PROJECT_NAME__')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text('\$_counter', style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
'''),
      TemplateFile('test/widget_test.dart', '''import 'package:flutter_test/flutter_test.dart';

import 'package:__PROJECT_NAME__/main.dart';

void main() {
  testWidgets('counter starts at zero', (tester) async {
    await tester.pumpWidget(const __PROJECT_NAME__App());
    expect(find.text('0'), findsOneWidget);
  });
}
'''),
      TemplateFile('analysis_options.yaml',
          'include: package:flutter_lints/flutter.yaml\n'),
      TemplateFile(
          '.gitignore', '.dart_tool/\nbuild/\n*.iml\n.idea/\nandroid/.gradle/\n'),
    ],
  );

  static const flutterPackage = ProjectTemplate(
    id: 'flutter_package',
    label: 'Flutter Package',
    description: 'Reusable Dart/Flutter library',
    icon: Icons.category_outlined,
    dirs: ['lib/src', 'test'],
    files: [
      TemplateFile('pubspec.yaml', '''name: __PROJECT_NAME__
description: A reusable Flutter package created with CodeFexa Mobile.
version: 0.1.0

environment:
  sdk: ">=3.3.0 <4.0.0"
'''),
      TemplateFile('lib/__PROJECT_NAME__.dart', '''/// __PROJECT_NAME__ — a reusable Flutter package.
library;

export 'src/core.dart';
'''),
      TemplateFile('lib/src/core.dart', '''/// Core API of the package.
class Core {
  const Core();

  /// Returns a friendly greeting.
  String greet(String name) => 'Hello, \$name!';
}
'''),
      TemplateFile('test/core_test.dart', '''import 'package:flutter_test/flutter_test.dart';

import 'package:__PROJECT_NAME__/__PROJECT_NAME__.dart';

void main() {
  test('greet', () {
    expect(const Core().greet('World'), 'Hello, World!');
  });
}
'''),
    ],
  );

  static const androidProject = ProjectTemplate(
    id: 'android',
    label: 'Android Project',
    description: 'Gradle + manifest skeleton',
    icon: Icons.android,
    dirs: ['app/src/main/java/com/example/app'],
    files: [
      TemplateFile('settings.gradle', '''pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
rootProject.name = "__PROJECT_NAME__"
include ':app'
'''),
      TemplateFile('build.gradle', '''// Top-level build file.
tasks.register('clean', Delete) {
    delete rootProject.buildDir
}
'''),
      TemplateFile('app/build.gradle', '''plugins {
    id 'com.android.application'
}

android {
    namespace 'com.example.app'
    compileSdk 34

    defaultConfig {
        applicationId "com.example.app"
        minSdk 24
        targetSdk 34
        versionCode 1
        versionName "1.0"
    }
}

dependencies {
    implementation 'androidx.appcompat:appcompat:1.6.1'
}
'''),
      TemplateFile('app/src/main/AndroidManifest.xml', '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="__PROJECT_NAME__"
        android:theme="@android:style/Theme.Material.Light">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
'''),
    ],
  );

  static const webProject = ProjectTemplate(
    id: 'web',
    label: 'HTML/CSS/JavaScript',
    description: 'Static web page — live-previewable in CodeFexa Mobile',
    icon: Icons.code,
    dirs: ['assets'],
    files: [
      TemplateFile('index.html', '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>__PROJECT_NAME__</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main class="card">
    <h1>__PROJECT_NAME__</h1>
    <p>Edit this page or ask the CodeFexa agent to build it out.</p>
    <button id="cta">Tap me</button>
  </main>
  <script src="script.js"></script>
</body>
</html>
'''),
      TemplateFile('style.css', '''* { box-sizing: border-box; margin: 0; }
body {
  min-height: 100vh;
  display: grid;
  place-items: center;
  font-family: system-ui, sans-serif;
  background: #0b0f1a;
  color: #e8ecf4;
}
.card {
  padding: 2rem;
  border-radius: 16px;
  background: #131a2b;
  border: 1px solid #233250;
  text-align: center;
}
button {
  margin-top: 1rem;
  padding: 0.6rem 1.4rem;
  border-radius: 999px;
  border: 0;
  background: #2f81f7;
  color: white;
  font-size: 1rem;
}
'''),
      TemplateFile('script.js', '''document.getElementById('cta').addEventListener('click', () => {
  document.querySelector('.card p').textContent =
    'JavaScript works — build something great!';
});
'''),
    ],
  );

  static const reactProject = ProjectTemplate(
    id: 'react',
    label: 'React Web App',
    description: 'Vite + React scaffold',
    icon: Icons.web,
    dirs: ['src'],
    files: [
      TemplateFile('package.json', '''{
  "name": "__PROJECT_NAME__",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "echo add tests"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "vite": "^5.4.0"
  }
}
'''),
      TemplateFile('index.html', '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>__PROJECT_NAME__</title>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.jsx"></script>
</body>
</html>
'''),
      TemplateFile('vite.config.js', '''import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({ plugins: [react()] });
'''),
      TemplateFile('src/main.jsx', '''import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';

createRoot(document.getElementById('root')).render(<App />);
'''),
      TemplateFile('src/App.jsx', '''export default function App() {
  return (
    <main style={{ fontFamily: 'system-ui', padding: 32 }}>
      <h1>__PROJECT_NAME__</h1>
      <p>Edit src/App.jsx or ask the CodeFexa agent.</p>
    </main>
  );
}
'''),
    ],
  );

  static const nodeProject = ProjectTemplate(
    id: 'node',
    label: 'Node.js Project',
    description: 'package.json + entry script',
    icon: Icons.terminal,
    dirs: ['src', 'test'],
    files: [
      TemplateFile('package.json', '''{
  "name": "__PROJECT_NAME__",
  "version": "0.1.0",
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "test": "node --test test/"
  }
}
'''),
      TemplateFile('src/index.js', '''// __PROJECT_NAME__ entry point.
console.log('__PROJECT_NAME__ is running.');
'''),
      TemplateFile('test/smoke.test.js', '''import test from 'node:test';
import assert from 'node:assert';

test('smoke', () => {
  assert.equal(1 + 1, 2);
});
'''),
    ],
  );

  static const pythonProject = ProjectTemplate(
    id: 'python',
    label: 'Python Project',
    description: 'Main script + tests + requirements',
    icon: Icons.data_object,
    dirs: ['src', 'tests'],
    files: [
      TemplateFile('requirements.txt', '# Add dependencies here\n'),
      TemplateFile('src/main.py', '''"""__PROJECT_NAME__ — entry point."""


def main() -> None:
    print("__PROJECT_NAME__ is running.")


if __name__ == "__main__":
    main()
'''),
      TemplateFile('tests/test_main.py', '''"""Smoke tests."""


def test_placeholder():
    assert True
'''),
      TemplateFile(
          '.gitignore', '__pycache__/\n.venv/\n*.pyc\n.pytest_cache/\n'),
    ],
  );

  static const all = [
    blank,
    flutterApp,
    flutterPackage,
    androidProject,
    webProject,
    reactProject,
    nodeProject,
    pythonProject,
  ];

  static ProjectTemplate byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => blank);
}

/// Serialize settings without ever touching the key (utility).
String maskKey(String key) =>
    key.length >= 8 ? '••••${key.substring(key.length - 4)}' : '••••';

String jsonPretty(Object o) => const JsonEncoder.withIndent('  ').convert(o);
