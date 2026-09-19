import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_service.dart';

/// Local HTTP static server bound to 127.0.0.1, serving ONE project's files.
///
/// Why: WebView `loadHtmlString` has no base URL, so `<link href="style.css">`,
/// `<script src="script.js">`, and `<img src="assets/logo.png">` can never
/// resolve. Serving the workspace over loopback HTTP lets the browser fetch
/// every relative resource through normal HTTP — CSS applies, JavaScript
/// executes, local assets load. Source files are NOT modified.
///
/// Security: paths are resolved inside the project root only (traversal
/// blocked); the server binds to loopback so other devices cannot reach it.
class PreviewServer {
  HttpServer? _server;
  String? _rootPath;
  int? _port;

  bool get isRunning => _server != null;
  String? get baseUrl => _port == null ? null : 'http://127.0.0.1:$_port';

  /// Start (or restart against a new root) serving [rootPath].
  /// Returns the base URL, e.g. http://127.0.0.1:8013
  Future<String> start(String rootPath) async {
    if (_server != null && _rootPath == rootPath) return baseUrl!;
    await stop();
    _rootPath = rootPath;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle, onError: (_) {});
    return baseUrl!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    _rootPath = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final root = _rootPath;
      if (root == null) {
        await _respond(request, HttpStatus.internalServerError, 'text/plain', 'server stopped');
        return;
      }
      var urlPath = Uri.decodeComponent(request.uri.path);
      if (urlPath.startsWith('/')) urlPath = urlPath.substring(1);
      if (urlPath.isEmpty) urlPath = 'index.html';

      final resolved = p.normalize(p.join(root, urlPath));
      final rootNorm = p.normalize(root);
      if (!p.isWithin(rootNorm, resolved) && resolved != rootNorm) {
        await _respond(request, HttpStatus.forbidden, 'text/plain', 'forbidden');
        return;
      }

      final file = File(resolved);
      if (file.existsSync()) {
        // Never serve CodePilot's own metadata or hidden files.
        final base = p.basename(resolved);
        if (base.startsWith('.')) {
          await _respond(request, HttpStatus.forbidden, 'text/plain', 'forbidden');
          return;
        }
        final ext = p.extension(resolved).toLowerCase();
        final type = _contentType(ext);
        if (type == null) {
          await _respond(request, HttpStatus.unsupportedMediaType, 'text/plain',
              'unsupported file type');
          return;
        }
        final bytes = file.readAsBytesSync();
        request.response.headers
          ..contentType = ContentType.parse(type)
          ..add('Access-Control-Allow-Origin', '*');
        request.response.add(bytes);
        await request.response.close();
        return;
      }

      final dir = Directory(resolved);
      if (dir.existsSync()) {
        final index = File(p.join(resolved, 'index.html'));
        if (index.existsSync()) {
          request.response.headers.contentType =
              ContentType.parse('text/html; charset=utf-8');
          await request.response.addStream(index.openRead());
          await request.response.close();
          return;
        }
        await _respond(request, HttpStatus.notFound, 'text/plain',
            'directory has no index.html');
        return;
      }

      // SPA fallback: unknown extension-less routes go to index.html so
      // hash/history-routed apps render. Unknown files 404 honestly.
      final segments = urlPath.split('/');
      final last = segments.last;
      if (!last.contains('.') &&
          File(p.join(root, 'index.html')).existsSync()) {
        final index = File(p.join(root, 'index.html'));
        request.response.headers.contentType =
            ContentType.parse('text/html; charset=utf-8');
        await request.response.addStream(index.openRead());
        await request.response.close();
        return;
      }
      await _respond(request, HttpStatus.notFound, 'text/plain', 'not found: $urlPath');
    } catch (e) {
      try {
        await _respond(request, HttpStatus.internalServerError, 'text/plain', 'error: $e');
      } catch (_) {}
    }
  }

  Future<void> _respond(
      HttpRequest request, int status, String type, String body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.parse(type);
    request.response.write(body);
    await request.response.close();
  }

  /// Null = refuse to serve (binaries, secrets).
  String? _contentType(String ext) => switch (ext) {
        '.html' || '.htm' => 'text/html; charset=utf-8',
        '.css' => 'text/css; charset=utf-8',
        '.js' || '.mjs' => 'application/javascript; charset=utf-8',
        '.json' || '.map' => 'application/json; charset=utf-8',
        '.svg' => 'image/svg+xml',
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.ico' => 'image/x-icon',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
        '.ttf' => 'font/ttf',
        '.otf' => 'font/otf',
        '.eot' => 'application/vnd.ms-fontobject',
        '.mp3' => 'audio/mpeg',
        '.mp4' => 'video/mp4',
        '.webm' => 'video/webm',
        '.txt' || '.md' => 'text/plain; charset=utf-8',
        '.xml' => 'application/xml',
        '.pdf' => 'application/pdf',
        // Never serve dotfiles/secrets or unknown binaries.
        _ => null,
      };
}

/// Singleton owning the app-wide preview server (one server, one root at a
/// time — restarting against another project root is cheap).
PreviewServer previewServerInstance = PreviewServer();
