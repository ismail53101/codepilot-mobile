import 'package:flutter/material.dart';

import '../providers/provider_backends.dart';
import '../providers/provider_config.dart';
import '../providers/provider_store.dart';
import '../stores.dart';
import '../theme.dart';
import '../main.dart' show settingsStore;

/// API KEY MANAGER — central manager for ALL providers and keys.
///
/// Multiple providers can coexist (OpenRouter, OpenAI, Gemini, Anthropic,
/// custom OpenAI-compatible), each with one or more key slots. Keys live in
/// the Keystore-backed vault and are NEVER displayed — only masked tails
/// (••••••••8F42). Nothing here touches the chat/agent flow directly; the
/// provider router reads these configs per request.
class ApiKeyManagerScreen extends StatefulWidget {
  const ApiKeyManagerScreen({super.key});

  @override
  State<ApiKeyManagerScreen> createState() => _ApiKeyManagerScreenState();
}

class _ApiKeyManagerScreenState extends State<ApiKeyManagerScreen> {
  final ProviderStore store = ProviderStore();
  List<ProviderConfig> _configs = [];
  RoutingSettings _routing = const RoutingSettings();
  Map<String, String> _masked = {}; // configId → masked key ('' = none)
  bool _loading = true;
  String? _testing; // config id currently under test
  String? _testResult; // 'label — ok/message'

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await store.migrateLegacyIfNeeded(settingsStore);
    final configs = await store.loadConfigs();
    final routing = await store.loadRouting();
    final masked = <String, String>{};
    for (final c in configs) {
      masked[c.id] = await store.maskedKey(c.id) ?? '';
    }
    if (!mounted) return;
    setState(() {
      _configs = configs..sort(ProviderConfig.byPriority);
      _routing = routing;
      _masked = masked;
      _loading = false;
    });
  }

  // ---------------- actions ----------------

  Future<void> _toggleEnabled(ProviderConfig c, bool enabled) async {
    await store.upsert(c.copyWith(enabled: enabled));
    await _reload();
  }

  Future<void> _setDefault(ProviderConfig c) async {
    for (final other in _configs) {
      if (other.isDefault && other.id != c.id) {
        await store.upsert(other.copyWith(isDefault: false));
      }
    }
    await store.upsert(c.copyWith(isDefault: true));
    await _reload();
  }

  Future<void> _adjustPriority(ProviderConfig c, int delta) async {
    final next = (c.priority + delta).clamp(1, 99);
    await store.upsert(c.copyWith(priority: next));
    await _reload();
  }

  Future<void> _delete(ProviderConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete provider key?'),
        content: Text(
            '${c.displayName} and its stored API key will be removed from this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.err),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.remove(c.id);
      await _reload();
    }
  }

  Future<void> _test(ProviderConfig c, {String? freshKey}) async {
    setState(() {
      _testing = c.id;
      _testResult = null;
    });
    final key = (freshKey != null && freshKey.trim().isNotEmpty)
        ? freshKey.trim()
        : await store.readKey(c.id);
    String result;
    if (key == null || key.trim().isEmpty) {
      result = 'No API key stored for this slot.';
    } else {
      try {
        final backend = AiProviderBackend.forConfig(c, key.trim());
        final (ok, detail) = await backend.testConnection();
        result = ok ? '✓ $detail' : detail;
      } catch (e) {
        result = 'Test failed: $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _testing = null;
      _testResult = result;
    });
  }

  Future<void> _addOrEdit([ProviderConfig? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ProviderEditorSheet(store: store, existing: existing),
    );
    if (saved == true) await _reload();
  }

  Future<void> _setRoutingMode(RoutingMode mode) async {
    if (mode == RoutingMode.manual && _routing.manualConfigId.isEmpty) {
      final first = _configs.where((c) => c.enabled).toList().isEmpty
          ? (_configs.isEmpty ? null : _configs.first)
          : _configs.firstWhere((c) => c.enabled);
      if (first == null) return;
      await store.saveRouting(RoutingSettings(
          mode: RoutingMode.manual, manualConfigId: first.id));
    } else {
      await store.saveRouting(RoutingSettings(
        mode: mode,
        manualConfigId: _routing.manualConfigId,
      ));
    }
    await _reload();
  }

  Future<void> _pickManualConfig() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Use this provider for every request',
                  style: TextStyle(color: AppTheme.text))),
          for (final c in _configs)
            ListTile(
              leading: Icon(_iconFor(c.type),
                  color: c.id == _routing.manualConfigId
                      ? AppTheme.glowAccent
                      : AppTheme.muted,
                  size: 20),
              title: Text(c.displayName,
                  style: const TextStyle(color: AppTheme.text, fontSize: 14)),
              subtitle: Text(
                  'Priority ${c.priority}${c.enabled ? '' : ' · disabled'}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
              trailing: c.id == _routing.manualConfigId
                  ? const Icon(Icons.check, color: AppTheme.glowAccent, size: 18)
                  : null,
              onTap: () => Navigator.pop(ctx, c.id),
            ),
        ]),
      ),
    );
    if (id != null) {
      await store.saveRouting(RoutingSettings(
          mode: RoutingMode.manual, manualConfigId: id));
      await _reload();
    }
  }

  // ---------------- build ----------------

  IconData _iconFor(AiProviderType t) => switch (t) {
        AiProviderType.openRouter => Icons.bolt,
        AiProviderType.openai => Icons.smart_toy_outlined,
        AiProviderType.gemini => Icons.diamond_outlined,
        AiProviderType.anthropic => Icons.terminal,
        AiProviderType.custom => Icons.settings_input_component,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('API Keys & Providers',
            style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Advanced provider settings (timeout, streaming)',
            icon: const Icon(Icons.tune, size: 20),
            onPressed: () => Navigator.pushNamed(context, '/api'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.glowAccent,
        foregroundColor: Colors.white,
        onPressed: _addOrEdit,
        icon: const Icon(Icons.add),
        label: const Text('Add Provider'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.glowAccent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                _routingCard(),
                const SizedBox(height: 8),
                if (_testResult != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Text(_testResult!,
                        style:
                            const TextStyle(color: AppTheme.muted, fontSize: 12)),
                  ),
                if (_configs.isEmpty)
                  const _EmptyHint(),
                for (final c in _configs)
                  _configCard(c),
                const SizedBox(height: 8),
                const Text(
                  'Keys are stored in Android Keystore-backed secure storage, '
                  'sent only to their provider, and never shown in full.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 11),
                ),
              ],
            ),
    );
  }

  Widget _routingCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Routing',
            style: TextStyle(
                color: AppTheme.text,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _modeTile(
              'Automatic',
              'Priority order + fallback',
              Icons.auto_mode_outlined,
              _routing.mode == RoutingMode.auto,
              () => _setRoutingMode(RoutingMode.auto),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _modeTile(
              'Manual',
              'Always one provider',
              Icons.push_pin_outlined,
              _routing.mode == RoutingMode.manual,
              () => _setRoutingMode(RoutingMode.manual),
            ),
          ),
        ]),
        if (_routing.mode == RoutingMode.manual) ...[
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickManualConfig,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.surface2,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(children: [
                const Icon(Icons.push_pin_outlined,
                    size: 15, color: AppTheme.glowAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _configs
                            .where((c) => c.id == _routing.manualConfigId)
                            .map((c) => c.displayName)
                            .firstOrNull ??
                        'Pick a provider…',
                    style: const TextStyle(color: AppTheme.text, fontSize: 12.5),
                  ),
                ),
                const Icon(Icons.expand_more, size: 16, color: AppTheme.muted),
              ]),
            ),
          ),
        ] else ...[
          const SizedBox(height: 6),
          const Text(
            'Requests try Priority 1 first, then fall back to the next '
            'enabled key/provider on rate limits, quota, invalid keys or outages.',
            style: TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
        ],
      ]),
    );
  }

  Widget _modeTile(String label, String sub, IconData icon, bool active,
      VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: active ? AppTheme.glowSoft : AppTheme.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? AppTheme.glowAccent : AppTheme.border),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: active ? AppTheme.glowAccent : AppTheme.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      color: active ? AppTheme.text : AppTheme.muted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
              Text(sub,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 10)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _configCard(ProviderConfig c) {
    final masked = _masked[c.id];
    final isManual = _routing.manualConfigId == c.id;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isManual ? AppTheme.glowAccent.withOpacity(.5) : AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_iconFor(c.type),
              size: 17,
              color: c.enabled ? AppTheme.glowAccent : AppTheme.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(c.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: c.enabled ? AppTheme.text : AppTheme.muted,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
          ),
          if (c.isDefault)
            const Icon(Icons.star, size: 15, color: AppTheme.gold),
          if (isManual)
            const Icon(Icons.push_pin, size: 13, color: AppTheme.glowAccent),
          Switch(
            value: c.enabled,
            activeColor: AppTheme.glowAccent,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => _toggleEnabled(c, v),
          ),
        ]),
        const SizedBox(height: 4),
        Text(c.model.isEmpty ? 'No model set' : c.model,
            style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 11.5,
                fontFamily: 'monospace')),
        const SizedBox(height: 2),
        Text(
          masked == null || masked.isEmpty
              ? 'No API key — tap Edit to add one'
              : masked,
          style: TextStyle(
              color: masked == null || masked.isEmpty
                  ? AppTheme.warn
                  : AppTheme.muted,
              fontSize: 11.5,
              fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          // Priority stepper: lower number = tried first.
          _miniBtn(Icons.arrow_upward, 'Raise priority',
              () => _adjustPriority(c, -1)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.surface2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text('Priority ${c.priority}',
                style: const TextStyle(color: AppTheme.text, fontSize: 11)),
          ),
          _miniBtn(Icons.arrow_downward, 'Lower priority',
              () => _adjustPriority(c, 1)),
          const Spacer(),
          _miniBtn(Icons.star_border, 'Set as default', () => _setDefault(c)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          _miniBtn(_testing == c.id ? Icons.hourglass_top : Icons.network_check,
              'Test connection', () => _test(c)),
          const SizedBox(width: 6),
          _miniBtn(Icons.edit_outlined, 'Edit', () => _addOrEdit(c)),
          const SizedBox(width: 6),
          _miniBtn(Icons.delete_outline, 'Delete', () => _delete(c),
              danger: true),
        ]),
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppTheme.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border),
          ),
          child: Icon(icon,
              size: 15, color: danger ? AppTheme.err : AppTheme.muted),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Column(children: [
        Icon(Icons.key, color: AppTheme.glowAccent, size: 28),
        SizedBox(height: 8),
        Text('No providers configured',
            style: TextStyle(
                color: AppTheme.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        Text(
            'Add a provider and API key. Your previous single-provider setup '
            'is adopted automatically on first open.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.muted, fontSize: 12)),
      ]),
    );
  }
}

// ----------------------------------------------------------------------
// Editor sheet
// ----------------------------------------------------------------------

class _ProviderEditorSheet extends StatefulWidget {
  final ProviderStore store;
  final ProviderConfig? existing;

  const _ProviderEditorSheet({required this.store, this.existing});

  @override
  State<_ProviderEditorSheet> createState() => _ProviderEditorSheetState();
}

class _ProviderEditorSheetState extends State<_ProviderEditorSheet> {
  late AiProviderType _type =
      widget.existing?.type ?? AiProviderType.openRouter;
  late final TextEditingController _label =
      TextEditingController(text: widget.existing?.label ?? '');
  late final TextEditingController _model =
      TextEditingController(text: widget.existing?.model ?? '');
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.existing?.baseUrl ?? '');
  final TextEditingController _key = TextEditingController();
  late int _priority = widget.existing?.priority ?? 10;
  late bool _enabled = widget.existing?.enabled ?? true;

  List<String> _models = const [];
  String? _fetching;
  String? _error;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _label.dispose();
    _model.dispose();
    _baseUrl.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    final key = _key.text.trim().isNotEmpty
        ? _key.text.trim()
        : await widget.store.readKey(widget.existing?.id ?? '');
    if (key == null || key.isEmpty) {
      setState(() => _error = 'Enter the API key first to fetch models.');
      return;
    }
    setState(() {
      _fetching = 'Fetching models…';
      _error = null;
    });
    try {
      final backend = AiProviderBackend.forConfig(
          _draft(model: _model.text.trim()), key);
      final models = await backend.listModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _fetching = models.isEmpty ? 'No model list available — type an id.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetching = null);
      setState(() => _error = 'Could not fetch models: $e');
    }
  }

  ProviderConfig _draft({String model = ''}) => ProviderConfig(
        id: widget.existing?.id ?? 'draft',
        type: _type,
        label: _label.text.trim(),
        model: model,
        baseUrl: _baseUrl.text.trim(),
      );

  Future<void> _save() async {
    final model = _model.text.trim();
    if (model.isEmpty) {
      setState(() => _error = 'Model ID is required.');
      return;
    }
    if (_type == AiProviderType.custom && _baseUrl.text.trim().isEmpty) {
      setState(() => _error = 'Custom providers need a Base URL.');
      return;
    }
    if (!_editing &&
        _key.text.trim().isEmpty &&
        widget.existing == null) {
      setState(() => _error = 'API key is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final store = widget.store;
      final id = widget.existing?.id ?? await store.newId();
      if (_key.text.trim().isNotEmpty) {
        await store.writeKey(id, _key.text.trim());
      }
      // Only the first-ever config becomes default automatically.
      final configs = await store.loadConfigs();
      final isDefault = widget.existing?.isDefault ??
          (!configs.any((c) => c.isDefault) && configs.isEmpty);
      await store.upsert(ProviderConfig(
        id: id,
        type: _type,
        label: _label.text.trim(),
        model: model,
        baseUrl: _baseUrl.text.trim(),
        enabled: _enabled,
        priority: _priority,
        isDefault: isDefault,
      ));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_editing ? 'Edit provider key' : 'Add provider',
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in AiProviderType.values)
                  ChoiceChip(
                    label: Text(t.label,
                        style: TextStyle(
                            fontSize: 11,
                            color: _type == t
                                ? Colors.white
                                : AppTheme.muted)),
                    selected: _type == t,
                    selectedColor: AppTheme.glowAccent,
                    backgroundColor: AppTheme.surface2,
                    side: BorderSide(
                        color: _type == t
                            ? AppTheme.glowAccent
                            : AppTheme.border),
                    onSelected: (_) => setState(() {
                      _type = t;
                      _models = const [];
                      if (_model.text.isEmpty) _model.text = t.modelHint;
                      if (t != AiProviderType.custom) {
                        _baseUrl.text = '';
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _field(_label, 'Label (e.g. "Key 2 — free tier")'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field(_model, 'Model ID')),
              IconButton(
                tooltip: 'Fetch model list from the provider',
                onPressed: _fetching != null ? null : _fetchModels,
                icon: const Icon(Icons.list_alt,
                    size: 20, color: AppTheme.glowAccent),
              ),
            ]),
            if (_models.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: AppTheme.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _models.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(_models[i],
                        style: const TextStyle(
                            color: AppTheme.text,
                            fontSize: 12,
                            fontFamily: 'monospace')),
                    onTap: () {
                      _model.text = _models[i];
                      setState(() => _models = const []);
                    },
                  ),
                ),
              ),
            if (_fetching != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_fetching!,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
              ),
            const SizedBox(height: 8),
            _field(
              _baseUrl,
              _type == AiProviderType.custom
                  ? 'Base URL (required, OpenAI-compatible)'
                  : 'Base URL (optional — default: ${_type.defaultBaseUrl})',
            ),
            const SizedBox(height: 8),
            _field(
              _key,
              _editing
                  ? 'API key (leave blank to keep the stored one)'
                  : 'API key',
              obscure: true,
            ),
            const SizedBox(height: 10),
            Row(children: [
              const Text('Priority',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _priority > 1
                    ? () => setState(() => _priority--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline,
                    size: 18, color: AppTheme.muted),
              ),
              Text('$_priority',
                  style: const TextStyle(
                      color: AppTheme.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _priority < 99
                    ? () => setState(() => _priority++)
                    : null,
                icon: const Icon(Icons.add_circle_outline,
                    size: 18, color: AppTheme.muted),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('lower = tried first in Automatic mode',
                    style: TextStyle(color: AppTheme.muted, fontSize: 10)),
              ),
              Switch(
                value: _enabled,
                activeColor: AppTheme.glowAccent,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const Text('Enabled',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: const TextStyle(color: AppTheme.err, fontSize: 12)),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.glowAccent),
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      obscuringCharacter: '•',
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: AppTheme.text, fontSize: 13),
      cursorColor: AppTheme.glowAccent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 12),
        filled: true,
        fillColor: AppTheme.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.glowAccent),
        ),
      ),
    );
  }
}
