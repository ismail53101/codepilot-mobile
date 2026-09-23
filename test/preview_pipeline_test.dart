import 'package:flutter_test/flutter_test.dart';

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
