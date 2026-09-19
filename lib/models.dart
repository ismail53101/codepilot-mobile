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
  final String role; // user | assistant | system | tool
  final String content;
  final bool isError;

  /// Base64 data-URL of an attached image (vision requests). Transient:
  /// intentionally NOT serialized — session storage would overflow with
  /// full images, so restored transcripts keep the [hasImage] marker only.
  final String? imageDataUrl;

  /// Whether this message carried an image (persisted for display).
  final bool hasImage;

  /// For assistant messages that requested tool calls (agent loop):
  /// the raw OpenAI tool_calls array to echo back to the provider.
  final List<Map<String, dynamic>>? toolCalls;

  /// For role=tool messages: the tool_call_id this result answers.
  final String? toolCallId;

  const ChatMessage({
    required this.role,
    required this.content,
    this.isError = false,
    this.imageDataUrl,
    this.hasImage = false,
    this.toolCalls,
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (isError) 'isError': true,
        if (hasImage) 'hasImage': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: (j['role'] as String?) ?? 'user',
        content: (j['content'] as String?) ?? '',
        isError: (j['isError'] as bool?) ?? false,
        hasImage: (j['hasImage'] as bool?) ?? false,
      );
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

// ------------------------------------------------------------------
// Autonomous agent models
// ------------------------------------------------------------------

/// How autonomous the agent is allowed to be.
enum AgentMode {
  /// Inspect, edit, run commands, fix errors, and commit without asking.
  auto,

  /// Inspect and plan freely; every file modification asks first.
  askBeforeChanges,

  /// Produce a plan only — no edits, no commands.
  planOnly,
}

/// Status of a single agent activity step (drives the live activity panel).
enum AgentStepStatus { pending, running, done, failed }

/// One real agent action. Every panel row corresponds to an executed tool —
/// the UI never fabricates activity.
class AgentStep {
  final String id;
  final String title; // short human label, e.g. "Searching code"
  final String tool; // tool name executed
  final Map<String, dynamic> args; // tool arguments
  AgentStepStatus status;
  String? detail; // command output / error / file summary
  bool expanded; // UI toggle

  AgentStep({
    required this.id,
    required this.title,
    required this.tool,
    this.args = const {},
    this.status = AgentStepStatus.pending,
    this.detail,
    this.expanded = false,
  });
}

/// One file change reported by `git_status`.
class GitFileChange {
  final String path;
  final String status; // M | A | D | ?

  const GitFileChange(this.path, this.status);
}
