import '../api_client.dart' show CancelToken, ChatBackend, ApiException, ToolCall;
import '../models.dart';
import '../stores.dart';
import 'provider_backends.dart';
import 'provider_config.dart';
import 'provider_store.dart';

/// Central AI PROVIDER ROUTER.
///
/// USER REQUEST → Router → Provider → Key → Model → AI RESPONSE
///
/// - Automatic mode: enabled configs ordered by priority (1 = first); on a
///   fallback-able failure (rate limit, quota, invalid/expired key, provider
///   outage, network, timeout, missing key) the NEXT candidate is tried.
/// - Manual mode: exactly the user-selected config — no cross-provider
///   fallback (if it fails, the real error is reported).
///
/// Safety: attempts are capped at [maxAttempts]; a user cancel aborts the
/// whole chain immediately; the final error NEVER contains key material.
class ProviderRouter implements ChatBackend {
  final ProviderStore store;
  final SettingsStore legacy;

  /// Hard cap on provider attempts per request — prevents runaway fallback.
  final int maxAttempts;

  /// Injectable for tests: builds the concrete backend for a config+key.
  final ChatBackend Function(ProviderConfig config, String key)? _factory;

  ProviderRouter({
    required this.store,
    required this.legacy,
    this.maxAttempts = 5,
    ChatBackend Function(ProviderConfig config, String key)? backendFactory,
  }) : _factory = backendFactory;

  ChatBackend _backendFor(ProviderConfig c, String key) =>
      _factory?.call(c, key) ?? AiProviderBackend.forConfig(c, key);

  /// Ordered (config, backend) pairs for ONE request. Configs without a
  /// stored key are skipped — they simply can't be used.
  Future<List<(ProviderConfig, ChatBackend)>> resolveCandidates() async {
    await store.migrateLegacyIfNeeded(legacy);
    final configs = await store.loadConfigs();
    final routing = await store.loadRouting();

    List<ProviderConfig> ordered;
    if (routing.mode == RoutingMode.manual && routing.manualConfigId.isNotEmpty) {
      // Manual: exactly the chosen config. If it was deleted meanwhile,
      // fall back to automatic ordering (defensive, never a dead end).
      final chosen =
          configs.where((c) => c.id == routing.manualConfigId).toList();
      ordered = chosen.isNotEmpty
          ? chosen
          : (configs.where((c) => c.enabled).toList()
            ..sort(ProviderConfig.byPriority));
    } else {
      ordered = (configs.where((c) => c.enabled).toList()
        ..sort(ProviderConfig.byPriority));
    }

    final out = <(ProviderConfig, ChatBackend)>[];
    for (final c in ordered) {
      if (out.length >= maxAttempts) break;
      final key = await store.readKey(c.id);
      if (key == null || key.trim().isEmpty) continue;
      out.add((c, _backendFor(c, key.trim())));
    }
    return out;
  }

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 1,
  }) async {
    final candidates = await resolveCandidates();
    if (candidates.isEmpty) {
      throw const ApiException(
          'No AI provider with an API key is enabled. Open 🔑 → API Key '
          'Manager to add one.',
          'no_api_key');
    }

    final failures = <String>[];
    ApiException? lastError;
    var attempts = 0;
    for (var i = 0; i < candidates.length && attempts < maxAttempts; i++) {
      final (config, backend) = candidates[i];
      attempts++;
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiException('Cancelled.', 'cancelled');
      }
      try {
        return await backend.chatWithTools(
          messages,
          tools: tools,
          timeoutSeconds: timeoutSeconds,
          cancelToken: cancelToken,
          retries: 1, // retrying happens across KEYS here, not within one
        );
      } on ApiException catch (e) {
        if (e.kind == 'cancelled') rethrow; // user stop: abort the chain
        lastError = e;
        failures.add('${config.displayName}: ${e.message}');
      }
    }

    // Every candidate failed. Exactly one attempt → rethrow the original
    // error so the exact diagnosis (invalid key, rate limit…) survives;
    // several → aggregate, still key-free.
    if (failures.length == 1 && lastError != null) {
      throw ApiException(
          '${candidates.first.$1.displayName}: ${lastError.message}',
          lastError.kind);
    }
    throw ApiException(
      'All configured AI providers failed ($attempts tried):\n'
      '${failures.map((f) => '• $f').join('\n')}',
      'provider',
    );
  }

  /// Non-streaming plain chat with fallback (used by the chat screen).
  Future<String> chatWithFallback(
    List<ChatMessage> messages, {
    int? timeoutSeconds,
    CancelToken? cancelToken,
  }) async {
    final r = await chatWithTools(messages,
        timeoutSeconds: timeoutSeconds, cancelToken: cancelToken);
    return r.content;
  }

  /// Streaming plain chat with fallback: tries streaming candidates in
  /// priority order; a provider that fails BEFORE its first token is
  /// skipped, and if nothing streams the chain ends in one non-streaming
  /// request. Mid-stream errors propagate honestly (a partial reply is
  /// never silently swapped).
  Stream<String> streamWithFallback(
    List<ChatMessage> messages, {
    int? timeoutSeconds,
    CancelToken? cancelToken,
  }) async* {
    final candidates = await resolveCandidates();
    if (candidates.isEmpty) {
      throw const ApiException(
          'No AI provider with an API key is enabled. Open 🔑 → API Key '
          'Manager to add one.',
          'no_api_key');
    }
    final failures = <String>[];
    for (var i = 0; i < candidates.length && i < maxAttempts; i++) {
      final (config, backend) = candidates[i];
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiException('Cancelled.', 'cancelled');
      }
      if (backend is! StreamingBackend) continue; // e.g. Anthropic → non-stream
      var streamed = false;
      try {
        await for (final piece
            in backend.chatStream(messages, timeoutSeconds: timeoutSeconds, cancelToken: cancelToken)) {
          streamed = true;
          yield piece;
        }
        return;
      } on ApiException catch (e) {
        if (e.kind == 'cancelled') rethrow;
        if (streamed) rethrow; // partial reply already shown — be honest
        failures.add('${config.displayName}: ${e.message}');
      }
    }
    // Nothing streamed → one last non-streaming attempt across the chain.
    try {
      yield await chatWithFallback(messages,
          timeoutSeconds: timeoutSeconds, cancelToken: cancelToken);
    } on ApiException catch (e) {
      if (failures.isNotEmpty && e.kind != 'cancelled') {
        throw ApiException(
          '${e.message}\nStreaming attempts: ${failures.join('; ')}',
          e.kind,
        );
      }
      rethrow;
    }
  }
}
