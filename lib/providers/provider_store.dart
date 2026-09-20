import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../stores.dart';
import 'provider_config.dart';

/// Where provider API keys live. Production uses the Keystore-backed
/// [FlutterSecureStorage]; tests inject [InMemoryKeyVault]. Keys are stored
/// ONE PER CONFIG under `provider_key_<id>` and never leave the vault except
/// in the Authorization header of the provider request.
abstract class KeyVault {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class SecureKeyVault implements KeyVault {
  static const _prefix = 'provider_key_';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String id) => _storage.read(key: '$_prefix$id');

  @override
  Future<void> write(String id, String value) =>
      _storage.write(key: '$_prefix$id', value: value.trim());

  @override
  Future<void> delete(String id) => _storage.delete(key: '$_prefix$id');
}

/// Test-only in-memory vault.
class InMemoryKeyVault implements KeyVault {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String id) async => _map[id];
  @override
  Future<void> write(String id, String value) async => _map[id] = value.trim();
  @override
  Future<void> delete(String id) async => _map.remove(id);
}

/// Routing preferences: automatic (priority chain + fallback) or manual
/// (exactly the selected config).
class RoutingSettings {
  final RoutingMode mode;
  final String manualConfigId;

  const RoutingSettings({
    this.mode = RoutingMode.auto,
    this.manualConfigId = '',
  });

  Map<String, dynamic> toJson() =>
      {'mode': mode.name, 'manualConfigId': manualConfigId};

  factory RoutingSettings.fromJson(Map<String, dynamic> j) => RoutingSettings(
        mode: RoutingMode.fromName(j['mode'] as String?),
        manualConfigId: (j['manualConfigId'] as String?) ?? '',
      );
}

/// Central AI provider manager: the list of configured provider/key slots,
/// their routing order, and the secure key vault. Non-secret metadata lives
/// in SharedPreferences; keys live ONLY in the [KeyVault].
class ProviderStore {
  static const _kConfigs = 'ai_provider_configs';
  static const _kRouting = 'ai_routing';

  final KeyVault vault;
  ProviderStore({KeyVault? keyVault}) : vault = keyVault ?? SecureKeyVault();

  // ---------------- configs ----------------

  Future<List<ProviderConfig>> loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConfigs);
    if (raw == null) return <ProviderConfig>[];
    try {
      final list = jsonDecode(raw) as List;
      return <ProviderConfig>[
        for (final item in list)
          if (item is Map)
            ProviderConfig.fromJson(Map<String, dynamic>.from(item)),
      ]..removeWhere((c) => c.id.isEmpty);
    } catch (_) {
      return <ProviderConfig>[];
    }
  }

  Future<void> saveConfigs(List<ProviderConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kConfigs, jsonEncode([for (final c in configs) c.toJson()]));
  }

  /// Insert-or-update by id, keeping list order stable, then persist.
  Future<void> upsert(ProviderConfig config) async {
    final configs = List<ProviderConfig>.of(await loadConfigs());
    final i = configs.indexWhere((c) => c.id == config.id);
    if (i >= 0) {
      configs[i] = config;
    } else {
      configs.add(config);
    }
    await saveConfigs(configs);
  }

  Future<void> remove(String id) async {
    await deleteKey(id);
    final configs = List<ProviderConfig>.of(await loadConfigs());
    configs.removeWhere((c) => c.id == id);
    await saveConfigs(configs);
    // Routing that points at a removed config falls back to automatic.
    final routing = await loadRouting();
    if (routing.manualConfigId == id) {
      await saveRouting(const RoutingSettings(mode: RoutingMode.auto));
    }
  }

  /// New unique config id.
  Future<String> newId() async {
    final existing = await loadConfigs();
    var n = existing.length + 1;
    String candidate() => 'prov_${DateTime.now().millisecondsSinceEpoch}_$n';
    var id = candidate();
    while (existing.any((c) => c.id == id)) {
      n++;
      id = candidate();
    }
    return id;
  }

  // ---------------- keys ----------------

  Future<String?> readKey(String configId) => vault.read(configId);
  Future<void> writeKey(String configId, String key) =>
      vault.write(configId, key);
  Future<void> deleteKey(String configId) => vault.delete(configId);

  /// Masked key for UI display ('••••••••8F42'), or null when unset.
  Future<String?> maskedKey(String configId) async {
    final key = await readKey(configId);
    return key == null || key.trim().isEmpty ? null : maskKey(key);
  }

  // ---------------- routing ----------------

  Future<RoutingSettings> loadRouting() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRouting);
    if (raw == null) return const RoutingSettings();
    try {
      return RoutingSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const RoutingSettings();
    }
  }

  Future<void> saveRouting(RoutingSettings r) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRouting, jsonEncode(r.toJson()));
  }

  // ---------------- legacy migration ----------------

  /// One-time migration: the pre-multi-provider setup stored a single
  /// provider + key via [SettingsStore]. If the new config list is empty and
  /// that key exists, adopt it as the first (default) config so the user's
  /// working setup keeps working unchanged. Idempotent.
  Future<void> migrateLegacyIfNeeded(SettingsStore legacy) async {
    final configs = await loadConfigs();
    if (configs.isNotEmpty) return;
    final (:settings, apiKey: key) = await legacy.loadWithKey();
    if (key == null || key.trim().isEmpty) return;
    const id = 'legacy_primary';
    await writeKey(id, key);
    await upsert(ProviderConfig(
      id: id,
      type: AiProviderType.custom,
      label: settings.providerName.isEmpty
          ? 'Primary provider'
          : settings.providerName,
      model: settings.modelId,
      baseUrl: settings.baseUrl,
      enabled: true,
      priority: 1,
      isDefault: true,
    ));
  }
}
