import 'package:flutter_test/flutter_test.dart';
// Stable-id contract tests for ChatMessage.

import 'package:codepilot_mobile/models.dart';

void main() {
  group('ChatMessage stable id', () {
    test('auto-generated ids are unique across messages', () {
      final a = ChatMessage(role: 'user', content: 'one');
      final b = ChatMessage(role: 'user', content: 'two');
      expect(a.id, isNotEmpty);
      expect(b.id, isNotEmpty);
      expect(a.id, isNot(b.id));
    });

    test('explicit id is preserved', () {
      final m = ChatMessage(role: 'user', content: 'x', id: 'fixed-id');
      expect(m.id, 'fixed-id');
    });

    test('id survives the session-storage JSON round-trip', () {
      final m = ChatMessage(role: 'user', content: 'hello', hasImage: true);
      final restored = ChatMessage.fromJson(m.toJson());
      expect(restored.id, m.id);
      expect(restored.hasImage, isTrue);
    });

    test('legacy transcript without id gets a fresh stable id', () {
      final restored = ChatMessage.fromJson({'role': 'user', 'content': 'hi'});
      expect(restored.id, isNotEmpty);
    });

    test('rapid creation still yields distinct ids (counter suffix)', () {
      final ids = <String>{};
      for (var i = 0; i < 100; i++) {
        ids.add(ChatMessage(role: 'user', content: 'm$i').id);
      }
      expect(ids, hasLength(100));
    });
  });
}
