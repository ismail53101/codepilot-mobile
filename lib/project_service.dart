import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Local project workspace: ZIP import, file tree, read, full-text search,
/// and ZIP export. All operations run against a real directory on device.
class ProjectService {
  Directory? _root; // <appdocs>/projects/<name>
  String? _projectName;

  String? get projectName => _projectName;

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
    return 'Imported $count files into "$baseName".';
  }

  /// Create an empty project (e.g. from "New project").
  Future<String> createProject(String name) async {
    final clean = name.replaceAll(RegExp(r'[^\w\-. ]'), '_').trim();
    if (clean.isEmpty) throw const ProjectException('Project name is empty.');
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, clean));
    if (root.existsSync()) {
      throw ProjectException('A project named "$clean" already exists.');
    }
    root.createSync(recursive: true);
    File(p.join(root.path, '.codepilot_project')).writeAsStringSync(clean);
    _root = root;
    _projectName = clean;
    return clean;
  }

  /// Open an existing project by name.
  Future<void> openProject(String name) async {
    final dir = await projectsDir();
    final root = Directory(p.join(dir.path, name));
    if (!root.existsSync()) throw ProjectException('Project "$name" not found.');
    _root = root;
    _projectName = name;
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

  /// Export the project as a ZIP. Skips files listed in .codepilot_exclude
  /// (e.g. any local secret file) — the API key lives in secure storage and
  /// is never part of the project directory, so it can never be exported.
  Future<String> exportZip() async {
    final exclude = <String>{'.codepilot_exclude'};
    final excludeFile = File(p.join(root.path, '.codepilot_exclude'));
    if (excludeFile.existsSync()) {
      exclude.addAll(excludeFile
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty));
    }
    final encoder = ZipFileEncoder();
    final dir = await projectsDir();
    final outPath = p.join(dir.path, '${_projectName}_export.zip');
    encoder.create(outPath);
    await encoder.addDirectory(root, exclude: []);
    await encoder.close();

    // Rebuild the zip without excluded entries (archive package rewrite).
    if (exclude.length > 1) {
      final input = File(outPath).readAsBytesSync();
      final decoded = ZipDecoder().decodeBytes(input);
      final out = Archive();
      for (final f in decoded) {
        if (exclude.any(f.name.contains)) continue;
        out.add(f);
      }
      File(outPath).writeAsBytesSync(ZipEncoder().encode(out)!);
    }
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

/// Serialize settings without ever touching the key (utility).
String maskKey(String key) =>
    key.length >= 8 ? '••••${key.substring(key.length - 4)}' : '••••';

String jsonPretty(Object o) => const JsonEncoder.withIndent('  ').convert(o);
