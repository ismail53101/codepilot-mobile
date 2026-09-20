import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/providers/provider_config.dart';

void main() {
  group('maskKey', () {
    test('shows only the last 4 characters', () {
      expect(maskKey('sk-proj-abcdef9f2a8F42'), '••••••••8F42');
      expect(maskKey('AIzaSyC1234567890abcdE'), '••••••••bcdE');
    });

    test('fully masks short keys (never leaks a hint of them)', () {
      expect(maskKey('abc123'), '••••••••');
      expect(maskKey('sk-12'), '••••••••');
      expect(maskKey(''), '••••••••');
    });
  });

  group('ProviderConfig', () {
    test('JSON round-trip preserves every field', () {
      const c = ProviderConfig(
        id: 'prov_1',
        type: AiProviderType.openRouter,
        label: 'Key 2 — free tier',
        model: 'qwen/qwen3.7-flash:free',
        baseUrl: '',
        enabled: false,
        priority: 3,
        isDefault: true,
      );
      final restored = ProviderConfig.fromJson(c.toJson());
      expect(restored.id, c.id);
      expect(restored.type, AiProviderType.openRouter);
      expect(restored.label, c.label);
      expect(restored.model, c.model);
      expect(restored.enabled, isFalse);
      expect(restored.priority, 3);
      expect(restored.isDefault, isTrue);
    });

    test('effectiveBaseUrl prefers the override, else the provider default',
        () {
      const custom = ProviderConfig(
          id: 'a', type: AiProviderType.openRouter, model: 'm',
          baseUrl: 'https://my-proxy.dev/v1');
      expect(custom.effectiveBaseUrl, 'https://my-proxy.dev/v1');

      const openai = ProviderConfig(
          id: 'b', type: AiProviderType.openai, model: 'm');
      expect(openai.effectiveBaseUrl, 'https://api.openai.com/v1');

      const customNoUrl = ProviderConfig(
          id: 'c', type: AiProviderType.custom, model: 'm');
      expect(() => customNoUrl.effectiveBaseUrl, throwsStateError);
    });

    test('byPriority orders lower first, default breaks ties, id last', () {
      const c3 = ProviderConfig(id: 'c', type: AiProviderType.openai,
          model: 'm', priority: 5);
      const c1 = ProviderConfig(id: 'a', type: AiProviderType.openai,
          model: 'm', priority: 1);
      const c2default = ProviderConfig(id: 'b', type: AiProviderType.openai,
          model: 'm', priority: 5, isDefault: true);
      final list = [c3, c1, c2default]..sort(ProviderConfig.byPriority);
      expect(list.map((c) => c.id).toList(), ['a', 'b', 'c']);
    });

    test('displayName prefers the label', () {
      const labeled = ProviderConfig(
          id: 'x', type: AiProviderType.gemini, model: 'gemini-1.5-flash',
          label: 'Work key');
      expect(labeled.displayName, 'Work key');
      const unlabeled = ProviderConfig(
          id: 'y', type: AiProviderType.gemini, model: 'gemini-1.5-flash');
      expect(unlabeled.displayName, 'Google Gemini · gemini-1.5-flash');
    });
  });
}
