import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:codepilot_mobile/preview_manager.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('preview_mgr_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  PreviewResolution resolve() => resolvePreviewInDirectory(
        rootPath: temp.path,
        projectName: 'Test Project',
      );

  test('static web project with index.html at root is previewable', () {
    File(p.join(temp.path, 'index.html')).writeAsStringSync('<html></html>');
    File(p.join(temp.path, 'style.css')).writeAsStringSync('body{}');
    File(p.join(temp.path, 'script.js')).writeAsStringSync('console.log(1);');

    final res = resolve();
    expect(res.supported, isTrue);
    expect(res.projectType, 'HTML/CSS/JS');
    expect(res.entryPath, 'index.html');
  });

  test('HTML entry is discovered when it is not at the root', () {
    Directory(p.join(temp.path, 'pages')).createSync();
    File(p.join(temp.path, 'pages', 'about.html'))
        .writeAsStringSync('<html></html>');

    final res = resolve();
    expect(res.supported, isTrue);
    expect(res.entryPath, 'pages/about.html');
  });

  test('dotfiles are never picked as the entry', () {
    File(p.join(temp.path, '.hidden.html')).writeAsStringSync('<html></html>');

    final res = resolve();
    expect(res.supported, isFalse,
        reason: 'a lone dotfile HTML is not an entry point');
  });

  test('Flutter projects are honestly NOT previewable with the real reason',
      () {
    File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
    Directory(p.join(temp.path, 'lib')).createSync();
    File(p.join(temp.path, 'lib', 'main.dart')).writeAsStringSync('void main(){}');

    final res = resolve();
    expect(res.supported, isFalse);
    expect(res.projectType, 'Flutter');
    expect(res.reason, contains('toolchain'));
    expect(res.hint, isNotNull);
  });

  test('Next.js projects are honestly NOT previewable', () {
    File(p.join(temp.path, 'package.json'))
        .writeAsStringSync('{"dependencies":{"next":"14.0.0"}}\n');

    final res = resolve();
    expect(res.supported, isFalse);
    expect(res.projectType, 'Next.js');
    expect(res.reason, contains('npm'));
  });

  test('plain Node projects are honestly NOT previewable', () {
    File(p.join(temp.path, 'package.json'))
        .writeAsStringSync('{"dependencies":{"express":"4"}}\n');

    final res = resolve();
    expect(res.supported, isFalse);
    expect(res.projectType, 'Node.js');
  });

  test('a folder with no HTML entry explains exactly that', () {
    File(p.join(temp.path, 'readme.md')).writeAsStringSync('# hi\n');

    final res = resolve();
    expect(res.supported, isFalse);
    expect(res.reason, contains('No HTML entry file'));
  });

  test('a missing project folder fails honestly', () {
    final res = resolvePreviewInDirectory(
      rootPath: p.join(temp.path, 'does-not-exist'),
      projectName: 'Ghost',
    );
    expect(res.supported, isFalse);
    expect(res.reason, contains('no longer exists'));
  });
}
