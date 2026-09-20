/// AI provider configuration models.
///
/// A [ProviderConfig] is ONE provider + ONE key slot (e.g. "OpenRouter Key 2").
/// The KEY ITSELF never lives here — it is stored in the Keystore-backed
/// secure vault (see ProviderStore) and only referenced by [id]. Metadata
/// (provider type, model, base URL, enabled flag, priority, default mark) is
/// non-secret and persisted in SharedPreferences.
library;

/// Supported provider families. Every family maps to one backend
/// implementation in provider_backends.dart.
enum AiProviderType {
  openRouter,
  openai,
  gemini,
  anthropic,
  custom;

  String get label => switch (this) {
        AiProviderType.openRouter => 'OpenRouter',
        AiProviderType.openai => 'OpenAI',
        AiProviderType.gemini => 'Google Gemini',
        AiProviderType.anthropic => 'Anthropic',
        AiProviderType.custom => 'Custom (OpenAI-compatible)',
      };

  /// Default API base. [custom] has no default — the user MUST supply one
  /// (an empty string here means "required, unset").
  String get defaultBaseUrl => switch (this) {
        AiProviderType.openRouter => 'https://openrouter.ai/api/v1',
        AiProviderType.openai => 'https://api.openai.com/v1',
        AiProviderType.gemini => 'https://generativelanguage.googleapis.com',
        AiProviderType.anthropic => 'https://api.anthropic.com',
        AiProviderType.custom => '',
      };

  /// Suggested model ids shown as hints in the editor (user can type any).
  String get modelHint => switch (this) {
        AiProviderType.openRouter => 'qwen/qwen3.7-flash:free',
        AiProviderType.openai => 'gpt-4o-mini',
        AiProviderType.gemini => 'gemini-1.5-flash',
        AiProviderType.anthropic => 'claude-3-5-haiku-latest',
        AiProviderType.custom => '',
      };

  static AiProviderType fromName(String? name) => AiProviderType.values
      .firstWhere((t) => t.name == name, orElse: () => AiProviderType.custom);
}

/// How the router picks a configuration for each request.
enum RoutingMode {
  /// Highest-priority enabled config first, then fall back down the chain.
  auto,

  /// Exactly the config the user selected — no fallback to others.
  manual;

  static RoutingMode fromName(String? name) =>
      name == 'manual' ? RoutingMode.manual : RoutingMode.auto;
}

/// One configured provider + key slot. Immutable; edit via copyWith.
class ProviderConfig {
  /// Unique, stable id (also the secure-storage key suffix for the API key).
  final String id;

  final AiProviderType type;

  /// Optional user label to tell keys apart, e.g. "Key 2 — free tier".
  final String label;

  final String model;

  /// Empty → use [AiProviderType.defaultBaseUrl].
  final String baseUrl;

  final bool enabled;

  /// Lower = tried first in Automatic mode (1 is the top slot).
  final int priority;

  /// The default config: preselected in Manual mode and highlighted in UI.
  final bool isDefault;

  const ProviderConfig({
    required this.id,
    required this.type,
    this.label = '',
    required this.model,
    this.baseUrl = '',
    this.enabled = true,
    this.priority = 10,
    this.isDefault = false,
  });

  /// Effective API base URL (explicit override or provider default).
  String get effectiveBaseUrl {
    final b = baseUrl.trim();
    if (b.isNotEmpty) return b;
    final d = type.defaultBaseUrl;
    if (d.isEmpty) {
      throw StateError('Provider "${type.label}" needs a Base URL.');
    }
    return d;
  }

  /// Display name in lists: label if set, otherwise provider + model.
  String get displayName =>
      label.trim().isNotEmpty ? label.trim() : '${type.label} · $model';

  ProviderConfig copyWith({
    String? label,
    String? model,
    String? baseUrl,
    bool? enabled,
    int? priority,
    bool? isDefault,
  }) =>
      ProviderConfig(
        id: id,
        type: type,
        label: label ?? this.label,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
        isDefault: isDefault ?? this.isDefault,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'label': label,
        'model': model,
        'baseUrl': baseUrl,
        'enabled': enabled,
        'priority': priority,
        'isDefault': isDefault,
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
        id: (j['id'] as String?) ?? '',
        type: AiProviderType.fromName(j['type'] as String?),
        label: (j['label'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        baseUrl: (j['baseUrl'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        priority: (j['priority'] as num?)?.toInt() ?? 10,
        isDefault: (j['isDefault'] as bool?) ?? false,
      );

  /// Automatic-mode ordering: priority first, then default, then stable id.
  static int byPriority(ProviderConfig a, ProviderConfig b) {
    final p = a.priority.compareTo(b.priority);
    if (p != 0) return p;
    if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
    return a.id.compareTo(b.id);
  }
}

/// Mask an API key for display: NEVER the full value.
/// `sk-...9f2a8F42` → `••••••••8F42`; short keys are fully masked.
String maskKey(String key) {
  final k = key.trim();
  if (k.length <= 8) return '••••••••';
  return '••••••••${k.substring(k.length - 4)}';
}
