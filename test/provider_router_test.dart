import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:codepilot_mobile/api_client.dart';
import 'package:codepilot_mobile/models.dart';
import 'package:codepilot_mobile/providers/provider_config.dart';
import 'package:codepilot_mobile/providers/provider_router.dart';
import 'package:codepilot_mobile/providers/provider_store.dart';
import 'package:codepilot_mobile/stores.dart';

class FakeSecureStore extends SecureStore {
  final String? key;
  FakeSecureStore(this.key);

  @override
  Future<String?> readApiKey() async => key;
}

class FakeBackend implements ChatBackend {
  final String tag;
  final ApiException? failure;
  int calls = 0;

  FakeBackend(this.tag, [this.failure]);

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 1,
  }) async {
    calls++;
    if (failure != null) throw failure!;
    return (content: 'ok-from-$tag', toolCalls: const []);
  }
}

void main() {
  late ProviderStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = ProviderStore(keyVault: InMemoryKeyVault());
  });

  Future<ProviderRouter> routerWith(
    Map<String, ChatBackend> backends, {
    SettingsStore? legacy,
    int maxAttempts = 5,
  }) async {
    await store.migrateLegacyIfNeeded(
        legacy ?? SettingsStore(secure: FakeSecureStore(null)));
    return ProviderRouter(
      store: store,
      legacy: legacy ?? SettingsStore(secure: FakeSecureStore(null)),
      maxAttempts: maxAttempts,
      backendFactory: (config, key) =>
          backends[config.id] ?? FakeBackend(config.id),
    );
  }

  ProviderConfig cfg(String id,
      {int priority = 10,
      bool enabled = true,
      bool isDefault = false,
      String label = ''}) {
    return ProviderConfig(
      id: id,
      type: AiProviderType.openRouter,
      label: label,
      model: 'm-$id',
      enabled: enabled,
      priority: priority,
      isDefault: isDefault,
    );
  }

  test('automatic mode falls back from a rate-limited key to the next config',
      () async {
    await store.upsert(cfg('a', priority: 1, label: 'OpenRouter K1'));
    await store.upsert(cfg('b', priority: 2, label: 'OpenRouter K2'));
    await store.writeKey('a', 'sk-aaaaaaaaaaaaaaaa1');
    await store.writeKey('b', 'sk-bbbbbbbbbbbbbbbb2');
    final backends = {
      'a': FakeBackend('a', const ApiException('rate limited', 'rate_limited')),
      'b': FakeBackend('b'),
    };
    final router = await routerWith(backends);

    final result = await router.chatWithTools(const [
      ChatMessage(role: 'user', content: 'hi'),
    ]);
    expect(result.content, 'ok-from-b');
    expect(backends['a']!.calls, 1);
    expect(backends['b']!.calls, 1);
  });

  test('disabled configs and configs without keys are skipped', () async {
    await store.upsert(cfg('disabled', priority: 1, enabled: false));
    await store.upsert(cfg('nokey', priority: 2));
    await store.upsert(cfg('good', priority: 3, isDefault: true));
    await store.writeKey('good', 'sk-gggggggggggggggg3');
    final backends = {'good': FakeBackend('good')};
    final router = await routerWith(backends);

    final candidates = await router.resolveCandidates();
    expect(candidates.map((c) => c.$1.id), ['good']);
    expect((await router.chatWithTools(const [
      ChatMessage(role: 'user', content: 'hi'),
    ]))
        .content, 'ok-from-good');
  });

  test('manual mode uses ONLY the selected config (no cross fallback)',
      () async {
    await store.upsert(cfg('a', priority: 1));
    await store.upsert(cfg('b', priority: 2));
    await store.writeKey('a', 'sk-aaaaaaaaaaaaaaaa1');
    await store.writeKey('b', 'sk-bbbbbbbbbbbbbbbb2');
    final backends = {
      'a': FakeBackend('a'),
      'b': FakeBackend('b', const ApiException('invalid key', 'invalid_api_key')),
    };
    await store.saveRouting(
        const RoutingSettings(mode: RoutingMode.manual, manualConfigId: 'b'));
    final router = await routerWith(backends);

    await expectLater(
      router.chatWithTools(const [ChatMessage(role: 'user', content: 'hi')]),
      throwsA(isA<ApiException>()
          .having((e) => e.kind, 'kind', 'invalid_api_key')),
    );
    expect(backends['a']!.calls, 0, reason: 'manual mode must not fall back');
  });

  test('a user cancel aborts the whole fallback chain immediately',
      () async {
    await store.upsert(cfg('a', priority: 1));
    await store.upsert(cfg('b', priority: 2));
    await store.writeKey('a', 'sk-aaaaaaaaaaaaaaaa1');
    await store.writeKey('b', 'sk-bbbbbbbbbbbbbbbb2');
    final backends = {
      'a': FakeBackend('a', const ApiException('Cancelled.', 'cancelled')),
      'b': FakeBackend('b'),
    };
    final router = await routerWith(backends);

    await expectLater(
      router.chatWithTools(const [ChatMessage(role: 'user', content: 'hi')]),
      throwsA(isA<ApiException>()
          .having((e) => e.kind, 'kind', 'cancelled')),
    );
    expect(backends['b']!.calls, 0);
  });

  test('when everything fails the aggregated error is key-free and detailed',
      () async {
    await store.upsert(cfg('a', priority: 1, label: 'OpenRouter K1'));
    await store.upsert(cfg('b', priority: 2, label: 'Gemini K1'));
    await store.writeKey('a', 'sk-SECRET-aaaaaaaa1');
    await store.writeKey('b', 'sk-SECRET-bbbbbbbb2');
    final backends = {
      'a': FakeBackend('a', const ApiException('Rate limited.', 'rate_limited')),
      'b': FakeBackend('b',
          const ApiException('Quota exceeded.', 'insufficient_quota')),
    };
    final router = await routerWith(backends);

    try {
      await router.chatWithTools(const [ChatMessage(role: 'user', content: 'x')]);
      fail('should have thrown');
    } on ApiException catch (e) {
      expect(e.message, contains('OpenRouter K1'));
      expect(e.message, contains('Gemini K1'));
      expect(e.message, contains('Rate limited.'));
      expect(e.message, contains('Quota exceeded.'));
      expect(e.message, isNot(contains('SECRET')));
    }
  });

  test('fallback attempts are capped at maxAttempts (no infinite loops)',
      () async {
    for (var i = 1; i <= 6; i++) {
      await store.upsert(cfg('f$i', priority: i));
      await store.writeKey('f$i', 'sk-key-${i}xxxxxxxxxxx');
    }
    final created = <String>[];
    final router = ProviderRouter(
      store: store,
      legacy: SettingsStore(secure: FakeSecureStore(null)),
      maxAttempts: 3,
      backendFactory: (config, key) {
        created.add(config.id);
        return FakeBackend(config.id,
            const ApiException('Rate limited.', 'rate_limited'));
      },
    );

    try {
      await router.chatWithTools(
          const [ChatMessage(role: 'user', content: 'x')]);
      fail('should have thrown');
    } on ApiException {
      // Only the first 3 candidates may ever be attempted.
      expect(created, hasLength(3));
      expect(created, ['f1', 'f2', 'f3']);
    }
  });

  test('legacy single-provider setup migrates into the config list once',
      () async {
    SharedPreferences.setMockInitialValues({});
    final legacy = SettingsStore(secure: FakeSecureStore('sk-legacy-00001234'));
    final router = ProviderRouter(
      store: store,
      legacy: legacy,
      backendFactory: (config, key) => FakeBackend(config.id),
    );

    final candidates = await router.resolveCandidates();
    expect(candidates, hasLength(1));
    expect(candidates.first.$1.id, 'legacy_primary');
    expect(candidates.first.$1.isDefault, isTrue);
    expect(candidates.first.$1.priority, 1);

    // Idempotent: a second resolve must not duplicate it.
    final again = await router.resolveCandidates();
    expect(again, hasLength(1));
  });

  test('no enabled key at all → actionable error pointing at the manager',
      () async {
    final router = await routerWith({});
    await expectLater(
      router.chatWithTools(const [ChatMessage(role: 'user', content: 'x')]),
      throwsA(isA<ApiException>()
          .having((e) => e.kind, 'kind', 'no_api_key')
          .having((e) => e.message, 'message', contains('API Key'))),
    );
  });
}
