import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:codepilot_mobile/preview_manager.dart';
import 'package:codepilot_mobile/preview_pipeline.dart';

void main() {
  group('planForProjectType — type-aware preview routing', () {
    test('HTML/CSS/JS stays on the on-device live preview', () {
      final plan = planForProjectType('HTML/CSS/JS', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.liveLocal);
      expect(plan.blocker, isNull);
    });

    test('Flutter → Pages web build when a repo is linked', () {
      final plan = planForProjectType('Flutter', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.pagesPreview);
      expect(plan.blocker, isNull);
      expect(plan.summary, contains('flutter build web'));
    });

    test('Flutter without a repo is an honest blocker, never a fake preview',
        () {
      final plan = planForProjectType('Flutter', hasRepo: false);
      expect(plan.outcome, PreviewOutcome.unavailable);
      expect(plan.blocker, contains('GitHub repository'));
    });

    test('React (Vite) → Pages web build', () {
      final plan = planForProjectType('React (Vite)', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.pagesPreview);
      expect(plan.summary, contains('npm run build'));
    });

    test('Next.js → Pages static export', () {
      final plan = planForProjectType('Next.js', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.pagesPreview);
    });

    test('Android → Build APK (never an on-device pretend preview)', () {
      final plan = planForProjectType('Android', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.buildApk);
      expect(plan.summary, contains('APK'));
    });

    test('Node.js → run/output console', () {
      final plan = planForProjectType('Node.js', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.runOutput);
    });

    test('Python → run/output console', () {
      final plan = planForProjectType('Python', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.runOutput);
    });

    test('unknown types are honestly unavailable', () {
      final plan = planForProjectType('Unknown', hasRepo: true);
      expect(plan.outcome, PreviewOutcome.unavailable);
      expect(plan.blocker, isNotNull);
    });
  });

  group('NO-GITHUB / LOCAL PREVIEW MODE (requirements 10–12)', () {
    test('prebuilt Vite dist/ routes to a local preview without GitHub', () {
      final plan =
          planForProjectType('React (Vite)', hasRepo: false, hasPrebuiltOutput: true);
      expect(plan.outcome, PreviewOutcome.localStatic);
      expect(plan.label, 'Local Preview');
      expect(plan.requiresRepo, isFalse);
      expect(plan.blocker, isNull);
    });

    test('prebuilt Next.js out/ routes to a local preview without GitHub', () {
      final plan =
          planForProjectType('Next.js', hasRepo: false, hasPrebuiltOutput: true);
      expect(plan.outcome, PreviewOutcome.localStatic);
      expect(plan.label, 'Local Preview');
    });

    test('prebuilt Flutter build/web routes to a local preview without GitHub',
        () {
      final plan =
          planForProjectType('Flutter', hasRepo: false, hasPrebuiltOutput: true);
      expect(plan.outcome, PreviewOutcome.localStatic);
      expect(plan.label, 'Local Preview');
    });

    test('source-only Vite project without repo still explains GitHub need',
        () {
      final plan =
          planForProjectType('React (Vite)', hasRepo: false);
      expect(plan.outcome, PreviewOutcome.unavailable);
      expect(plan.requiresRepo, isTrue);
      expect(plan.blocker, contains('external build environment'));
      expect(plan.blocker, contains('Connect GitHub'));
    });

    test('every plan carries an honest path label', () {
      expect(planForProjectType('HTML/CSS/JS', hasRepo: true).label,
          'Local Preview');
      expect(planForProjectType('Flutter', hasRepo: true).label,
          'GitHub Build Preview');
      expect(planForProjectType('React (Vite)', hasRepo: true).label,
          'GitHub Build Preview');
      expect(planForProjectType('Next.js', hasRepo: true).label,
          'GitHub Build Preview');
      expect(planForProjectType('Android', hasRepo: true).label, 'Build APK');
      expect(planForProjectType('Node.js', hasRepo: true).label, 'Run / Output');
      expect(planForProjectType('Python', hasRepo: true).label, 'Run / Output');
    });

    test('only GitHub-build outcomes declare requiresRepo', () {
      for (final t in const [
        'Flutter',
        'React (Vite)',
        'Next.js',
        'Android',
        'Node.js',
        'Python'
      ]) {
        expect(planForProjectType(t, hasRepo: true).requiresRepo, isTrue,
            reason: t);
      }
      expect(
          planForProjectType('HTML/CSS/JS', hasRepo: true).requiresRepo, isFalse);
      expect(
          planForProjectType('React (Vite)', hasRepo: false,
                  hasPrebuiltOutput: true)
              .requiresRepo,
          isFalse);
    });
  });

  group('hasPrebuiltStaticOutputIn — compiled-artifact detection', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('prebuilt_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('detects dist/index.html (Vite build output)', () {
      Directory(p.join(tmp.path, 'dist')).createSync(recursive: true);
      File(p.join(tmp.path, 'dist', 'index.html')).writeAsStringSync('<html></html>');
      expect(hasPrebuiltStaticOutputIn(tmp.path), isTrue);
    });

    test('detects out/index.html (Next.js export)', () {
      Directory(p.join(tmp.path, 'out')).createSync(recursive: true);
      File(p.join(tmp.path, 'out', 'index.html')).writeAsStringSync('<html></html>');
      expect(hasPrebuiltStaticOutputIn(tmp.path), isTrue);
    });

    test('detects build/web/index.html (Flutter web build)', () {
      Directory(p.join(tmp.path, 'build', 'web')).createSync(recursive: true);
      File(p.join(tmp.path, 'build', 'web', 'index.html'))
          .writeAsStringSync('<html></html>');
      expect(hasPrebuiltStaticOutputIn(tmp.path), isTrue);
    });

    test('an empty dist/ without index.html does NOT count', () {
      Directory(p.join(tmp.path, 'dist')).createSync(recursive: true);
      expect(hasPrebuiltStaticOutputIn(tmp.path), isFalse);
    });

    test('source-only projects have no prebuilt output', () {
      expect(hasPrebuiltStaticOutputIn(tmp.path), isFalse);
    });
  });

  group('resolvePreviewInDirectory — detection through the full resolver', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('preview_detect_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('static web with index.html is locally previewable', () {
      File(p.join(tmp.path, 'index.html')).writeAsStringSync('<html></html>');
      final res = resolvePreviewInDirectory(
          rootPath: tmp.path, projectName: 'demo');
      expect(res.supported, isTrue);
      expect(res.projectType, 'HTML/CSS/JS');
      expect(res.entryPath, 'index.html');
    });

    test('Vite project with prebuilt dist reports the artifact flag', () {
      File(p.join(tmp.path, 'package.json')).writeAsStringSync(
          '{"name":"demo","dependencies":{"react":"^18","vite":"^5"}}');
      Directory(p.join(tmp.path, 'dist')).createSync(recursive: true);
      File(p.join(tmp.path, 'dist', 'index.html')).writeAsStringSync('<html></html>');
      final res = resolvePreviewInDirectory(
          rootPath: tmp.path, projectName: 'demo');
      expect(res.projectType, 'React (Vite)');
      expect(res.hasPrebuiltOutput, isTrue);
    });

    test('Vite project without dist does not claim prebuilt output', () {
      File(p.join(tmp.path, 'package.json')).writeAsStringSync(
          '{"name":"demo","dependencies":{"react":"^18","vite":"^5"}}');
      final res = resolvePreviewInDirectory(
          rootPath: tmp.path, projectName: 'demo');
      expect(res.projectType, 'React (Vite)');
      expect(res.hasPrebuiltOutput, isFalse);
    });
  });

  group('previewWorkflowYaml — the generated real build pipeline', () {
    final yaml = previewWorkflowYaml();

    test('is a workflow_dispatch workflow', () {
      expect(yaml, contains('workflow_dispatch:'));
      expect(yaml, contains('project_type:'));
    });

    test('Flutter job: pub get + build web --release + APK fallback', () {
      expect(yaml, contains('flutter pub get'));
      expect(yaml, contains('flutter build web --release'));
      expect(yaml, contains('flutter build apk --debug'));
    });

    test('Vite/Next/Node jobs use npm', () {
      expect(yaml, contains('npm ci || npm install'));
      expect(yaml, contains('npm run build'));
      expect(yaml, contains('npx next build'));
    });

    test('Python job installs requirements and detects web frameworks', () {
      expect(yaml, contains('pip install -r requirements.txt'));
      expect(yaml, contains('import flask'));
      expect(yaml, contains('import fastapi'));
      expect(yaml, contains('import django'));
    });

    test('Android job builds a real APK', () {
      expect(yaml, contains('gradlew assembleDebug'));
    });

    test('serves static output through GitHub Pages', () {
      expect(yaml, contains('actions/deploy-pages@v4'));
      expect(yaml, contains('build/web'));
      expect(yaml, contains('dist'));
    });

    test('workflow file path is a valid Actions location', () {
      expect(kPreviewWorkflowPath, '.github/workflows/codefexa-preview.yml');
    });
  });

  group('PreviewPipeline constants', () {
    test('preview branch is isolated from the user default branch', () {
      expect(PreviewPipeline.previewBranch, 'codefexa-preview');
    });
  });
}
