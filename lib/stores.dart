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

  /// Email identity linked via the email-OTP sign-in (non-secret, it is the
  /// user's own address).
  Future<String?> readEmailIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('codepilot_email_identity');
  }

  Future<void> saveEmailIdentity(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('codepilot_email_identity', email.trim());
  }

  Future<void> clearEmailIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('codepilot_email_identity');
  }

  /// Non-secret GitHub identity for UI display ("Connected as …").
  Future<Map<String, String?>> loadGitHubIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'login': prefs.getString('github_identity_login'),
      'avatarUrl': prefs.getString('github_identity_avatar'),
    };
  }

  Future<void> saveGitHubIdentity(String login, String? avatarUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('github_identity_login', login);
    if (avatarUrl == null) {
      await prefs.remove('github_identity_avatar');
    } else {
      await prefs.setString('github_identity_avatar', avatarUrl);
    }
  }

  Future<void> clearGitHubIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('github_identity_login');
    await prefs.remove('github_identity_avatar');
  }

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

/// One recent-search entry shown on the Search History screen.
class SearchHistoryEntry {
  final String query;
  final DateTime time;

  const SearchHistoryEntry(this.query, this.time);

  String get timeLabel {
    final local = time.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    return '$mm/$dd · $hh:$mi';
  }
}

/// Persistent recent-search history. Queries typed on the Home command bar
/// are recorded here (deduplicated, newest first) and shown on the
/// Search History screen. Non-secret data in SharedPreferences.
class SearchHistoryStore {
  static const _kHistory = 'search_history';
  static const _kTs = 'search_history_ts';
  static const maxEntries = 50;

  Future<List<SearchHistoryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final queries = prefs.getStringList(_kHistory) ?? const [];
    final stamps = prefs.getStringList(_kTs) ?? const [];
    final entries = <SearchHistoryEntry>[];
    for (var i = 0; i < queries.length; i++) {
      final raw = stamps.length > i ? stamps[i] : null;
      final ms = raw == null ? null : int.tryParse(raw);
      entries.add(SearchHistoryEntry(queries[i], ms == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(ms)));
    }
    return entries;
  }

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final queries = prefs.getStringList(_kHistory) ?? <String>[];
    final stamps = prefs.getStringList(_kTs) ?? <String>[];
    final existing = queries.indexOf(q);
    if (existing >= 0) {
      queries.removeAt(existing);
      if (existing < stamps.length) stamps.removeAt(existing);
    }
    queries.insert(0, q);
    stamps.insert(0, DateTime.now().millisecondsSinceEpoch.toString());
    if (queries.length > maxEntries) {
      queries.removeRange(maxEntries, queries.length);
      if (stamps.length > maxEntries) stamps.removeRange(maxEntries, stamps.length);
    }
    await prefs.setStringList(_kHistory, queries);
    await prefs.setStringList(_kTs, stamps);
  }

  Future<void> removeAt(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final queries = prefs.getStringList(_kHistory) ?? <String>[];
    final stamps = prefs.getStringList(_kTs) ?? <String>[];
    if (index < 0 || index >= queries.length) return;
    queries.removeAt(index);
    if (index < stamps.length) stamps.removeAt(index);
    await prefs.setStringList(_kHistory, queries);
    await prefs.setStringList(_kTs, stamps);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistory);
    await prefs.remove(_kTs);
  }
}

/// One saved AI chat session (conversation transcript + metadata).
class ChatSession {
  final String id;
  final String title;
  final DateTime time;
  final List<ChatMessage> messages;

  const ChatSession({
    required this.id,
    required this.title,
    required this.time,
    required this.messages,
  });

  ChatSession withMessages(List<ChatMessage> messages) => ChatSession(
        id: id,
        title: title,
        time: DateTime.now(),
        messages: messages,
      );
}

/// Persistent AI chat sessions. Each conversation survives app restarts and
/// can be resumed from the Chats entry point in chat; nothing secret is
/// stored (messages contain project code the user chose to discuss).
class ChatSessionStore {
  static const _kSessions = 'chat_sessions';
  static const maxSessions = 30;

  /// Returns a fresh MUTABLE list (newest first). Callers may filter/reorder
  /// it — never return a `const` list from here: save()/remove() mutate the
  /// result, and a const list would throw "Cannot remove from an
  /// unmodifiable list" (this exact bug broke first-run chat saves).
  Future<List<ChatSession>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessions);
    if (raw == null) return <ChatSession>[];
    try {
      final list = jsonDecode(raw) as List;
      return <ChatSession>[
        for (final item in list)
          if (item is Map)
            ChatSession(
              id: (item['id'] as String?) ?? '',
              title: (item['title'] as String?) ?? 'Chat',
              time: DateTime.tryParse((item['time'] as String?) ?? '') ?? DateTime.now(),
              messages: [
                for (final m in (item['messages'] as List?) ?? const [])
                  if (m is Map) ChatMessage.fromJson(Map<String, dynamic>.from(m)),
              ],
            ),
      ]..removeWhere((s) => s.id.isEmpty || s.messages.isEmpty);
    } catch (_) {
      return <ChatSession>[];
    }
  }

  /// Adds or updates a session (newest first, capped). Returns nothing;
  /// callers re-read via [load] when they need the list.
  Future<void> save({required String? existingId, required String title, required List<ChatMessage> messages}) async {
    if (messages.isEmpty) return;
    final id = existingId ?? DateTime.now().microsecondsSinceEpoch.toString();
    // Mutable copy — load() is documented mutable, but copy defensively so
    // future refactors can never reintroduce unmodifiable-list mutations.
    final sessions = List<ChatSession>.of(await load());
    sessions.removeWhere((s) => s.id == id);
    sessions.insert(
      0,
      ChatSession(
        id: id,
        title: title.isEmpty ? 'Chat' : title,
        time: DateTime.now(),
        messages: messages,
      ),
    );
    if (sessions.length > maxSessions) sessions.removeRange(maxSessions, sessions.length);
    final encoded = jsonEncode([
      for (final s in sessions)
        {
          'id': s.id,
          'title': s.title,
          'time': s.time.toIso8601String(),
          'messages': [for (final m in s.messages) m.toJson()],
        },
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessions, encoded);
  }

  Future<void> remove(String id) async {
    final sessions = List<ChatSession>.of(await load());
    sessions.removeWhere((s) => s.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessions, jsonEncode([
      for (final s in sessions)
        {
          'id': s.id,
          'title': s.title,
          'time': s.time.toIso8601String(),
          'messages': [for (final m in s.messages) m.toJson()],
        },
    ]));
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessions);
  }
}
