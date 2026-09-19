import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'stores.dart';

/// Cooperative cancellation for in-flight HTTP. Closing the underlying
/// socket aborts the pending request immediately, so Stop responds instantly
/// instead of waiting out the timeout.
class CancelToken {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  Future<void> get future => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Minimal interface the agent loop depends on — lets tests drive the loop
/// with a fake backend (no network).
abstract class ChatBackend {
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
      List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools,
      int? timeoutSeconds,
      CancelToken? cancelToken,
      int retries});
}

/// OpenAI-compatible client: /chat/completions (+SSE streaming) and /models.
/// The API key is fetched from SecureStore per call and ONLY placed in the
/// Authorization header — never in bodies, logs, or error strings.
class ApiClient implements ChatBackend {
  static const _maxAttempts = 3;
  static const _retryCap = Duration(seconds: 30);
  final SettingsStore _store;

  ApiClient(this._store);

  Future<({ApiSettings s, String key})> _cfg() async {
    final r = await _store.loadWithKey();
    final key = r.apiKey;
    if (key == null || key.trim().isEmpty) {
      throw const ApiException('No API key configured. Open Settings → API key.', 'no_api_key');
    }
    final s = r.settings;
    if (!s.hasBaseUrl) {
      throw const ApiException('No Base URL configured.', 'config');
    }
    return (s: s, key: key.trim());
  }

  Uri _uri(ApiSettings s, String path) {
    var base = s.baseUrl.trim();
    if (!base.startsWith('http')) {
      throw const ApiException('Base URL must start with http(s):// — e.g. https://api.xkiro.com/v1', 'config');
    }
    return Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Map<String, String> _headers(String key) => {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _body(ApiSettings s, List<ChatMessage> messages,
      {bool stream = false, List<Map<String, dynamic>>? tools}) {
    // Messages with an attached image use the OpenAI vision content-array
    // format (text part + image_url part with a base64 data URL); plain
    // messages keep the simple string form.
    Object messageContent(ChatMessage m) {
      final url = m.imageDataUrl;
      if (url == null || url.isEmpty) return m.content;
      return [
        {'type': 'text', 'text': m.content.isEmpty ? 'Describe this image.' : m.content},
        {'type': 'image_url', 'image_url': {'url': url}},
      ];
    }

    return {
      'model': s.modelId,
      'messages': [
        for (final m in messages)
          {
            'role': m.role,
            'content': messageContent(m),
            // Agent loop: echo assistant tool_calls and tool results in the
            // OpenAI format so providers that support tool calling can
            // continue the conversation correctly.
            if (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false))
              'tool_calls': m.toolCalls,
            if (m.role == 'tool' && m.toolCallId != null) 'tool_call_id': m.toolCallId,
          },
      ],
      'temperature': 0.2,
      'stream': stream,
      if (tools != null) ...{'tools': tools, 'tool_choice': 'auto'},
    };
  }

  /// Non-streaming completion with retry/backoff on 429/5xx/network.
  Future<String> chat(List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools, int? timeoutSeconds}) async {
    final m = await chatWithTools(messages, tools: tools, timeoutSeconds: timeoutSeconds);
    return m.content;
  }

  /// Registers [client] so that cancelling [token] closes it, aborting the
  /// in-flight request. Returns the client for the caller's try/finally.
  http.Client _cancellableClient(CancelToken? token) {
    final client = http.Client();
    if (token != null) {
      // close() aborts the socket; a later close() in finally is a no-op.
      unawaited(token.future.then((_) => client.close()));
    }
    return client;
  }

  /// Non-streaming completion that also returns OpenAI tool_calls so the
  /// agent loop can execute tools. Falls back gracefully when the provider
  /// omits tool support (content-only response).
  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
      List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools,
      int? timeoutSeconds,
      CancelToken? cancelToken,
      int retries = _maxAttempts}) async {
    final (s: s, key: key) = await _cfg();
    final timeout = Duration(seconds: timeoutSeconds ?? s.requestTimeout);
    final url = _uri(s, '/chat/completions');
    final attempts = retries.clamp(1, _maxAttempts);

    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiException('Cancelled.', 'cancelled');
      }
      final client = _cancellableClient(cancelToken);
      try {
        final resp = await client
            .post(url, headers: _headers(key), body: jsonEncode(_body(s, messages, tools: tools)))
            .timeout(timeout);
        if (resp.statusCode == 200) {
          final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final choices = body['choices'] as List?;
          if (choices == null || choices.isEmpty) {
            throw const ApiException('Provider returned an empty response.', 'provider');
          }
          final msg = (choices.first as Map)['message'] as Map;
          final content = (msg['content'] as String?) ?? '';
          final calls = <ToolCall>[];
          final raw = msg['tool_calls'] as List?;
          if (raw != null) {
            for (final c in raw) {
              if (c is! Map) continue;
              final fn = c['function'] as Map?;
              if (fn == null) continue;
              final argsRaw = fn['arguments'];
              Map<String, dynamic> args = {};
              if (argsRaw is String) {
                try {
                  final decoded = jsonDecode(argsRaw);
                  if (decoded is Map) args = Map<String, dynamic>.from(decoded);
                } on FormatException {
                  args = {'_raw': argsRaw}; // let the loop report the bad JSON
                }
              } else if (argsRaw is Map) {
                args = Map<String, dynamic>.from(argsRaw);
              }
              calls.add(ToolCall(
                id: (c['id'] as String?) ?? 'call_${calls.length}',
                name: (fn['name'] as String?) ?? '',
                arguments: args,
              ));
            }
          }
          return (content: content, toolCalls: calls);
        }
        throw _statusError(resp, s.modelId);
      } on TimeoutException {
        lastErr = ApiException('Request timed out after ${timeout.inSeconds}s.', 'timeout');
      } on SocketException catch (e) {
        lastErr = ApiException('Network error: ${e.message}', 'network');
      } on http.ClientException catch (e) {
        // A cancel closes the client mid-request and surfaces here — report
        // it as cancelled, not as a network failure.
        if (cancelToken?.isCancelled ?? false) {
          throw const ApiException('Cancelled.', 'cancelled');
        }
        lastErr = ApiException('Network error: ${e.message}', 'network');
      } on ApiException {
        rethrow; // status errors: already classified
      } finally {
        client.close();
      }
      if (attempt < attempts) {
        await Future.delayed(Duration(seconds: (1 << attempt).clamp(2, _retryCap.inSeconds)));
      }
    }
    throw lastErr is ApiException
        ? lastErr
        : const ApiException('Request failed.', 'provider');
  }

  /// Streaming SSE completion — yields text deltas as they arrive.
  Stream<String> chatStream(List<ChatMessage> messages) async* {
    final (s: s, key: key) = await _cfg();
    final timeout = Duration(seconds: s.requestTimeout);
    final req = http.Request('POST', _uri(s, '/chat/completions'))
      ..headers.addAll(_headers(key))
      ..body = jsonEncode(_body(s, messages, stream: true));
    try {
      final resp = await req.send().timeout(timeout);
      if (resp.statusCode != 200) {
        final text = await resp.stream.bytesToString();
        throw _statusError(_FakeResponse(resp.statusCode, text), s.modelId);
      }
      await for (final line in resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') return;
        try {
          final chunk = jsonDecode(data) as Map<String, dynamic>;
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'] as Map?;
          final piece = delta?['content'] as String?;
          if (piece != null && piece.isNotEmpty) yield piece;
        } catch (_) {
          continue; // keep-alive / partial line
        }
      }
    } on TimeoutException {
      throw ApiException('Stream timed out after ${s.requestTimeout}s.', 'timeout');
    } on SocketException catch (e) {
      throw ApiException('Network error: ${e.message}', 'network');
    }
  }

  ApiException _statusError(http.Response resp, String modelId) {
    final body = resp.body.toLowerCase();
    switch (resp.statusCode) {
      case 401:
        return const ApiException(
            'Invalid API key (HTTP 401). The provider rejected it — check Settings → API key.',
            'invalid_api_key');
      case 404:
        if (body.contains('model') &&
            (body.contains('not found') || body.contains('does not exist'))) {
          return ApiException('Model "$modelId" was not found on this provider (HTTP 404). Check the Model ID.', 'unsupported_model');
        }
        return const ApiException('Endpoint not found (HTTP 404). Verify the Base URL.', 'provider');
      case 429:
        if (body.contains('insufficient_quota') ||
            body.contains('quota exceeded') ||
            body.contains('billing')) {
          return const ApiException('Insufficient quota: the API key has no remaining credit for this model.', 'insufficient_quota');
        }
        return const ApiException('Rate limited (HTTP 429). Wait a moment and retry.', 'rate_limited');
      case >= 500:
        return ApiException('Provider unavailable (HTTP ${resp.statusCode}). Try again shortly.', 'provider');
      default:
        return ApiException('Provider error HTTP ${resp.statusCode}.', 'provider');
    }
  }

  /// GET /models for the model selector.
  Future<List<String>> listModels() async {
    final (s: s, key: key) = await _cfg();
    final resp = await http
        .get(_uri(s, '/models'), headers: _headers(key))
        .timeout(Duration(seconds: 30));
    if (resp.statusCode != 200) throw _statusError(resp, s.modelId);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final data = (body['data'] as List?) ?? const [];
    return [for (final m in data) if (m is Map && m['id'] != null) m['id'] as String];
  }

  /// Test connection: real minimal request. Returns (ok, detail).
  Future<(bool, String)> testConnection() async {
    try {
      final (s: s, key: key) = await _cfg();
      final resp = await http
          .post(_uri(s, '/chat/completions'),
              headers: _headers(key),
              body: jsonEncode({
                'model': s.modelId,
                'messages': [
                  {'role': 'user', 'content': 'Reply with the single word: ok'}
                ],
              }))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return (true, 'Connected. model=${body['model'] ?? s.modelId}');
      }
      final e = _statusError(resp, s.modelId);
      return (false, e.message);
    } on ApiException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, 'Connection failed: $e');
    }
  }
}

class _FakeResponse extends http.Response {
  _FakeResponse(int statusCode, String body) : super(body, statusCode);
}

/// One tool call requested by the model.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({required this.id, required this.name, required this.arguments});
}

class ApiException implements Exception {
  final String message;
  final String kind;
  const ApiException(this.message, this.kind);
  @override
  String toString() => message;
}
