import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show projectService, githubService;
import '../preview_pipeline.dart';
import '../screens/preview_screen.dart';
import '../theme.dart';

/// Runs the type-aware preview pipeline with REAL progress: each pipeline
/// stage logs its actual output, the GitHub Actions run status is polled
/// live, and the result is either a real live preview URL (opened in the
/// existing PreviewScreen through the loopback-independent URL mode), the
/// run URL for APK artifacts, or the real build log on failure.
class PreviewPipelineScreen extends StatefulWidget {
  final PreviewPlan plan;
  const PreviewPipelineScreen({super.key, required this.plan});

  @override
  State<PreviewPipelineScreen> createState() => _PreviewPipelineScreenState();
}

class _PreviewPipelineScreenState extends State<PreviewPipelineScreen> {
  final List<String> _log = [];
  final ScrollController _scroll = ScrollController();
  bool _running = false;
  double? _progress;
  PreviewPipelineResult? _result;
  final PreviewPipeline _pipeline = PreviewPipeline(githubService);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _logLine(String s) {
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _result = null;
      _log.clear();
      _progress = null;
    });
    final input = switch (widget.plan.projectType) {
      'Flutter' => 'flutter',
      'React (Vite)' => 'vite',
      'Next.js' => 'nextjs',
      'Node.js' => 'node',
      'Python' => 'python',
      'Android' => 'android',
      _ => 'flutter',
    };
    final result = await _pipeline.run(
      plan: widget.plan,
      projectTypeInput: input,
      onLog: _logLine,
      onProgress: (p) => mounted ? setState(() => _progress = p) : null,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = 'Preview — ${widget.plan.projectType}';
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text(title, style: const TextStyle(fontSize: 16))),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              widget.plan.summary,
              style: const TextStyle(color: AppTheme.muted, fontSize: 12.5),
            ),
          ),
          if (_running)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: AppTheme.surface,
                color: AppTheme.glowAccent,
                minHeight: 3,
              ),
            ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: _log.isEmpty
                  ? const Center(
                      child: Text('Starting…',
                          style: TextStyle(color: AppTheme.muted, fontSize: 12)))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _log.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          _log[i],
                          style: const TextStyle(
                              color: AppTheme.text,
                              fontSize: 11.5,
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ),
            ),
          ),
          _resultView(),
        ],
      ),
    );
  }

  Widget _resultView() {
    final r = _result;
    if (r == null) {
      return const SizedBox(height: 8);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(
              r.ok ? Icons.check_circle : Icons.error_outline,
              size: 18,
              color: r.ok ? AppTheme.ok : AppTheme.err,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.ok ? (r.summary ?? 'Done.') : (r.error ?? 'Failed.'),
                style: TextStyle(
                  color: r.ok ? AppTheme.ok : AppTheme.err,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
          if (r.logs != null && r.logs!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: SingleChildScrollView(
                  child: Text(r.logs!,
                      style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 10.5,
                          fontFamily: 'monospace')),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (r.ok && r.url != null) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.glowAccent),
                  onPressed: () => _openPreview(r.url!),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(
                    widget.plan.outcome == PreviewOutcome.pagesPreview
                        ? 'Open Live Preview'
                        : 'Open Run',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: r.url!));
                    messenger.showSnackBar(const SnackBar(
                        content: Text('Preview URL copied'),
                        duration: Duration(seconds: 1)));
                  },
                  icon: const Icon(Icons.link, size: 14),
                  label: const Text('Copy URL'),
                ),
              ],
              if (!r.ok && r.runUrl != null)
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(r.runUrl!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('Open GitHub run'),
                ),
              OutlinedButton(
                onPressed: _running ? null : _start,
                child: Text(r.ok ? 'Rebuild' : 'Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openPreview(String url) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(url: url, projectTitle: projectService.projectName),
      ),
    );
  }
}
