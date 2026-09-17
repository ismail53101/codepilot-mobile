/// Data models shared across screens and services.
library models;

/// Non-secret provider settings (persisted via shared_preferences).
/// The API key NEVER lives here — see SecureStore.
class ApiSettings {
  final String providerName;
  final String baseUrl;
  final String modelId;
  final int requestTimeout; // seconds
  final bool streaming;

  const ApiSettings({
    this.providerName = 'xKiro',
    this.baseUrl = 'https://api.xkiro.com/v1',
    this.modelId = 'qwen/qwen3.7-flash:free',
    this.requestTimeout = 180,
    this.streaming = false,
  });

  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;

  ApiSettings copyWith({
    String? providerName,
    String? baseUrl,
    String? modelId,
    int? requestTimeout,
    bool? streaming,
  }) =>
      ApiSettings(
        providerName: providerName ?? this.providerName,
        baseUrl: baseUrl ?? this.baseUrl,
        modelId: modelId ?? this.modelId,
        requestTimeout: requestTimeout ?? this.requestTimeout,
        streaming: streaming ?? this.streaming,
      );

  Map<String, dynamic> toJson() => {
        'providerName': providerName,
        'baseUrl': baseUrl,
        'modelId': modelId,
        'requestTimeout': requestTimeout,
        'streaming': streaming,
      };

  factory ApiSettings.fromJson(Map<String, dynamic> j) => ApiSettings(
        providerName: (j['providerName'] as String?) ?? 'xKiro',
        baseUrl: (j['baseUrl'] as String?) ?? 'https://api.xkiro.com/v1',
        modelId: (j['modelId'] as String?) ?? 'qwen/qwen3.7-flash:free',
        requestTimeout: (j['requestTimeout'] as num?)?.toInt() ?? 180,
        streaming: (j['streaming'] as bool?) ?? false,
      );
}

/// One node of the project file tree.
class FileNode {
  final String path; // relative path from project root
  final bool isDir;
  final int size;

  const FileNode({required this.path, required this.isDir, this.size = 0});

  String get name => path.split('/').last;
}

/// A search hit.
class SearchHit {
  final String path;
  final int line;
  final String text;

  const SearchHit(this.path, this.line, this.text);
}

/// A chat message in the agent conversation.
class ChatMessage {
  final String role; // user | assistant | system
  final String content;
  final bool isError;

  const ChatMessage({required this.role, required this.content, this.isError = false});
}

/// A recorded change (applied or undone) for the change history.
class ChangeRecord {
  final String id;
  final DateTime time;
  final String kind; // write | delete
  final String path;
  final String? contentBefore;
  final String? contentAfter;
  final bool undone;

  const ChangeRecord({
    required this.id,
    required this.time,
    required this.kind,
    required this.path,
    this.contentBefore,
    this.contentAfter,
    this.undone = false,
  });

  ChangeRecord markUndone() => ChangeRecord(
      id: id, time: time, kind: kind, path: path,
      contentBefore: contentBefore, contentAfter: contentAfter, undone: true);
}

/// Result of one agent tool execution — real outcome only.
class ToolResult {
  final String tool;
  final bool ok;
  final String detail;

  const ToolResult(this.tool, this.ok, this.detail);
}

/// Simple unified line diff (context-free, colored by the UI).
class DiffLine {
  final String type; // same | add | del | hunk
  final String text;

  const DiffLine(this.type, this.text);
}
