import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'main.dart';
import 'preview_pipeline.dart';
import 'screens/preview_pipeline_screen.dart';
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

  /// Prebuilt static output exists in the project (dist/, out/ or
  /// build/web): compiled artifacts can be served locally without any
  /// toolchain or GitHub connection.
  final bool hasPrebuiltOutput;

  const PreviewResolution({
    required this.supported,
    required this.projectType,
    this.entryPath,
    this.reason,
    this.hint,
    this.hasPrebuiltOutput = false,
  });
}

/// Prebuilt static output directories — their presence means compiled
/// artifacts already exist and can be served locally as-is.
const _prebuiltOutputDirs = ['dist', 'out', 'build/web'];

/// True when [rootPath] contains a usable compiled static output directory
/// (an index.html plus at least one asset, or just an index.html).
bool hasPrebuiltStaticOutputIn(String rootPath) {
  for (final dir in _prebuiltOutputDirs) {
    final d = Directory(p.join(rootPath, dir));
    if (d.existsSync() && File(p.join(d.path, 'index.html')).existsSync()) {
      return true;
    }
  }
  return false;
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
  final prebuilt = hasPrebuiltStaticOutputIn(rootPath);

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
      hasPrebuiltOutput: prebuilt,
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
      hasPrebuiltOutput: prebuilt,
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
    hasPrebuiltOutput: prebuilt,
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

/// Detection against the currently open project. Uses the canonical
/// [ProjectService.contentRoot] so a legacy zipball-wrapped import previews
/// its real files (index.html), not the wrapper folder.
PreviewResolution resolvePreview() {
  final rootPath = projectService.contentRootPath;
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

/// Cached resolution for the synchronous preview-button label. Directory
/// scans on every frame are wasteful; the cache is invalidated whenever the
/// agent writes files (see [invalidatePreviewResolution]).
PreviewResolution? _resolutionCache;

/// Cached plan for the async preview tap. Invalidated together with the
/// resolution and the repo cache.
PreviewPlan? _planCache;

/// Synchronous, cheap label for the preview chip. Cached between agent
/// writes; returns 'Preview' when nothing is known yet.
String previewChipLabel() {
  if (projectService.projectName == null) return 'Preview';
  _resolutionCache ??= resolvePreview();
  final type = _resolutionCache!.projectType;
  _planCache ??= planForProjectType(type, hasRepo: true);
  return _planCache!.label;
}

/// The agent (or a GitHub import) changed project files/state — drop the
/// cached detection so the next label and preview reflect reality.
void invalidatePreviewResolution() {
  _resolutionCache = null;
  _planCache = null;
}

/// The ▶ PREVIEW action — PROJECT-TYPE AWARE with two clearly separated
/// paths, honestly labeled:
///
/// A) LOCAL PREVIEW — no GitHub required, works immediately:
///    - HTML/CSS/JS projects (source served over loopback + WebView).
///    - Projects with prebuilt static output (Vite dist/, Next out/,
///      Flutter build/web) — compiled artifacts served locally as-is.
///
/// B) GITHUB BUILD PREVIEW — real compilation on GitHub Actions:
///    - Flutter → flutter build web --release → GitHub Pages.
///    - React (Vite) / Next.js → npm build → GitHub Pages.
///    - Android → Build APK (real Gradle artifact, no pretend preview).
///    - Node.js / Python → Run/Output console (real install + execution).
///
/// GitHub is never required to create or edit a project, and never faked:
/// without a linked repo the user gets the reason plus [Connect GitHub].
Future<void> openProjectPreview(BuildContext context) async {
  final plan = await resolvePreviewPlan();
  if (!context.mounted) return;

  switch (plan.outcome) {
    case PreviewOutcome.liveLocal:
      // Existing on-device path — untouched.
      final res = resolvePreview();
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
      } else {
        // Detected as static web but no entry file found — say why.
        await _previewDialog(
          context,
          title: 'Preview unavailable',
          projectType: res.projectType,
          body: res.reason ?? 'No HTML entry file (index.html) was found.',
        );
      }
      return;

    case PreviewOutcome.localStatic:
      // Prebuilt output — serve the compiled directory locally. No GitHub,
      // no toolchain, no faking: the artifacts genuinely exist.
      final rootPath = projectService.contentRootPath;
      String? serveRoot;
      for (final dir in _prebuiltOutputDirs) {
        final d = Directory(p.join(rootPath!, dir));
        if (d.existsSync() && File(p.join(d.path, 'index.html')).existsSync()) {
          serveRoot = d.path;
          break;
        }
      }
      if (serveRoot != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PreviewScreen(
              localRoot: serveRoot,
              projectTitle:
                  '${projectService.projectName} — ${plan.label}',
            ),
          ),
        );
      } else {
        await _previewDialog(
          context,
          title: 'Preview unavailable',
          projectType: plan.projectType,
          body: 'Prebuilt output was detected but could not be opened.',
        );
      }
      return;

    case PreviewOutcome.pagesPreview:
    case PreviewOutcome.buildApk:
    case PreviewOutcome.runOutput:
      // Real remote pipelines with live logs.
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PreviewPipelineScreen(plan: plan),
        ),
      );
      return;

    case PreviewOutcome.unavailable:
      // Honest blocker: WHY GitHub/an external environment is required,
      // plus [Connect GitHub] when that is the missing piece.
      await _previewDialog(
        context,
        title: 'Preview unavailable',
        projectType: plan.projectType,
        body: plan.blocker ??
            'This project type cannot be previewed on-device.',
        showConnectGitHub: plan.requiresRepo,
      );
      return;
  }
}

Future<void> _previewDialog(
  BuildContext context, {
  required String title,
  required String projectType,
  required String body,
  bool showConnectGitHub = false,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: const [
        Icon(Icons.videocam_off_outlined, size: 18, color: AppTheme.warn),
        SizedBox(width: 8),
        Text('Preview unavailable', style: TextStyle(fontSize: 15)),
      ]),
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Project type: $projectType',
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(body,
                style: const TextStyle(color: AppTheme.muted, fontSize: 12.5)),
          ]),
      actions: [
        if (showConnectGitHub)
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.glowAccent),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushNamed(context, '/github');
            },
            icon: const Icon(Icons.link, size: 15),
            label: const Text('Connect GitHub'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Back to Project'),
        ),
      ],
    ),
  );
}
