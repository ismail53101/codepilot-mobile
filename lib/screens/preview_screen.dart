import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Live preview of AI-generated HTML in an in-app WebView.
///
/// Two modes:
/// - [rawHtml] set: renders exactly that HTML (a code block from chat).
/// - [path] set: loads a previewable file from the open project workspace.
///
/// HTML documents are darkened politely (page keeps its own colors once its
/// own CSS loads), and a minimal mobile viewport meta is injected when the
/// generated page forgot one — AI output frequently does.
class PreviewScreen extends StatefulWidget {
  final String? rawHtml;
  final String? html;
  final String? path;

  const PreviewScreen({super.key, this.rawHtml, this.html, this.path});

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

  String? _source;

  String? get _raw => widget.rawHtml ?? widget.html;

  @override
  void initState() {
    super.initState();
    // Defer: _initController calls setState, which must not run during
    // initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveSource());
  }

  Future<void> _resolveSource() async {
    var html = widget.rawHtml ?? widget.html;
    if (html == null && widget.path != null) {
      try {
        html = projectService.readFile(widget.path!);
      } on ProjectException catch (e) {
        if (mounted) setState(() => _error = e.message);
        return;
      }
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
    final hasViewport = RegExp(r'name\s*=\s*["\']viewport', caseSensitive: false).hasMatch(html);
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
    setState(() => _controller = c);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.path?.split('/').last ?? 'Live preview';
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload preview',
            onPressed: _controller == null
                ? null
                : () {
                    final src = _raw ?? _source;
                    if (src != null) _controller!.loadHtmlString(_document(src));
                  },
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
        bottom: _loadProgress < 100
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: const TextStyle(color: AppTheme.err)),
              ),
            )
          : _controller == null
              ? const Center(child: CircularProgressIndicator(color: AppTheme.glowAccent))
              : WebViewWidget(controller: _controller!),
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
