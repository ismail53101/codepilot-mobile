import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Secure storage for the API key ONLY (Android Keystore via
/// flutter_secure_storage). Never in SharedPreferences, never in source.
class SecureStore {
  static const _keyName = 'codepilot_api_key';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> readApiKey() => _storage.read(key: _keyName);

  Future<void> writeApiKey(String key) =>
      _storage.write(key: _keyName, value: key.trim());

  Future<void> deleteApiKey() => _storage.delete(key: _keyName);
}

/// Non-secret settings (provider name/base URL/model/timeout/streaming).
class SettingsStore {
  static const _kSettings = 'api_settings';
  final SecureStore _secure = SecureStore();

  Future<ApiSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSettings);
    if (raw == null) return const ApiSettings(); // xKiro defaults
    try {
      return ApiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ApiSettings();
    }
  }

  Future<void> save(ApiSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSettings, jsonEncode(s.toJson()));
  }

  /// Convenience for the API client: settings + key fetched separately.
  Future<({ApiSettings settings, String? apiKey})> loadWithKey() async {
    final settings = await load();
    final apiKey = await readApiKey();
    return (settings: settings, apiKey: apiKey);
  }

  // Public key passthroughs (screens must not touch SecureStore internals).
  Future<String?> readApiKey() => _secure.readApiKey();
  Future<void> writeApiKey(String key) => _secure.writeApiKey(key);
  Future<void> deleteApiKey() => _secure.deleteApiKey();
}
