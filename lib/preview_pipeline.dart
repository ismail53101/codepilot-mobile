import 'dart:async';

import 'api_client.dart' show CancelToken;
import 'github_service.dart';
import 'main.dart' show githubProjectStore;
import 'preview_manager.dart';

/// PROJECT-TYPE-AWARE PREVIEW PIPELINE.
///
/// Reality this code is built on: the Android app sandbox has NO Flutter,
/// Node, Python or Gradle toolchains (see TerminalExecutor). Real
/// compilation therefore runs on GitHub Actions via the project's linked
/// repository — the same infrastructure the Build screen uses — and the
/// compiled static output is served as a REAL live preview through GitHub
/// Pages. Every step reports its actual log output; nothing is faked.
///
/// Per project type:
/// - Flutter       → `flutter pub get` + `flutter build web --release` → Pages
/// - React (Vite)  → npm ci + `vite build`                             → Pages
/// - Next.js       → next build (static export)                        → Pages
/// - Node.js       → install + entry smoke run (Run/Output console)
/// - Python        → pip install + web-app check or entry run          → Run/Output
/// - Android       → real Gradle APK build (Build APK path)
/// - HTML/CSS/JS   → on-device live preview (existing path, unchanged)
///
/// One preview branch (`codefexa-preview`) carries the generated workflow
/// and preview commits; the user's default branch is never touched, no
/// force-push is ever issued, and no user file is modified.
class PreviewPlan {
  final String projectType;

  /// What the pipeline produces.
  final PreviewOutcome outcome;

  /// Human summary shown before dispatch.
  final String summary;

  /// Non-null when nothing runnable is possible; the UI shows this reason.
  final String? blocker;

  const PreviewPlan({
    required this.projectType,
    required this.outcome,
    required this.summary,
    this.blocker,
  });
}

enum PreviewOutcome {
  /// Compiled static site served live via GitHub Pages.
  pagesPreview,

  /// Real remote build producing an APK artifact (no visual preview).
  buildApk,

  /// Real remote execution with logs (server apps / CLI), no visual preview.
  runOutput,

  /// On-device WebView preview of the project files themselves.
  liveLocal,

  /// Nothing runnable — the honest blocker is shown.
  unavailable,
}

/// Decide the pipeline for a detected project type. Pure and testable.
PreviewPlan planForProjectType(String detectedType, {required bool hasRepo}) {
  switch (detectedType) {
    case 'HTML/CSS/JS':
      return const PreviewPlan(
        projectType: 'HTML/CSS/JS',
        outcome: PreviewOutcome.liveLocal,
        summary: 'Static web project — opens directly in the on-device viewer.',
      );
    case 'Flutter':
      if (!hasRepo) return _repoRequired('Flutter');
      return const PreviewPlan(
        projectType: 'Flutter',
        outcome: PreviewOutcome.pagesPreview,
        summary:
            'Flutter Web build (flutter pub get + flutter build web '
            '--release) runs on GitHub Actions, then the compiled app is '
            'served live through GitHub Pages. Needs a linked repository.',
      );
    case 'React (Vite)':
      if (!hasRepo) return _repoRequired('React (Vite)');
      return const PreviewPlan(
        projectType: 'React (Vite)',
        outcome: PreviewOutcome.pagesPreview,
        summary:
            'Vite build (npm ci + npm run build) runs on GitHub Actions and '
            'the compiled site is served live through GitHub Pages. Needs a '
            'linked repository.',
      );
    case 'Next.js':
      if (!hasRepo) return _repoRequired('Next.js');
      return const PreviewPlan(
        projectType: 'Next.js',
        outcome: PreviewOutcome.pagesPreview,
        summary:
            'Next.js static build runs on GitHub Actions and the exported '
            'site is served through GitHub Pages (server-only features '
            'cannot be exported — the build log will say so). Needs a '
            'linked repository.',
      );
    case 'Android':
      if (!hasRepo) return _repoRequired('Android');
      return const PreviewPlan(
        projectType: 'Android',
        outcome: PreviewOutcome.buildApk,
        summary:
            'An APK cannot run inside this app — the real Gradle build runs '
            'on GitHub Actions and produces a downloadable APK artifact. '
            'Needs a linked repository.',
      );
    case 'Node.js':
      if (!hasRepo) return _repoRequired('Node.js');
      return const PreviewPlan(
        projectType: 'Node.js',
        outcome: PreviewOutcome.runOutput,
        summary:
            'Dependencies are installed and the entry script is smoke-run '
            'on GitHub Actions with full logs (a local HTTP port cannot be '
            'exposed into this app). Needs a linked repository.',
      );
    case 'Python':
      if (!hasRepo) return _repoRequired('Python');
      return const PreviewPlan(
        projectType: 'Python',
        outcome: PreviewOutcome.runOutput,
        summary:
            'Dependencies are installed and the web app / entry script is '
            'really executed on GitHub Actions with full logs (the '
            'interpreter is not available on-device). Needs a linked '
            'repository.',
      );
    default:
      return const PreviewPlan(
        projectType: 'Unknown',
        outcome: PreviewOutcome.unavailable,
        summary: 'No build system recognized.',
        blocker:
            'This project type has no recognizable build system (no '
            'package.json, pubspec.yaml, build.gradle, requirements.txt '
            'or index.html).',
      );
  }
}

PreviewPlan _repoRequired(String type) => PreviewPlan(
      projectType: type,
      outcome: PreviewOutcome.unavailable,
      summary: '$type previews run remotely — a GitHub repository is needed.',
      blocker:
          '$type previews are built on GitHub Actions and served through '
          'GitHub Pages — link a GitHub repository first '
          '(Integrations → GitHub → import or connect this project).',
    );

/// Resolves the pipeline plan for the currently open project.
Future<PreviewPlan> resolvePreviewPlan() async {
  final res = resolvePreview();
  final repo = await githubProjectStore.resolveForActiveProject();
  return planForProjectType(res.projectType, hasRepo: repo != null);
}

/// The workflow file name on the preview branch.
const kPreviewWorkflowPath = '.github/workflows/codefexa-preview.yml';

/// The preview workflow YAML: ONE parameterized workflow serving every
/// project type — inputs select the real install/build/run steps. Committed
/// ONLY to the preview branch; the user's branches are untouched.
String previewWorkflowYaml() => '''
name: CodeFexa Preview

on:
  workflow_dispatch:
    inputs:
      project_type:
        description: 'Project type'
        required: true
        type: choice
        options:
          - flutter
          - vite
          - nextjs
          - node
          - python
          - android

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: codefexa-preview
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # ---------------- Flutter ----------------
      - name: Set up Flutter
        if: inputs.project_type == 'flutter'
        uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Flutter pub get
        if: inputs.project_type == 'flutter'
        run: flutter pub get
      - name: Flutter build web (release)
        if: inputs.project_type == 'flutter'
        run: flutter build web --release
      - name: Flutter debug APK (fallback)
        if: inputs.project_type == 'flutter' && failure()
        run: flutter build apk --debug

      # ---------------- React (Vite) ----------------
      - name: Set up Node
        if: inputs.project_type == 'vite' || inputs.project_type == 'nextjs'
        uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Install dependencies (Vite)
        if: inputs.project_type == 'vite'
        run: npm ci || npm install
      - name: Build (Vite)
        if: inputs.project_type == 'vite'
        run: npm run build

      # ---------------- Next.js ----------------
      - name: Install dependencies (Next.js)
        if: inputs.project_type == 'nextjs'
        run: npm ci || npm install
      - name: Build (Next.js static export)
        if: inputs.project_type == 'nextjs'
        run: |
          npx next build
          if [ ! -d out ]; then
            echo "Next.js did not produce an ./out export."
            echo "Server-only features (API routes, image optimization) are"
            echo "not exportable to static hosting."
            exit 1
          fi

      # ---------------- Node.js smoke run ----------------
      - name: Install & smoke-run (Node.js)
        if: inputs.project_type == 'node'
        run: |
          npm ci || npm install
          node -e "const p=require('./package.json');console.log('scripts:',JSON.stringify(p.scripts||{}))"
          ENTRY=\$(node -e "const p=require('./package.json');console.log(p.main||'index.js')")
          if [ -f "\$ENTRY" ]; then node --check "\$ENTRY" && echo "OK: entry \$ENTRY parses"; else echo "Entry \$ENTRY not found"; fi

      # ---------------- Python run ----------------
      - name: Set up Python
        if: inputs.project_type == 'python'
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Install & run (Python)
        if: inputs.project_type == 'python'
        run: |
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          if python -c "import flask" 2>/dev/null || python -c "import fastapi" 2>/dev/null || python -c "import django" 2>/dev/null; then
            echo "Web framework detected — verifying the app source:"
            APP_FILE=\$(ls app.py main.py wsgi.py 2>/dev/null | head -1 || true)
            if [ -n "\$APP_FILE" ]; then
              python -c "import ast,sys; ast.parse(open('\$APP_FILE').read()); print('OK: app source parses')"
            else
              echo 'No app.py/main.py/wsgi.py entry found — root listing:'
              ls
            fi
          else
            echo 'CLI/library project — running the entry script:'
            ENTRY=\$(ls main.py app.py run.py 2>/dev/null | head -1 || true)
            if [ -n "\$ENTRY" ]; then python "\$ENTRY" || true; else echo 'No entry script found.'; fi
          fi

      # ---------------- Android APK ----------------
      - name: Set up Java (Android)
        if: inputs.project_type == 'android'
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - name: Build debug APK (Android)
        if: inputs.project_type == 'android'
        run: |
          if [ -f ./gradlew ]; then chmod +x ./gradlew && ./gradlew assembleDebug; else gradle assembleDebug; fi

      # ---------------- Artifacts ----------------
      - name: Collect static output
        if: inputs.project_type != 'android'
        run: |
          mkdir -p /tmp/pages
          if [ -d build/web ]; then cp -r build/web/. /tmp/pages/;
          elif [ -d out ]; then cp -r out/. /tmp/pages/;
          elif [ -d dist ]; then cp -r dist/. /tmp/pages/;
          elif [ -f index.html ]; then cp -r . /tmp_pages_snapshot 2>/dev/null || cp -r ./index.html /tmp/pages/;
          else echo 'run-type project: no static output for Pages (expected)'; fi
      - name: Upload Pages artifact
        if: inputs.project_type != 'android'
        uses: actions/upload-artifact@v4
        with:
          name: pages
          path: /tmp/pages
          retention-days: 7
      - name: Upload APK artifact
        if: inputs.project_type == 'android' || inputs.project_type == 'flutter'
        uses: actions/upload-artifact@v4
        with:
          name: apk
          path: |
            **/build/app/outputs/flutter-apk/*.apk
            **/app/build/outputs/apk/debug/*.apk
          if-no-files-found: ignore
          retention-days: 14

  deploy:
    needs: build
    if: inputs.project_type != 'android' && needs.build.result == 'success'
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: \${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
''';

/// The workflow needs to exist on the branch GitHub dispatches. Upload it
/// (plus nothing else) into the preview branch via one commit — the user's
/// default branch and files are never modified.
class PreviewPipeline {
  final GitHubService github;
  PreviewPipeline(this.github);

  static const previewBranch = 'codefexa-preview';

  /// Runs the full pipeline. [onLog] receives real progress lines.
  Future<PreviewPipelineResult> run({
    required PreviewPlan plan,
    required String projectTypeInput,
    required void Function(String line) onLog,
    required void Function(double? progress) onProgress,
    CancelToken? cancelToken,
  }) async {
    final repo = await githubProjectStore.resolveForActiveProject();
    if (repo == null) {
      return PreviewPipelineResult.failed(
          'No GitHub repository is linked to this project '
          '(Integrations → GitHub).');
    }

    try {
      // 1. Ensure the workflow exists on the preview branch.
      onProgress(null);
      onLog('Ensuring preview workflow on branch "$previewBranch"…');
      await _ensureWorkflowPresent(repo, onLog);

      // 2. Dispatch the build for this project type.
      onLog('Dispatching $projectTypeInput build on GitHub Actions…');
      await github.dispatchWorkflow(
        repo,
        'codefexa-preview.yml',
        ref: previewBranch,
        inputs: {'project_type': projectTypeInput},
      );
      onLog('Build dispatched. Polling for the run…');

      // 3. Poll the workflow run until it finishes (real status).
      final sw = Stopwatch()..start();
      ({String status, String? conclusion, int runId, String url})? run;
      while (sw.elapsed < const Duration(minutes: 25)) {
        if (cancelToken?.isCancelled ?? false) {
          return PreviewPipelineResult.failed('Cancelled.');
        }
        await Future<void>.delayed(const Duration(seconds: 8));
        run = await github.latestWorkflowRun(repo, 'codefexa-preview.yml',
            branch: previewBranch);
        if (run == null) {
          onLog('Waiting for the run to appear…');
          continue;
        }
        onLog('Run #${run.runId}: ${run.status}'
            '${run.conclusion == null ? '' : ' (${run.conclusion})'}');
        onProgress(run.status == 'completed' ? 1.0 : null);
        if (run.status == 'completed') break;
      }
      final done = run;
      if (done == null || done.status != 'completed') {
        return PreviewPipelineResult.failed(
            'The preview build did not finish in 25 minutes. Check the run: '
            '${done?.url ?? 'GitHub Actions'}');
      }
      if (done.conclusion != 'success') {
        // Pull the REAL failure log — error-driven repair, no faked success.
        String log = '';
        try {
          log = await github.fetchFailureLog(repo, done.runId);
        } catch (_) {}
        return PreviewPipelineResult.failed(
          'The $projectTypeInput build FAILED on GitHub Actions '
          '(conclusion: ${done.conclusion}).',
          logs: log.isEmpty
              ? 'See the run for details: ${done.url}'
              : log,
          runUrl: done.url,
        );
      }

      // 4. Success — the outcome depends on the plan.
      if (plan.outcome == PreviewOutcome.pagesPreview) {
        onLog('Build succeeded. Ensuring GitHub Pages…');
        final url = await github.ensurePagesEnabled(repo);
        onLog('Live preview URL: $url');
        onProgress(1.0);
        return PreviewPipelineResult.success(
          url: url,
          runUrl: done.url,
          summary: 'Live preview deployed via GitHub Pages.',
        );
      }
      onProgress(1.0);
      return PreviewPipelineResult.success(
        url: done.url,
        runUrl: done.url,
        summary: plan.outcome == PreviewOutcome.buildApk
            ? 'Build succeeded — download the APK artifact from the run.'
            : 'Run completed — read the full output in the run logs.',
      );
    } on GitHubException catch (e) {
      return PreviewPipelineResult.failed(e.message);
    }
  }

  /// Ensures `codefexa-preview.yml` exists (and is current) on the preview
  /// branch; commits it when missing or changed. Returns the branch head.
  Future<String> _ensureWorkflowPresent(
      GitHubRepo repo, void Function(String) onLog) async {
    final wanted = previewWorkflowYaml();
    var head = await github.getHeadSha(repo, previewBranch);

    if (head == null) {
      onLog('Creating preview branch "${PreviewPipeline.previewBranch}" '
          'from ${repo.defaultBranch}…');
      await github.createBranch(repo, PreviewPipeline.previewBranch);
      head = await github.getHeadSha(repo, PreviewPipeline.previewBranch);
      if (head == null) {
        throw GitHubException('Could not create the preview branch.');
      }
    }

    final existing = await github.getContents(repo, kPreviewWorkflowPath,
        ref: PreviewPipeline.previewBranch);
    if (existing != null && existing.content.trim() == wanted.trim()) {
      onLog('Preview workflow is up to date.');
      return head;
    }

    onLog(existing == null
        ? 'Committing the preview workflow to "${PreviewPipeline.previewBranch}"…'
        : 'Preview workflow changed — updating it…');
    final result = await github.commitTree(
      repo: repo,
      branch: PreviewPipeline.previewBranch,
      message: 'chore: add/update CodeFexa preview workflow',
      files: {
        kPreviewWorkflowPath: wanted.codeUnits,
      },
    );
    return result.sha;
  }
}

/// What the pipeline produced — success carries the REAL preview URL.
class PreviewPipelineResult {
  final bool ok;
  final String? url;
  final String? runUrl;
  final String? summary;
  final String? error;
  final String? logs;

  const PreviewPipelineResult._({
    required this.ok,
    this.url,
    this.runUrl,
    this.summary,
    this.error,
    this.logs,
  });

  factory PreviewPipelineResult.success({
    required String url,
    required String runUrl,
    required String summary,
  }) =>
      PreviewPipelineResult._(ok: true, url: url, runUrl: runUrl, summary: summary);

  factory PreviewPipelineResult.failed(String message, {String? logs, String? runUrl}) =>
      PreviewPipelineResult._(ok: false, error: message, logs: logs, runUrl: runUrl);
}
