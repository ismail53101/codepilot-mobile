import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api_client.dart' show CancelToken, ChatBackend, ApiException, ToolCall;
import '../models.dart';
import 'provider_config.dart';

/// One IMPLEMENTED provider family. All backends speak the app's common
/// [ChatBackend] interface (OpenAI-style messages + tool calls), so the
/// agent loop and the UI never know which provider actually served a
/// request. Provider-specific protocol differences live ONLY here.
abstract class AiProviderBackend implements ChatBackend {
  final ProviderConfig config;
  final String key;

  /// Injectable HTTP layer for tests; production uses real sockets.
  final http.Client Function() clientFactory;

  AiProviderBackend(this.config, this.key,
      {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  /// Real minimal request used by Test Connection in the Key Manager.
  Future<(bool, String)> testConnection();

  /// Real GET against the provider's model list (empty list = unsupported).
  Future<List<String>> listModels();

  static AiProviderBackend forConfig(ProviderConfig config, String key) =>
      switch (config.type) {
        AiProviderType.openRouter ||
        AiProviderType.openai ||
        AiProviderType.custom => OpenAiCompatibleBackend(config, key),
        AiProviderType.gemini => GeminiBackend(config, key),
        AiProviderType.anthropic => AnthropicBackend(config, key),
      };
}

// ----------------------------------------------------------------------
// Shared HTTP plumbing: timeout + cooperative cancel (close = abort).
// ----------------------------------------------------------------------

Future<http.Response> _post(
  Uri url,
  Map<String, String> headers,
  Object body, {
  required int timeoutSeconds,
  CancelToken? cancelToken,
  http.Client Function()? clientFactory,
}) async {
  final client = clientFactory?.call() ?? http.Client();
  if (cancelToken != null) {
    unawaited(cancelToken.future.then((_) => client.close()));
  }
  try {
    if (cancelToken?.isCancelled ?? false) {
      throw const ApiException('Cancelled.', 'cancelled');
    }
    return await client
        .post(url, headers: headers, body: jsonEncode(body))
        .timeout(Duration(seconds: timeoutSeconds));
  } on TimeoutException {
    throw ApiException('Request timed out after ${timeoutSeconds}s.', 'timeout');
  } on SocketException catch (e) {
    throw ApiException('Network error: ${e.message}', 'network');
  } on http.ClientException catch (e) {
    if (cancelToken?.isCancelled ?? false) {
      throw const ApiException('Cancelled.', 'cancelled');
    }
    throw ApiException('Network error: ${e.message}', 'network');
  } finally {
    client.close();
  }
}

Future<http.Response> _get(
  Uri url,
  Map<String, String> headers, {
  int timeoutSeconds = 30,
}) async {
  final client = http.Client();
  try {
    return await client
        .get(url, headers: headers)
        .timeout(Duration(seconds: timeoutSeconds));
  } on TimeoutException {
    throw const ApiException('Model list request timed out.', 'timeout');
  } on SocketException catch (e) {
    throw ApiException('Network error: ${e.message}', 'network');
  } finally {
    client.close();
  }
}

/// Parse a base64 data-URL image into (mimeType, base64).
(String, String)? _parseDataUrl(String url) {
  final m = RegExp(r'^data:([^;]+);base64,(.+)$', dotAll: true).firstMatch(url);
  if (m == null) return null;
  return (m.group(1)!, m.group(2)!);
}

/// Backends that support incremental SSE streaming for plain chat.
abstract class StreamingBackend {
  Stream<String> chatStream(
    List<ChatMessage> messages, {
    int? timeoutSeconds,
    CancelToken? cancelToken,
  });
}

/// Shared SSE line reader: yields `data:` payload strings until [DONE].
Stream<String> _sseData(http.StreamedResponse resp) async* {
  await for (final line in resp.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data == '[DONE]') return;
    yield data;
  }
}

Future<http.StreamedResponse> _postStream(
  Uri url,
  Map<String, String> headers,
  Object body, {
  required int timeoutSeconds,
  CancelToken? cancelToken,
  required ApiException Function(http.Response resp) onError,
  http.Client Function()? clientFactory,
}) async {
  final client = clientFactory?.call() ?? http.Client();
  if (cancelToken != null) {
    unawaited(cancelToken.future.then((_) => client.close()));
  }
  try {
    final req = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);
    // Send through [client] (NOT req.send(), which bypasses it) so the
    // injected factory applies and cooperative cancel (close) truly aborts
    // an in-flight stream.
    final resp = await client.send(req).timeout(Duration(seconds: timeoutSeconds));
    if (resp.statusCode != 200) {
      final text = await resp.stream.bytesToString();
      throw onError(http.Response(text, resp.statusCode));
    }
    return resp;
  } on TimeoutException {
    client.close();
    throw ApiException('Stream timed out after ${timeoutSeconds}s.', 'timeout');
  } on SocketException catch (e) {
    client.close();
    throw ApiException('Network error: ${e.message}', 'network');
  } on http.ClientException catch (e) {
    client.close();
    if (cancelToken?.isCancelled ?? false) {
      throw const ApiException('Cancelled.', 'cancelled');
    }
    throw ApiException('Network error: ${e.message}', 'network');
  } catch (e) {
    client.close();
    rethrow;
  }
}

// ----------------------------------------------------------------------
// OpenRouter / OpenAI / Custom — OpenAI-compatible /chat/completions.
// ----------------------------------------------------------------------

class OpenAiCompatibleBackend extends AiProviderBackend
    implements StreamingBackend {
  OpenAiCompatibleBackend(super.config, super.key, {super.clientFactory});

  late final ApiSettings _settings = ApiSettings(
    providerName: config.displayName,
    baseUrl: config.effectiveBaseUrl,
    modelId: config.model,
    requestTimeout: 3600,
    streaming: true,
  );

  Uri _uri(String path) => Uri.parse(
      '${_settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
        // OpenRouter attribution (optional, ignored by other providers).
        'HTTP-Referer': 'https://codepilot.app',
        'X-Title': 'CodeFexa Mobile',
      };

  Map<String, dynamic> _body(List<ChatMessage> messages,
      {bool stream = false, List<Map<String, dynamic>>? tools}) {
    Object content(ChatMessage m) {
      final url = m.imageDataUrl;
      if (url == null || url.isEmpty) return m.content;
      return [
        {'type': 'text', 'text': m.content.isEmpty ? 'Describe this image.' : m.content},
        {'type': 'image_url', 'image_url': {'url': url}},
      ];
    }

    return {
      'model': config.model,
      'messages': [
        for (final m in messages)
          {
            'role': m.role,
            'content': content(m),
            if (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false))
              'tool_calls': m.toolCalls,
            if (m.role == 'tool' && m.toolCallId != null)
              'tool_call_id': m.toolCallId,
          },
      ],
      // Capability-aware sampling: reasoning-first models (o-series,
      // gpt-5*, Claude Opus 4.5+/5.x) 400 on `temperature` — omit it there.
      if (modelCapabilitiesFor(config.model).supportsSamplingControls)
        'temperature': 0.2,
      'stream': stream,
      if (tools != null) ...{'tools': tools, 'tool_choice': 'auto'},
    };
  }

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 1,
  }) async {
    final resp = await _post(
      _uri('/chat/completions'),
      _headers,
      _body(messages, tools: tools),
      timeoutSeconds: timeoutSeconds ?? 3600,
      cancelToken: cancelToken,
      clientFactory: clientFactory,
    );
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const ApiException('Provider returned an empty response.', 'provider');
    }
    final msg = (choices.first as Map)['message'] as Map? ?? {};
    final calls = _parseOpenAiToolCalls(msg['tool_calls'] as List?);
    return (content: (msg['content'] as String?) ?? '', toolCalls: calls);
  }

  /// Streaming SSE completion — yields text deltas as they arrive.
  @override
  Stream<String> chatStream(
    List<ChatMessage> messages, {
    int? timeoutSeconds,
    CancelToken? cancelToken,
  }) async* {
    final resp = await _postStream(
      _uri('/chat/completions'),
      _headers,
      _body(messages, stream: true),
      timeoutSeconds: timeoutSeconds ?? 3600,
      cancelToken: cancelToken,
      onError: (r) => _statusError(r, config),
      clientFactory: clientFactory,
    );
    await for (final data in _sseData(resp)) {
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
  }

  @override
  Future<(bool, String)> testConnection() async {
    try {
      final resp = await _post(
        _uri('/chat/completions'),
        _headers,
        {
          'model': config.model,
          'messages': [
            {'role': 'user', 'content': 'Hi'}
          ],
        },
        timeoutSeconds: 30,
        clientFactory: clientFactory,
      );
      if (resp.statusCode == 200) return (true, 'Connected to ${config.type.label}.');
      final e = _statusError(resp, config);
      return (false, e.message);
    } on ApiException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, 'Connection failed: $e');
    }
  }

  @override
  Future<List<String>> listModels() async {
    final resp = await _get(_uri('/models'), _headers);
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final data = (body['data'] as List?) ?? const [];
    return [for (final m in data) if (m is Map && m['id'] != null) m['id'] as String];
  }
}

/// Shared OpenAI tool_calls array → [ToolCall] list.
List<ToolCall> _parseOpenAiToolCalls(List? raw) {
  final calls = <ToolCall>[];
  if (raw == null) return calls;
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
        args = {'_raw': argsRaw};
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
  return calls;
}

// ----------------------------------------------------------------------
// Google Gemini — generateContent with function calling.
// ----------------------------------------------------------------------

class GeminiBackend extends AiProviderBackend
    implements StreamingBackend {
  GeminiBackend(super.config, super.key, {super.clientFactory});

  Uri _uri(String model, String method) => Uri.parse(
      '${config.effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '')}'
      '/v1beta/models/${model.startsWith('models/') ? model : 'models/$model'}:$method');

  Map<String, String> get _headers =>
      {'x-goog-api-key': key, 'Content-Type': 'application/json'};

  /// OpenAI-style messages → Gemini contents. Tool results need the tool
  /// NAME (Gemini has no tool_call ids), so resolve ids from the echoed
  /// assistant tool_calls turns. Gemini enforces user/model alternation, so
  /// consecutive tool results are merged into ONE user turn.
  Map<String, dynamic> _convert(List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools}) {
    final contents = <Map<String, dynamic>>[];
    final system = StringBuffer();
    final idToName = <String, String>{};

    // Pending function responses (merged into a single user turn).
    final pendingFn = <Map<String, dynamic>>[];
    void flushFn() {
      if (pendingFn.isEmpty) return;
      contents.add({'role': 'user', 'parts': List.of(pendingFn)});
      pendingFn.clear();
    }

    for (final m in messages) {
      switch (m.role) {
        case 'system':
          if (system.isNotEmpty) system.write('\n');
          system.write(m.content);
        case 'user':
          flushFn();
          contents.add({
            'role': 'user',
            'parts': [
              {'text': m.content},
              if (m.imageDataUrl case final url? when url.isNotEmpty)
                if (_parseDataUrl(url) case (final mime, final data))
                  {
                    'inlineData': {'mimeType': mime, 'data': data},
                  },
            ],
          });
        case 'assistant':
          final list = <Map<String, dynamic>>[];
          if (m.content.isNotEmpty) list.add({'text': m.content});
          for (final c in m.toolCalls ?? const []) {
            final fn = c['function'] as Map? ?? {};
            final name = fn['name'] as String? ?? '';
            final id = c['id'] as String? ?? '';
            if (id.isNotEmpty) idToName[id] = name;
            Map<String, dynamic> args = {};
            final raw = fn['arguments'];
            if (raw is String) {
              try {
                final d = jsonDecode(raw);
                if (d is Map) args = Map<String, dynamic>.from(d);
              } on FormatException {
                args = {};
              }
            } else if (raw is Map) {
              args = Map<String, dynamic>.from(raw);
            }
            list.add({'functionCall': {'name': name, 'args': args}});
          }
          if (list.isNotEmpty) {
            flushFn();
            contents.add({'role': 'model', 'parts': list});
          }
        case 'tool':
          final name = idToName[m.toolCallId] ?? 'tool';
          pendingFn.add({
            'functionResponse': {
              'name': name,
              'response': {'result': m.content},
            },
          });
      }
    }
    flushFn();

    return {
      if (system.isNotEmpty)
        'systemInstruction': {'parts': [{'text': system.toString()}]},
      'contents': contents,
      'generationConfig':
          // Gemini reasoning variants also reject sampling controls.
          modelCapabilitiesFor(config.model).supportsSamplingControls
              ? {'temperature': 0.2}
              : <String, dynamic>{},
      if (tools != null && tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in tools)
                {
                  'name': t['function']['name'],
                  'description': t['function']['description'],
                  'parameters': t['function']['parameters'],
                },
            ],
          },
        ],
    };
  }

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 1,
  }) async {
    final resp = await _post(
      _uri(config.model, 'generateContent'),
      _headers,
      _convert(messages, tools: tools),
      timeoutSeconds: timeoutSeconds ?? 3600,
      cancelToken: cancelToken,
      clientFactory: clientFactory,
    );
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

    final candidates = body['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      final feedback = body['promptFeedback'] as Map?;
      final reason = feedback?['blockReason'];
      throw ApiException(
        reason == null
            ? 'Gemini returned no response.'
            : 'Gemini blocked the request: $reason.',
        'provider',
      );
    }
    final content = ((candidates.first as Map)['content'] as Map?) ??
        <String, dynamic>{};
    final parts = (content['parts'] as List?) ?? const [];
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final p in parts) {
      if (p is! Map) continue;
      final t = p['text'];
      if (t is String && t.isNotEmpty) text.write(t);
      final fc = p['functionCall'];
      if (fc is Map) {
        calls.add(ToolCall(
          id: 'gemini_${calls.length}_${DateTime.now().microsecondsSinceEpoch}',
          name: (fc['name'] as String?) ?? '',
          arguments: fc['args'] is Map
              ? Map<String, dynamic>.from(fc['args'] as Map)
              : <String, dynamic>{},
        ));
      }
    }
    return (content: text.toString(), toolCalls: calls);
  }

  /// Streaming SSE completion (streamGenerateContent?alt=sse).
  @override
  Stream<String> chatStream(
    List<ChatMessage> messages, {
    int? timeoutSeconds,
    CancelToken? cancelToken,
  }) async* {
    final resp = await _postStream(
      _uri(config.model, 'streamGenerateContent?alt=sse'),
      _headers,
      _convert(messages),
      timeoutSeconds: timeoutSeconds ?? 3600,
      cancelToken: cancelToken,
      onError: (r) => _statusError(r, config),
      clientFactory: clientFactory,
    );
    await for (final data in _sseData(resp)) {
      try {
        final chunk = jsonDecode(data) as Map<String, dynamic>;
        final candidates = chunk['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) continue;
        final parts =
            (((candidates.first as Map)['content'] as Map?)?['parts'] as List?) ??
                const [];
        for (final p in parts) {
          if (p is Map) {
            final t = p['text'];
            if (t is String && t.isNotEmpty) yield t;
          }
        }
      } catch (_) {
        continue;
      }
    }
  }

  @override
  Future<(bool, String)> testConnection() async {
    try {
      final resp = await _post(
        _uri(config.model, 'generateContent'),
        _headers,
        {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Hi'}
              ],
            },
          ],
        },
        timeoutSeconds: 30,
        clientFactory: clientFactory,
      );
      if (resp.statusCode == 200) return (true, 'Connected to Google Gemini.');
      final e = _statusError(resp, config);
      return (false, e.message);
    } on ApiException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, 'Connection failed: $e');
    }
  }

  @override
  Future<List<String>> listModels() async {
    final url = Uri.parse(
        '${config.effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1beta/models');
    final resp = await _get(url, _headers);
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final models = (body['models'] as List?) ?? const [];
    return [
      for (final m in models)
        if (m is Map)
          if ((m['name'] as String?) case final name?)
            if ((m['supportedGenerationMethods'] as List?)
                    ?.contains('generateContent') !=
                false)
              name.replaceFirst(RegExp('^models/'), ''),
    ];
  }
}

// ----------------------------------------------------------------------
// Anthropic — /v1/messages with tool_use blocks.
// ----------------------------------------------------------------------

class AnthropicBackend extends AiProviderBackend {
  AnthropicBackend(super.config, super.key, {super.clientFactory});

  Uri get _uri => Uri.parse(
      '${config.effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages');

  Map<String, String> get _headers => {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _convert(List<ChatMessage> messages,
      {List<Map<String, dynamic>>? tools}) {
    final system = StringBuffer();
    final out = <Map<String, dynamic>>[];

    // Pending tool results — Anthropic requires alternation too, so
    // consecutive results merge into ONE user message.
    final pendingResults = <Map<String, dynamic>>[];
    void flushResults() {
      if (pendingResults.isEmpty) return;
      out.add({'role': 'user', 'content': List.of(pendingResults)});
      pendingResults.clear();
    }

    for (final m in messages) {
      switch (m.role) {
        case 'system':
          if (system.isNotEmpty) system.write('\n');
          system.write(m.content);
        case 'user':
          flushResults();
          out.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': m.content},
              if (m.imageDataUrl case final url? when url.isNotEmpty)
                if (_parseDataUrl(url) case (final mime, final data))
                  {
                    'type': 'image',
                    'source': {'type': 'base64', 'media_type': mime, 'data': data},
                  },
            ],
          });
        case 'assistant':
          final blocks = <Map<String, dynamic>>[
            if (m.content.isNotEmpty)
              {'type': 'text', 'text': m.content},
            for (final c in m.toolCalls ?? const [])
              if (c['function'] case final Map fn)
                {
                  'type': 'tool_use',
                  'id': (c['id'] as String?) ?? 'toolu_unknown',
                  'name': (fn['name'] as String?) ?? '',
                  'input': () {
                    final raw = fn['arguments'];
                    if (raw is String) {
                      try {
                        final d = jsonDecode(raw);
                        return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
                      } on FormatException {
                        return <String, dynamic>{};
                      }
                    }
                    return raw is Map
                        ? Map<String, dynamic>.from(raw)
                        : <String, dynamic>{};
                  }(),
                },
          ];
          if (blocks.isNotEmpty) {
            flushResults();
            out.add({'role': 'assistant', 'content': blocks});
          }
        case 'tool':
          // tool_result blocks ride in user messages; merged when consecutive.
          pendingResults.add({
            'type': 'tool_result',
            'tool_use_id': m.toolCallId ?? '',
            'content': m.content,
          });
      }
    }
    flushResults();

    // Anthropic requires the conversation to start with a user turn.
    while (out.isNotEmpty && (out.first['role'] as String) != 'user') {
      out.removeAt(0);
    }

    return {
      'model': config.model,
      'max_tokens': modelCapabilitiesFor(config.model).maxTokens,
      // Capability-aware: Claude reasoning/extended-thinking families
      // (Opus 4.5+, Claude 5.x) reject `temperature` with HTTP 400.
      if (modelCapabilitiesFor(config.model).supportsSamplingControls)
        'temperature': 0.2,
      if (system.isNotEmpty) 'system': system.toString(),
      'messages': out,
      if (tools != null && tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'name': (t['function'] as Map)['name'],
              'description': (t['function'] as Map)['description'],
              'input_schema': (t['function'] as Map)['parameters'],
            },
        ],
    };
  }

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 1,
  }) async {
    final resp = await _post(
      _uri,
      _headers,
      _convert(messages, tools: tools),
      timeoutSeconds: timeoutSeconds ?? 3600,
      cancelToken: cancelToken,
      clientFactory: clientFactory,
    );
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final content = (body['content'] as List?) ?? const [];
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final b in content) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String) text.write(t);
        case 'tool_use':
          calls.add(ToolCall(
            id: (b['id'] as String?) ?? 'toolu_${calls.length}',
            name: (b['name'] as String?) ?? '',
            arguments: b['input'] is Map
                ? Map<String, dynamic>.from(b['input'] as Map)
                : <String, dynamic>{},
          ));
      }
    }
    return (content: text.toString(), toolCalls: calls);
  }

  @override
  Future<(bool, String)> testConnection() async {
    try {
      final resp = await _post(
        _uri,
        _headers,
        {
          'model': config.model,
          'max_tokens': 16,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Hi'}
              ],
            },
          ],
        },
        timeoutSeconds: 30,
        clientFactory: clientFactory,
      );
      if (resp.statusCode == 200) return (true, 'Connected to Anthropic.');
      final e = _statusError(resp, config);
      return (false, e.message);
    } on ApiException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, 'Connection failed: $e');
    }
  }

  @override
  Future<List<String>> listModels() async {
    final url = Uri.parse(
        '${config.effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/models');
    final resp = await _get(url, _headers);
    if (resp.statusCode != 200) throw _statusError(resp, config);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final data = (body['data'] as List?) ?? const [];
    return [for (final m in data) if (m is Map && m['id'] != null) m['id'] as String];
  }
}

// ----------------------------------------------------------------------
// Shared status-error classification (same kinds as ApiClient).
// ----------------------------------------------------------------------

ApiException _statusError(http.Response resp, ProviderConfig config) {
  // Surface the provider's structured error (status + type + code + param
  // + message) before the coarse keyword classification.
  final detail = ProviderErrorDetail.fromBody(resp.statusCode, resp.body);
  final detailSuffix = detail == null ? '' : ' — ${detail.describe()}';
  final label = config.type.label;
  final body = resp.body.toLowerCase();
  switch (resp.statusCode) {
    case 400:
      final param = detail?.param ?? '';
      final msg = detail?.message ?? '';
      if (param.contains('temperature') ||
          (msg.contains('temperature') && msg.contains('support'))) {
        return ApiException(
            'Provider rejected "temperature" for model "${config.model}" '
            '(HTTP 400). This model does not accept sampling controls; '
            'the app now omits them for it — update and retry.',
            'bad_request');
      }
      if (param.isNotEmpty || msg.isNotEmpty) {
        return ApiException(
            '$label rejected the request (HTTP 400): '
            '${msg.isNotEmpty ? msg : 'invalid ${param.isEmpty ? 'request' : param}'}'
            '${param.isNotEmpty && msg.isNotEmpty ? ' [param: $param]' : ''}'
            '${detail?.type != null ? ' (type: ${detail!.type})' : ''}',
            'bad_request');
      }
      return ApiException(
          '$label error HTTP 400.$detailSuffix', 'bad_request');
    case 401:
    case 403:
      return ApiException(
          'Invalid or unauthorized API key for $label (HTTP ${resp.statusCode}).'
          '$detailSuffix',
          'invalid_api_key');
    case 404:
      if (body.contains('model') &&
          (body.contains('not found') ||
              body.contains('does not exist') ||
              body.contains('not_supported'))) {
        return ApiException(
            'Model "${config.model}" was not found on $label (HTTP 404).$detailSuffix',
            'unsupported_model');
      }
      return ApiException('Endpoint not found on $label (HTTP 404). Check the Base URL.$detailSuffix', 'provider');
    case 429:
      if (body.contains('quota') ||
          body.contains('billing') ||
          body.contains('insufficient') ||
          body.contains('credit')) {
        return ApiException(
            'Insufficient quota on $label: this key has no remaining credit.$detailSuffix',
            'insufficient_quota');
      }
      return ApiException('Rate limited by $label (HTTP 429).$detailSuffix', 'rate_limited');
    case >= 500:
      return ApiException(
          '$label is temporarily unavailable (HTTP ${resp.statusCode}).$detailSuffix', 'provider');
    default:
      // Provider-specific 400s (e.g. Gemini API_KEY_INVALID, Anthropic
      // authentication_error) surface here — classify by body markers.
      if (body.contains('api_key_invalid') ||
          body.contains('invalid api key') ||
          body.contains('authentication_error') ||
          body.contains('invalid x-api-key') ||
          body.contains('unregistered') ||
          body.contains('api key not valid')) {
        return ApiException('Invalid API key for $label.', 'invalid_api_key');
      }      if (body.contains('resource_exhausted') || body.contains('quota')) {
        return ApiException('Quota exceeded on $label.$detailSuffix', 'insufficient_quota');
      }
      return ApiException('$label error HTTP ${resp.statusCode}.$detailSuffix', 'provider');
    }
  }
