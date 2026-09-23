import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:codepilot_mobile/api_client.dart';
import 'package:codepilot_mobile/models.dart';
import 'package:codepilot_mobile/providers/provider_backends.dart';
import 'package:codepilot_mobile/providers/provider_config.dart';
import 'package:codepilot_mobile/stores.dart';

import 'fake_http_client.dart';

/// In-memory SecureStore so tests never touch the secure-storage platform
/// channel (same pattern as path_and_git_regression_test.dart).
class _MemorySecureStore implements SecureStore {
  final _values = <String, String?>{};

  @override
  Future<String?> readApiKey() async => _values['key'];
  @override
  Future<void> writeApiKey(String key) async => _values['key'] = key;
  @override
  Future<void> deleteApiKey() async => _values['key'] = null;
  @override
  Future<String?> readGitHubToken() async => _values['gh'];
  @override
  Future<void> writeGitHubToken(String token) async => _values['gh'] = token;
  @override
  Future<void> deleteGitHubToken() async => _values['gh'] = null;
}

/// Settings store pointed at the Experiential Labs gateway with the given
/// model. The key value itself is arbitrary in tests (never logged).
Future<SettingsStore> _storeFor(String model) async {
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(secure: _MemorySecureStore());
  await store.save(ApiSettings(
    providerName: 'Experiential Labs',
    baseUrl: 'https://api.experientiallabs.ai/v1',
    modelId: model,
  ));
  await store.writeApiKey('xpl_test_key');
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('modelCapabilitiesFor', () {
    test('claude-opus-5.5 rejects sampling controls', () {
      final c = modelCapabilitiesFor('claude-opus-5.5');
      expect(c.supportsSamplingControls, isFalse);
    });

    test('older Claude models keep sampling controls', () {
      expect(modelCapabilitiesFor('claude-3-5-sonnet-latest').supportsSamplingControls,
          isTrue);
      expect(modelCapabilitiesFor('claude-sonnet-4-20250514').supportsSamplingControls,
          isTrue);
    });

    test('gpt-5.6-luna and o-series reject sampling controls', () {
      expect(modelCapabilitiesFor('gpt-5.6-luna').supportsSamplingControls, isFalse);
      expect(modelCapabilitiesFor('o4-mini').supportsSamplingControls, isFalse);
      expect(modelCapabilitiesFor('o3').supportsSamplingControls, isFalse);
      // Prefixed variants via gateways (openrouter/vendor ids).
      expect(modelCapabilitiesFor('openai/gpt-5.2').supportsSamplingControls, isFalse);
    });

    test('unknown / qwen / gemini models keep sampling controls', () {
      expect(modelCapabilitiesFor('qwen/qwen3.7-flash:free').supportsSamplingControls,
          isTrue);
      expect(modelCapabilitiesFor('gemini-1.5-flash').supportsSamplingControls,
          isTrue);
      expect(modelCapabilitiesFor('').supportsSamplingControls, isTrue);
    });
  });

  group('ApiClient request building (Experiential Labs gateway)', () {
    test('claude-opus-5.5: minimal Hi request has NO temperature', () async {
      final fake = FakeHttpClient()
        ..enqueueJson(200, {
          'id': 'x', 'model': 'claude-opus-5.5',
          'choices': [
            {'index': 0, 'message': {'role': 'assistant', 'content': 'Hi!'}, 'finish_reason': 'stop'}
          ],
        });
      final client = ApiClient(await _storeFor('claude-opus-5.5'),
          clientFactory: () => fake);

      final reply = await client.chat([ChatMessage(role: 'user', content: 'Hi')]);
      expect(reply, 'Hi!');

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body['model'], 'claude-opus-5.5');
      expect(body['messages'], [
        {'role': 'user', 'content': 'Hi'}
      ]);
      expect(body.containsKey('temperature'), isFalse,
          reason: 'claude-opus-5.5 rejects temperature with HTTP 400');
      expect(body['stream'], false);
    });

    test('gpt-5.6-luna: normal chat keeps working with temperature omitted',
        () async {
      final fake = FakeHttpClient()
        ..enqueueJson(200, {
          'id': 'y', 'model': 'gpt-5.6-luna',
          'choices': [
            {'index': 0, 'message': {'role': 'assistant', 'content': 'luna-ok'}, 'finish_reason': 'stop'}
          ],
        });
      final client = ApiClient(await _storeFor('gpt-5.6-luna'), clientFactory: () => fake);

      final reply = await client.chat([
        ChatMessage(role: 'system', content: 'You are helpful.'),
        ChatMessage(role: 'user', content: 'Hi'),
      ]);
      expect(reply, 'luna-ok');

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-5.6-luna');
      expect(body.containsKey('temperature'), isFalse,
          reason: 'gpt-5* reasoning line also rejects temperature');
    });

    test('standard model (qwen) still sends temperature 0.2', () async {
      final fake = FakeHttpClient()
        ..enqueueJson(200, {
          'choices': [
            {'index': 0, 'message': {'role': 'assistant', 'content': 'ok'}, 'finish_reason': 'stop'}
          ],
        });
      final client = ApiClient(await _storeFor('qwen/qwen3.7-flash:free'),
          clientFactory: () => fake);
      await client.chat([ChatMessage(role: 'user', content: 'Hi')]);

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body['temperature'], 0.2);
    });

    test('HTTP 400 exposes status + provider code/param/message', () async {
      final fake = FakeHttpClient()
        ..enqueueJson(400, {
          'error': {
            'message': 'temperature does not support 0.2 with this model',
            'type': 'invalid_request_error',
            'param': 'temperature',
            'code': 'unsupported_value',
          }
        });
      final client = ApiClient(await _storeFor('claude-opus-5.5'), clientFactory: () => fake);

      ApiException? caught;
      try {
        await client.chat([ChatMessage(role: 'user', content: 'Hi')]);
      } on ApiException catch (e) {
        caught = e;
      }
      final e = caught!;
      expect(e.kind, 'bad_request');
      expect(e.message, contains('HTTP 400'));
      expect(e.message, contains('invalid_request_error'));
      expect(e.message, contains('unsupported_value'));
      expect(e.message, contains('param=temperature'));
      expect(e.message, contains('temperature does not support 0.2'));
    });

    test('streaming request omits temperature for claude-opus-5.5 and parses SSE',
        () async {
      final fake = FakeHttpClient()
        ..enqueueSse(200, [
          'data: {"choices":[{"delta":{"content":"He"}}]}',
          'data: {"choices":[{"delta":{"content":"llo"}}]}',
          'data: [DONE]',
        ]);
      final client = ApiClient(await _storeFor('claude-opus-5.5'), clientFactory: () => fake);

      final buf = StringBuffer();
      await for (final piece
          in client.chatStream([ChatMessage(role: 'user', content: 'Hi')])) {
        buf.write(piece);
      }
      expect(buf.toString(), 'Hello');

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body['stream'], true);
      expect(body.containsKey('temperature'), isFalse);
    });
  });

  group('OpenAiCompatibleBackend (Key Manager path)', () {
    ProviderConfig cfg(String model) => ProviderConfig(
          id: 'p1',
          type: AiProviderType.custom,
          label: 'Experiential Labs',
          model: model,
          baseUrl: 'https://api.experientiallabs.ai/v1',
        );

    test('agent tools request: claude-opus-5.5 keeps tools, drops temperature',
        () async {
      final fake = FakeHttpClient()
        ..enqueueJson(200, {
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'c1',
                    'type': 'function',
                    'function': {'name': 'list_files', 'arguments': '{}'}
                  }
                ]
              },
              'finish_reason': 'tool_calls'
            }
          ]
        });
      final backend =
          OpenAiCompatibleBackend(cfg('claude-opus-5.5'), 'xpl_test_key',
              clientFactory: () => fake);

      final r = await backend.chatWithTools(
        [ChatMessage(role: 'user', content: 'Hi')],
        tools: [
          {
            'type': 'function',
            'function': {
              'name': 'list_files',
              'description': 'List files',
              'parameters': {'type': 'object', 'properties': {}}
            }
          }
        ],
      );
      expect(r.toolCalls.single.name, 'list_files');

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body.containsKey('temperature'), isFalse);
      expect(body['tools'], isNotNull);
      expect(body['tool_choice'], 'auto');
    });

    test('gpt-5.6-luna tools request unchanged except temperature omission',
        () async {
      final fake = FakeHttpClient()
        ..enqueueJson(200, {
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'done'},
              'finish_reason': 'stop'
            }
          ]
        });
      final backend = OpenAiCompatibleBackend(cfg('gpt-5.6-luna'), 'xpl_test_key',
          clientFactory: () => fake);

      final r = await backend.chatWithTools(
          [ChatMessage(role: 'user', content: 'Hi')]);
      expect(r.content, 'done');

      final body = jsonDecode(fake.requests.single.body) as Map<String, dynamic>;
      expect(body.containsKey('temperature'), isFalse);
    });

    test('streaming backend: first-token failure surfaces provider 400 detail',
        () async {
      final fake = FakeHttpClient()
        ..enqueueJson(400, {
          'error': {
            'message': 'max_tokens is not supported by this model',
            'type': 'invalid_request_error',
            'param': 'max_tokens',
            'code': 'unsupported_parameter',
          }
        });
      final backend = OpenAiCompatibleBackend(cfg('claude-opus-5.5'), 'xpl_test_key',
          clientFactory: () => fake);

      await expectLater(
        backend.chatStream([ChatMessage(role: 'user', content: 'Hi')]).drain(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message',
            allOf(contains('HTTP 400'), contains('max_tokens')))),
      );
    });
  });

  group('ProviderErrorDetail parsing', () {
    test('OpenAI-style error body', () {
      final d = ProviderErrorDetail.fromBody(400, jsonEncode({
        'error': {
          'message': 'bad param',
          'type': 'invalid_request_error',
          'param': 'top_p',
          'code': 'unsupported_parameter',
        }
      }))!;
      expect(d.status, 400);
      expect(d.type, 'invalid_request_error');
      expect(d.code, 'unsupported_parameter');
      expect(d.param, 'top_p');
      expect(d.message, 'bad param');
      expect(d.describe(),
          'HTTP 400 · type=invalid_request_error · code=unsupported_parameter · param=top_p · message=bad param');
    });

    test('Anthropic-style error body', () {
      final d = ProviderErrorDetail.fromBody(400, jsonEncode({
        'type': 'error',
        'error': {
          'type': 'invalid_request_error',
          'message': 'temperature must be omitted for this model',
        }
      }))!;
      expect(d.type, 'invalid_request_error');
      expect(d.message, contains('temperature must be omitted'));
    });

    test('non-JSON body → null, describe never throws', () {
      expect(ProviderErrorDetail.fromBody(502, '<html>oops</html>'), isNull);
    });
  });
}
