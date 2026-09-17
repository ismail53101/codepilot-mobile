import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Secure storage for the API key ONLY (Android Keystore via
/// flutter_secure_storage). Never in SharedPreferences, never in source.
class SecureStore {
  static const _keyName = 'codepilot_api_key';
  static const _githubTokenName = 'codepilot_github_token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> readApiKey() => _storage.read(key: _keyName);

  Future<void> writeApiKey(String key) =>
      _storage.write(key: _keyName, value: key.trim());

  Future<void> deleteApiKey() => _storage.delete(key: _keyName);

  Future<String?> readGitHubToken() => _storage.read(key: _githubTokenName);
  Future<void> writeGitHubToken(String token) =>
      _storage.write(key: _githubTokenName, value: token.trim());
  Future<void> deleteGitHubToken() => _storage.delete(key: _githubTokenName);
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
  Future<String?> readGitHubToken() => _secure.readGitHubToken();
  Future<void> writeGitHubToken(String token) => _secure.writeGitHubToken(token);
  Future<void> deleteGitHubToken() => _secure.deleteGitHubToken();

  Future<Map<String, String?>> loadGitHubProject() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'owner': prefs.getString('github_repo_owner'),
      'name': prefs.getString('github_repo_name'),
      'branch': prefs.getString('github_repo_branch'),
    };
  }

  Future<void> saveGitHubProject(String owner, String name, String branch) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('github_repo_owner', owner);
    await prefs.setString('github_repo_name', name);
    await prefs.setString('github_repo_branch', branch);
  }

  Future<void> clearGitHubProject() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('github_repo_owner');
    await prefs.remove('github_repo_name');
    await prefs.remove('github_repo_branch');
  }
}
