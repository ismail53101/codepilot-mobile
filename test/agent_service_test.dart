import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/agent_service.dart';
import 'package:codepilot_mobile/models.dart';

void main() {
  group('AgentService.parseReply', () {
    test('parses write and delete blocks from a model reply', () {
      const reply = '''
I will add a config file and remove the old one.
```codepilot:write lib/config.dart
const apiKeyPlaceholder = 'SET_ME';
```
```codepilot:delete lib/old_config.dart
```
Done.''';
      final parsed = AgentService.parseReply(reply);
      expect(parsed.changes.length, 2);
      expect(parsed.changes[0].kind, 'write');
      expect(parsed.changes[0].path, 'lib/config.dart');
      expect(parsed.changes[0].after, contains('SET_ME'));
      expect(parsed.changes[1].kind, 'delete');
      expect(parsed.changes[1].path, 'lib/old_config.dart');
      expect(parsed.explanation, isNot(contains('codepilot:')));
    });

    test('returns no changes for a plain explanation', () {
      const reply = 'This project is a Flutter app with two screens.';
      final parsed = AgentService.parseReply(reply);
      expect(parsed.changes, isEmpty);
      expect(parsed.explanation, contains('Flutter'));
    });
  });

  group('DiffLine model', () {
    test('holds type and text', () {
      const l = DiffLine('add', 'final x = 1;');
      expect(l.type, 'add');
      expect(l.text, 'final x = 1;');
    });
  });
}
