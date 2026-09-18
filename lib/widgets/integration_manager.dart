import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// One pluggable integration (GitHub, GitLab, Dropbox, ...). The Integrations
/// screen renders `IntegrationManager.catalog`, so new providers appear
/// without touching any UI code — add an entry here and it is done.
class Integration {
  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const Integration({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.accent = AppTheme.glowAccent,
  });

  /// Const icon palette for persisted integrations. Restoring icons from
  /// stored code points must go through this list — constructing IconData
  /// dynamically breaks release icon tree-shaking.
  static const _iconPalette = [
    Icons.extension,
    Icons.folder_outlined,
    Icons.link,
    Icons.cloud_outlined,
    Icons.code,
    Icons.account_tree_outlined,
    Icons.call_split,
    Icons.upload_file,
    Icons.hub_outlined,
    Icons.bolt,
  ];

  factory Integration.fromJson(Map<String, dynamic> j) {
    final code = j['iconCode'] as int?;
    IconData icon = Icons.extension;
    for (final candidate in _iconPalette) {
      if (candidate.codePoint == code) {
        icon = candidate;
        break;
      }
    }
    return Integration(
      id: j['id'] as String,
      name: j['name'] as String,
      subtitle: (j['subtitle'] as String?) ?? '',
      icon: icon,
      accent: Color(j['accentValue'] as int? ?? AppTheme.glowAccent.value),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subtitle': subtitle,
        'iconCode': icon.codePoint,
        'accentValue': accent.value,
      };
}

/// Extensible integration registry. The catalog is the single source of
/// truth for the Integrations screen; connect/disconnect state persists in
/// SharedPreferences via [IntegrationManager].
class IntegrationManager extends ChangeNotifier {
  static const _kConnected = 'codepilot_connected_integrations';
  static const _kCustom = 'codepilot_custom_integrations';

  IntegrationManager() {
    _load();
  }

  /// Built-in providers. Add new providers here (or at runtime via
  /// [addCustom]) — the screen needs no changes.
  static const List<Integration> catalog = [
    Integration(
      id: 'github',
      name: 'GitHub',
      subtitle: 'Repositories, pull requests, and issues',
      icon: Icons.code,
    ),
    Integration(
      id: 'gitlab',
      name: 'GitLab',
      subtitle: 'GitLab.com and self-managed projects',
      icon: Icons.account_tree_outlined,
    ),
    Integration(
      id: 'bitbucket',
      name: 'Bitbucket',
      subtitle: 'Atlassian Bitbucket repositories',
      icon: Icons.call_split,
    ),
    Integration(
      id: 'gdrive',
      name: 'Google Drive',
      subtitle: 'Import and export project archives',
      icon: Icons.cloud_outlined,
    ),
    Integration(
      id: 'dropbox',
      name: 'Dropbox',
      subtitle: 'Sync project files with your Dropbox',
      icon: Icons.upload_file,
    ),
  ];

  final Set<String> _connected = {};
  final List<Integration> _custom = [];

  Set<String> get connectedIds => Set.unmodifiable(_connected);
  bool isConnected(String id) => _connected.contains(id);

  /// All entries: built-in catalog followed by user-defined integrations.
  List<Integration> get all => [...catalog, ..._custom];

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _connected
      ..clear()
      ..addAll(prefs.getStringList(_kConnected) ?? const []);
    _custom.clear();
    for (final raw in prefs.getStringList(_kCustom) ?? const <String>[]) {
      try {
        _custom.add(Integration.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } on FormatException {
        // Skip corrupted persisted entries rather than failing startup.
      }
    }
    notifyListeners();
  }

  Future<void> setConnected(String id, bool value) async {
    if (value) {
      _connected.add(id);
    } else {
      _connected.remove(id);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kConnected, _connected.toList());
  }

  /// Register a new provider at runtime (stored and restored on startup).
  Future<Integration> addCustom(String name) async {
    final id = 'custom_${name.toLowerCase().trim().replaceAll(RegExp(r'\\s+'), '_')}';
    final entry = Integration(
      id: id,
      name: name.trim(),
      subtitle: 'Custom integration',
      icon: Icons.extension,
    );
    if (_custom.any((c) => c.id == id)) return entry;
    _custom.add(entry);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs
        .setStringList(_kCustom, [for (final c in _custom) jsonEncode(c.toJson())]);
    return entry;
  }
}

/// Rounded card for one integration on the Integrations screen.
class IntegrationCard extends StatelessWidget {
  final Integration integration;
  final bool connected;
  final VoidCallback onTap;

  const IntegrationCard({
    super.key,
    required this.integration,
    required this.connected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: connected ? AppTheme.glowAccent : AppTheme.border),
          ),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppTheme.navyPanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Icon(integration.icon, color: integration.accent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(integration.name,
                    style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(integration.subtitle,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: connected ? AppTheme.glowSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: connected ? AppTheme.glowAccent : AppTheme.border),
              ),
              child: Text(
                connected ? 'Connected' : 'Connect',
                style: TextStyle(
                  color: connected ? AppTheme.glowAccent : AppTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
