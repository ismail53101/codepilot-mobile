import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart';
import '../preview_server.dart';
import '../project_service.dart';
import '../theme.dart';

/// Live preview of AI-generated HTML in an in-app WebView.
///
/// Three modes:
/// - [rawHtml] set: renders exactly that HTML (a code block from chat).
/// - [path] set AND a project is open: loads the page through the local
///   loopback HTTP server (http://127.0.0.1:port/<path>), so relative
///   `<link href="style.css">`, `<script src="script.js">`, and
///   `<img src="assets/logo.png">` all resolve from the workspace — CSS
///   applies, JavaScript executes, assets load. Source files are untouched.
/// - [path] set but no project open: falls back to rendering the single
///   file's HTML as a string (relative resources cannot resolve there).
///
/// HTML documents get a minimal mobile viewport meta injected when the
/// generated page forgot one; the author's own markup/CSS/JS is kept as-is.
class PreviewScreen extends StatefulWidget {
  final String? rawHtml;
  final String? html;
  final String? path;

  /// A fully-qualified URL to load directly (e.g. the GitHub Pages URL of a
  /// compiled Flutter/Vite preview). Takes precedence over [path].
  final String? url;

  /// Friendly screen title for project previews (the project name).
  final String? projectTitle;

  const PreviewScreen(
      {super.key,
      this.rawHtml,
      this.html,
      this.path,
      this.url,
      this.projectTitle});

  /// Can this file be previewed in-app?
  static bool isPreviewable(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'html' || ext == 'htm';
  }

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  WebViewController? _controller;
  int _loadProgress = 100;
  String? _error;
  bool _serverMode = false;

  String? _source;
  String? _loadedUrl;

  String? get _raw => widget.rawHtml ?? widget.html;

  @override
  void initState() {
    super.initState();
    // Defer: _initController calls setState, which must not run during
    // initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveSource());
  }

  @override
  void dispose() {
    // The preview server is shared app-wide; leave it running only while
    // this screen needs it. Restarting per navigation is cheap, but stop
    // it when leaving the preview to avoid a lingering listener.
    previewServerInstance.stop();
    super.dispose();
  }

  Future<void> _resolveSource() async {
    if (mounted) setState(() => _error = null); // fresh attempt (Retry)
    final raw = _raw;
    if (raw != null) {
      _initController(raw);
      return;
    }
    // Remote URL mode: compiled previews (GitHub Pages etc.) load directly.
    final remote = widget.url;
    if (remote != null && remote.isNotEmpty) {
      if (!mounted) return;
      setState(() => _serverMode = false);
      _initControllerWithUrl(remote);
      return;
    }

    final path = widget.path;
    if (path == null) {
      if (mounted) setState(() => _error = 'Nothing to preview.');
      return;
    }

    // PROJECT MODE: serve the whole workspace over loopback HTTP.
    final rootPath = projectService.rootPath;
    if (rootPath != null && PreviewScreen.isPreviewable(path)) {
      try {
        final base = await previewServerInstance.start(rootPath);
        final url = '$base/${path.split('/').map(Uri.encodeComponent).join('/')}';
        if (!mounted) return;
        setState(() => _serverMode = true);
        _initControllerWithUrl(url);
        return;
      } on ProjectException catch (e) {
        if (mounted) setState(() => _error = e.message);
        return;
      } catch (e) {
        // Fall through to string mode below if the server can't bind.
      }
    }

    // STRING MODE fallback (no open project / server unavailable).
    String? html;
    try {
      html = projectService.readFile(path);
    } on ProjectException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    }
    if (html == null || html.trim().isEmpty) {
      if (mounted) setState(() => _error ??= 'Nothing to preview.');
      return;
    }
    _initController(html);
  }

  String _wrap(String body) {
    return '''<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html { background: #ffffff; }
  body { margin: 0; padding: 16px; font-family: sans-serif; color: #111;
         word-wrap: break-word; }
  pre { white-space: pre-wrap; }
</style></head><body>$body</body></html>''';
  }

  String _document(String html) {
    final hasViewport = RegExp(r'name\s*=\s*.viewport', caseSensitive: false).hasMatch(html);
    final injection = hasViewport
        ? ''
        : '<meta name="viewport" content="width=device-width, initial-scale=1.0">';
    // Keep the author's own document; only add what's missing.
    if (RegExp(r'<html[\s>]', caseSensitive: false).hasMatch(html)) {
      return html.contains('<head')
          ? html.replaceFirst(RegExp(r'<head[^>]*>', caseSensitive: false), '<head>$injection')
          : html.replaceFirst(RegExp(r'<body[^>]*>', caseSensitive: false), '$injection<body>');
    }
    return _wrap(html);
  }

  void _initController(String initialHtml) {
    _source = initialHtml;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _loadProgress = p) : null,
          onWebResourceError: (e) {
            // External-subresource failures (offline font, etc.) shouldn't
            // blank the screen; only a failed initial load does.
            if (_loadProgress < 100 && mounted) {
              setState(() => _error = 'Preview failed to load: ${e.description}');
            }
          },
        ),
      )
      ..loadHtmlString(_document(initialHtml));
    setState(() {
      _controller = c;
      _loadedUrl = null;
    });
  }

  void _initControllerWithUrl(String url) {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _loadProgress = p) : null,
          onWebResourceError: (e) {
            if (_loadProgress < 100 && mounted) {
              setState(() => _error =
                  'Preview failed to load: ${e.description}\n(check that "${widget.path}" exists)');
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
    setState(() {
      _controller = c;
      _loadedUrl = url;
    });
  }

  Future<void> _reload() async {
    if (_serverMode && widget.path != null) {
      final rootPath = projectService.rootPath;
      if (rootPath == null) return;
      // Re-bind the server so edits are picked up (files are read from disk
      // per request, so a plain reload is enough — but keep the root fresh).
      final base = await previewServerInstance.start(rootPath);
      final url = '$base/${widget.path!.split('/').map(Uri.encodeComponent).join('/')}';
      if (url == _loadedUrl) {
        await _controller?.reload();
      } else {
        _initControllerWithUrl(url);
      }
      return;
    }
    final src = _raw ?? _source;
    if (src != null) _controller!.loadHtmlString(_document(src));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.projectTitle ??
        widget.path?.split('/').last ??
        'Live preview';
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload preview',
            onPressed: _controller == null ? null : _reload,
          ),
          if (_loadedUrl != null)
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) async {
                if (v == 'browser') {
                  final uri = Uri.parse(_loadedUrl!);
                  // The loopback URL opens in the device's own browser.
                  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('No browser available to open the preview.'),
                          duration: Duration(seconds: 2)));
                    }
                  }
                } else if (v == 'url') {
                  await Clipboard.setData(ClipboardData(text: _loadedUrl!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Preview URL copied'),
                        duration: Duration(seconds: 1)));
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'browser',
                    child: Row(children: [
                      Icon(Icons.open_in_browser, size: 16),
                      SizedBox(width: 8),
                      Text('Open in browser', style: TextStyle(fontSize: 13)),
                    ])),
                PopupMenuItem(
                    value: 'url',
                    child: Row(children: [
                      Icon(Icons.link, size: 16),
                      SizedBox(width: 8),
                      Text('Copy preview URL', style: TextStyle(fontSize: 13)),
                    ])),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy source',
            onPressed: _source == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _source!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Source copied'), duration: Duration(seconds: 1)));
                    }
                  },
          ),
        ],
        bottom: _loadProgress < 100 && _error == null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _loadProgress / 100,
                  backgroundColor: AppTheme.surface,
                  color: AppTheme.glowAccent,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: _error != null
          ? _errorView()
          : _controller == null
              ? const Center(child: CircularProgressIndicator(color: AppTheme.glowAccent))
              : WebViewWidget(controller: _controller!),
    );
  }

  /// Honest failure state — never a fake success: the real reason plus
  /// Retry. Back navigation is the AppBar's ← button (Back to Project).
  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: AppTheme.err, size: 30),
          const SizedBox(height: 10),
          const Text('Preview failed to load',
              style: TextStyle(
                  color: AppTheme.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.glowAccent),
            onPressed: () {
              setState(() {
                _error = null;
                _controller = null;
              });
              _resolveSource();
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ]),
      ),
    );
  }
}

/// Reusable "open HTML in live preview" helper.
Future<void> openHtmlPreview(BuildContext context, {String? rawHtml, String? path}) async {
  final html = rawHtml;
  if (html == null && (path == null || !PreviewScreen.isPreviewable(path))) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PreviewScreen(rawHtml: html, path: path),
    ),
  );
}

/// Named-route adapter: arguments are either a raw HTML string or a map
/// {'rawHtml': String} / {'path': String}.
class LivePreviewRoute extends StatelessWidget {
  const LivePreviewRoute({super.key});

  @override
  Widget build(BuildContext context) {
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is String && arg.trim().isNotEmpty) {
      return PreviewScreen(rawHtml: arg);
    }
    if (arg is Map) {
      final raw = arg['rawHtml'];
      final path = arg['path'];
      if (raw is String) return PreviewScreen(rawHtml: raw);
      if (path is String) return PreviewScreen(path: path);
    }
    return const PreviewScreen();
  }
}
