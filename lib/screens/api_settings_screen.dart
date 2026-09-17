import 'package:flutter/material.dart';

import '../api_client.dart';
import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../theme.dart';

/// Custom API Provider screen. The key goes to SecureStore (Android
/// Keystore-backed) — never into preferences, code, logs, or exports.
class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _model = TextEditingController(text: 'qwen/qwen3.7-flash:free');
  final _key = TextEditingController();
  final _timeout = TextEditingController(text: '180');
  bool _streaming = false;
  bool _keyVisible = false;
  bool _busy = false;
  bool _testing = false;
  String? _hasKeyHint;
  List<String> _models = [];
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await settingsStore.load();
    final key = await settingsStore.readApiKey();
    if (!mounted) return;
    setState(() {
      _name.text = s.providerName;
      _baseUrl.text = s.baseUrl;
      _model.text = s.modelId;
      _timeout.text = s.requestTimeout.toString();
      _streaming = s.streaming;
      _hasKeyHint = key == null || key.isEmpty ? null : maskKey(key);
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      final url = _baseUrl.text.trim();
      if (url.isEmpty || !url.startsWith('http')) {
        throw const ApiException('Base URL must start with http(s):// — e.g. https://api.xkiro.com/v1', 'config');
      }
      if (_model.text.trim().isEmpty) {
        throw const ApiException('Model ID is required.', 'config');
      }
      final s = ApiSettings(
        providerName: _name.text.trim().isEmpty ? 'xKiro' : _name.text.trim(),
        baseUrl: url,
        modelId: _model.text.trim(),
        requestTimeout: (int.tryParse(_timeout.text) ?? 180).clamp(5, 600),
        streaming: _streaming,
      );
      await settingsStore.save(s);
      final key = _key.text.trim();
      if (key.isNotEmpty) {
        await settingsStore.writeApiKey(key);
        _key.clear();
      }
      await _load();
      setState(() { _message = 'Settings saved.'; _isError = false; });
    } on ApiException catch (e) {
      setState(() { _message = e.message; _isError = true; });
    } catch (e) {
      setState(() { _message = 'Save failed: $e'; _isError = true; });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() { _testing = true; _message = null; });
    // Test the SAVED settings; save first if the user typed a new key.
    await _save();
    final (ok, detail) = await apiClient.testConnection();
    if (!mounted) return;
    setState(() {
      _message = detail;
      _isError = !ok;
      _testing = false;
    });
  }

  Future<void> _fetchModels() async {
    setState(() { _testing = true; _message = 'Fetching model list…'; _isError = false; });
    try {
      final models = await apiClient.listModels();
      setState(() { _models = models; _message = '${models.length} models available — tap Model ID to pick.'; _isError = false; });
    } on ApiException catch (e) {
      setState(() { _message = e.message; _isError = true; });
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Custom API Provider')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _field('Provider name', _name, 'e.g. xKiro'),
          _field('Base URL', _baseUrl, 'https://api.xkiro.com/v1', mono: true),
          _modelField(),
          _field('API key', _key, _hasKeyHint == null ? 'sk-… (stored in Android secure storage)' : 'Stored: $_hasKeyHint — type a new key to replace',
              obscure: !_keyVisible,
              suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: Icon(_keyVisible ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _keyVisible = !_keyVisible)),
                if (_hasKeyHint != null) IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Remove stored key', onPressed: () async {
                  await settingsStore.deleteApiKey();
                  await _load();
                }),
              ])),
          Row(children: [
            Expanded(child: _field('Request timeout (s)', _timeout, '180', number: true)),
            const SizedBox(width: 12),
            Expanded(child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Streaming', style: TextStyle(fontSize: 14)),
              value: _streaming, onChanged: (v) => setState(() => _streaming = v),
            )),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _busy ? null : _save,
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
              label: const Text('Save'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(onPressed: _testing ? null : _test,
              icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.power),
              label: const Text('Test connection'))),
          ]),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _testing ? null : _fetchModels, child: const Text('Fetch model list (/models)')),
        ]))),
        if (_message != null) Padding(padding: const EdgeInsets.all(12), child: Text(_message!, style: TextStyle(color: _isError ? AppTheme.err : AppTheme.ok))),
        Card(color: AppTheme.surface2, child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('How your key is protected', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text('• Stored in Android Keystore-backed secure storage, not in app preferences\n'
               '• Sent only in the Authorization header to your provider\n'
               '• Never written to chat, logs, project files, error messages, or exported ZIPs\n'
               '• Change it any time on this screen — no code edits needed',
              style: TextStyle(fontSize: 13)),
        ]))),
      ]),
    );
  }

  Widget _modelField() {
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: Autocomplete<String>(
      initialValue: TextEditingValue(text: _model.text),
      optionsBuilder: (v) => _models.where((m) => m.toLowerCase().contains(v.text.toLowerCase())),
      onSelected: (v) => _model.text = v,
      fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
        controller: controller,
        focusNode: focus,
        decoration: const InputDecoration(labelText: 'Model ID', hintText: 'qwen/qwen3.7-flash:free'),
        onChanged: (v) => _model.text = v,
      ),
    ));
  }

  Widget _field(String label, TextEditingController c, String hint,
      {bool obscure = false, Widget? suffix, bool number = false, bool mono = false}) {
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix),
      style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
    ));
  }
}
