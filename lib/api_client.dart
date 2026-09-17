import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'stores.dart';

/// OpenAI-compatible client: /chat/completions (+SSE streaming) and /models.
/// The API key is fetched from SecureStore per call and ONLY placed in the
/// Authorization header — never in bodies, logs, or error strings.
class ApiClient {
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
    return {
      'model': s.modelId,
      'messages': [for (final m in messages) {'role': m.role, 'content': m.content}],
      'temperature': 0.2,
      'stream': stream,
      if (tools != null) ...{'tools': tools, 'tool_choice': 'auto'},
    };
  }

  /// Non-streaming completion with retry/backoff on 429/5xx/network.
  Future<String> chat(List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools, int? timeoutSeconds}) async {
    final (s: s, key: key) = await _cfg();
    final timeout = Duration(seconds: timeoutSeconds ?? s.requestTimeout);
    final url = _uri(s, '/chat/completions');

    Object? lastErr;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final resp = await http
            .post(url, headers: _headers(key), body: jsonEncode(_body(s, messages, tools: tools)))
            .timeout(timeout);
        if (resp.statusCode == 200) {
          final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final choices = body['choices'] as List?;
          if (choices == null || choices.isEmpty) {
            throw const ApiException('Provider returned an empty response.', 'provider');
          }
          final msg = (choices.first as Map)['message'] as Map;
          return (msg['content'] as String?) ?? '';
        }
        throw _statusError(resp, s.modelId);
      } on TimeoutException {
        lastErr = ApiException('Request timed out after ${timeout.inSeconds}s.', 'timeout');
      } on SocketException catch (e) {
        lastErr = ApiException('Network error: ${e.message}', 'network');
      } on http.ClientException catch (e) {
        lastErr = ApiException('Network error: ${e.message}', 'network');
      } on ApiException {
        rethrow; // status errors: already classified
      }
      if (attempt < _maxAttempts) {
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

class ApiException implements Exception {
  final String message;
  final String kind;
  const ApiException(this.message, this.kind);
  @override
  String toString() => message;
}
