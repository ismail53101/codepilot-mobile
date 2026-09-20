import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'main.dart';
import 'screens/preview_screen.dart';
import 'theme.dart';

/// PROJECT PREVIEW MANAGER.
///
/// Decides — honestly — whether the open project can be previewed on-device:
/// static HTML/CSS/JS projects CAN (loopback server + WebView, no GitHub and
/// no network needed); toolchain projects (Flutter, Android, Node, Python,
/// bundler-based React/Next.js) CANNOT and say so with the real reason
/// instead of faking a preview.
class PreviewResolution {
  final bool supported;
  final String projectType;

  /// Entry file relative to the project root (e.g. index.html).
  final String? entryPath;
  final String? reason;
  final String? hint;

  const PreviewResolution({
    required this.supported,
    required this.projectType,
    this.entryPath,
    this.reason,
    this.hint,
  });
}

/// Pure, testable detection over a directory.
PreviewResolution resolvePreviewInDirectory({
  required String rootPath,
  required String projectName,
}) {
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    return const PreviewResolution(
      supported: false,
      projectType: 'Unknown',
      reason: 'The project folder no longer exists on disk.',
    );
  }
  final has = (String f) => File(p.join(rootPath, f)).existsSync();

  // ---- toolchain types: cannot run on-device, say why ------------------
  if (has('pubspec.yaml')) {
    return PreviewResolution(
      supported: false,
      projectType: 'Flutter',
      reason:
          'Flutter projects must be compiled by the Flutter/Android toolchain, '
          'which cannot run on the device itself.',
      hint: 'Use Build → GitHub Actions to produce a real APK, or ask the '
          'agent to verify the code statically.',
    );
  }
  if (has('build.gradle') || has('build.gradle.kts')) {
    return PreviewResolution(
      supported: false,
      projectType: 'Android',
      reason:
          'Android projects need Gradle + the Android SDK to build an APK — '
          'unavailable on-device.',
      hint: 'Use Build → GitHub Actions for a real build.',
    );
  }
  if (has('package.json')) {
    final packageJson = File(p.join(rootPath, 'package.json'));
    var isNext = has('next.config.js') || has('next.config.mjs');
    var isVite = has('vite.config.ts') || has('vite.config.js');
    var isReact = false;
    try {
      final raw = packageJson.readAsStringSync().toLowerCase();
      isNext = isNext || raw.contains('"next"');
      isVite = isVite || raw.contains('"vite"');
      isReact = raw.contains('"react"');
    } catch (_) {
      // unreadable manifest → treat as plain Node
    }
    final label = isNext
        ? 'Next.js'
        : isVite
            ? 'React (Vite)'
            : isReact
                ? 'React'
                : 'Node.js';
    return PreviewResolution(
      supported: false,
      projectType: label,
      reason:
          '$label projects require npm dependencies and a dev/build server, '
          'which cannot run inside the app sandbox.',
      hint: 'Push to GitHub and let the included Actions workflow build it, '
          'or preview a plain HTML version of the UI.',
    );
  }
  if (has('requirements.txt') || has('pyproject.toml')) {
    return const PreviewResolution(
      supported: false,
      projectType: 'Python',
      reason:
          'Python projects need a Python interpreter, which is not available '
          'on this device.',
      hint: 'Run it on your machine or in CI, then preview a web front-end '
          'if the project has one.',
    );
  }

  // ---- static web: find the entry point --------------------------------
  String? entry;
  if (has('index.html')) {
    entry = 'index.html';
  } else {
    entry = _findHtmlEntry(root, rootPath);
  }
  if (entry == null) {
    return const PreviewResolution(
      supported: false,
      projectType: 'HTML/CSS/JS',
      reason:
          'No HTML entry file (e.g. index.html) was found in this project.',
      hint: 'Add an index.html (ask the agent to create one) and try again.',
    );
  }
  return PreviewResolution(
    supported: true,
    projectType: 'HTML/CSS/JS',
    entryPath: entry,
  );
}

/// Depth-first search for an HTML entry: index.html first (shallowest),
/// then any index.html, then any other .html file. Dot-dirs are skipped.
String? _findHtmlEntry(Directory root, String rootPath) {
  final indexes = <String>[];
  final others = <String>[];
  final stack = <String>[''];
  while (stack.isNotEmpty) {
    final rel = stack.removeLast();
    final dir = rel.isEmpty ? root : Directory(p.join(rootPath, rel));
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final relPath = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        stack.add(relPath);
      } else if (e is File) {
        final lower = name.toLowerCase();
        if (lower == 'index.html' || lower == 'index.htm') {
          indexes.add(relPath);
        } else if (lower.endsWith('.html') || lower.endsWith('.htm')) {
          others.add(relPath);
        }
      }
    }
  }
  if (indexes.isNotEmpty) {
    indexes.sort((a, b) =>
        a.split('/').length.compareTo(b.split('/').length) == 0
            ? a.compareTo(b)
            : a.split('/').length.compareTo(b.split('/').length));
    return indexes.first;
  }
  if (others.isNotEmpty) return others.first;
  return null;
}

/// Detection against the currently open project.
PreviewResolution resolvePreview() {
  final rootPath = projectService.rootPath;
  if (rootPath == null || projectService.projectName == null) {
    return const PreviewResolution(
      supported: false,
      projectType: 'None',
      reason: 'No project is open.',
      hint: 'Create a project (Home → ⋮ → Projects → +) or import a ZIP, '
          'then preview it.',
    );
  }
  return resolvePreviewInDirectory(
    rootPath: rootPath,
    projectName: projectService.projectName!,
  );
}

/// The ▶ PREVIEW action. Opens the live local preview when the project type
/// supports it; otherwise shows an honest "Preview unavailable" card with
/// the real reason and what to do instead. Works fully offline and NEVER
/// requires GitHub.
Future<void> openProjectPreview(BuildContext context) async {
  var res = resolvePreview();
  if (res.supported && res.entryPath != null) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(
          path: res.entryPath,
          projectTitle: projectService.projectName,
        ),
      ),
    );
    return;
  }

  // Unsupported — say why and offer honest actions.
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: const [
        Icon(Icons.videocam_off_outlined, size: 18, color: AppTheme.warn),
        SizedBox(width: 8),
        Text('Preview unavailable',
            style: TextStyle(fontSize: 15)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Project type: ${res.projectType}',
            style: const TextStyle(
                color: AppTheme.text, fontSize: 12.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(res.reason ?? 'This project type cannot be previewed on-device.',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12.5)),
        if (res.hint != null) ...[
          const SizedBox(height: 8),
          Text(res.hint!,
              style: const TextStyle(
                  color: AppTheme.glowAccent, fontSize: 12)),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: () {
            // View Error: full technical context, no faked success.
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              duration: const Duration(seconds: 4),
              content: Text(
                  'Preview resolver: type=${res.projectType}, '
                  'entry=${res.entryPath ?? 'none'}, reason=${res.reason}'),
            ));
          },
          child: const Text('View Error'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            // Retry: the agent may have changed the project since.
            final again = resolvePreview();
            if (again.supported) {
              await openProjectPreview(context);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Still unavailable: ${again.reason}'),
              ));
            }
          },
          child: const Text('Retry'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.glowAccent),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Back to Project'),
        ),
      ],
    ),
  );
}
