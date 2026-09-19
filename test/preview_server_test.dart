import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:codepilot_mobile/preview_server.dart';

void main() {
  late Directory temp;
  late PreviewServer server;
  late HttpClient client;
  late String base;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('preview_test');
    // A small web project: index.html links style.css + script.js and an
    // image in assets/.
    File(p.join(temp.path, 'index.html')).writeAsStringSync('''
<!DOCTYPE html><html><head>
<link rel="stylesheet" href="style.css">
<script src="script.js"></script>
</head><body><h1>Hi</h1><img src="assets/logo.png"></body></html>
''');
    File(p.join(temp.path, 'style.css'))
        .writeAsStringSync('body { color: red; }');
    File(p.join(temp.path, 'script.js'))
        .writeAsStringSync('console.log("ok");');
    Directory(p.join(temp.path, 'assets')).createSync();
    File(p.join(temp.path, 'assets', 'logo.png')).writeAsBytesSync([1, 2, 3]);
    // A nested page with parent-relative resources.
    Directory(p.join(temp.path, 'pages')).createSync();
    File(p.join(temp.path, 'pages', 'login.html')).writeAsStringSync(
        '<html><head><link rel="stylesheet" href="../style.css"></head></html>');
    // Dotfile that must never be served.
    File(p.join(temp.path, '.codepilot_manifest.json'))
        .writeAsStringSync('{"secret": true}');

    server = PreviewServer();
    base = await server.start(temp.path);
    client = HttpClient();
  });

  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    temp.deleteSync(recursive: true);
  });

  Future<(int, String)> get(String path) async {
    final req = await client.getUrl(Uri.parse('$base$path'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return (resp.statusCode, body);
  }

  test('serves index.html at /', () async {
    final (status, body) = await get('/index.html');
    expect(status, 200);
    expect(body, contains('<link rel="stylesheet" href="style.css">'));
  });

  test('serves relative CSS/JS with correct content types', () async {
    var (status, body) = await get('/style.css');
    expect(status, 200);
    expect(body, contains('color: red'));

    (status, body) = await get('/script.js');
    expect(status, 200);
    expect(body, contains('console.log'));
  });

  test('serves binary assets (png) with image content type', () async {
    final req = await client.getUrl(Uri.parse('$base/assets/logo.png'));
    final resp = await req.close();
    expect(resp.statusCode, 200);
    expect(resp.headers.contentType?.mimeType, 'image/png');
    final bytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, [1, 2, 3]);
  });

  test('nested page and parent-relative path resolve', () async {
    final (status, body) = await get('/pages/login.html');
    expect(status, 200);
    expect(body, contains('href="../style.css"'));
  });

  test('blocks path traversal outside the project root', () async {
    final (status, _) = await get('/..%2F..%2Fetc%2Fpasswd');
    expect(status, anyOf(403, 404));
  });

  test('never serves dotfiles / CodePilot metadata', () async {
    final (status, _) = await get('/.codepilot_manifest.json');
    expect(status, 403);
  });

  test('404 for missing files', () async {
    final (status, _) = await get('/nope.css');
    expect(status, 404);
  });
}
