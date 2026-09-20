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

  /// Compact attachment metadata for the transcript. File contents remain in
  /// the request only; the visible name/type is enough to avoid duplicating
  /// large files in persisted chat history.
  final String? attachmentName;
  final String? attachmentKind;

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
    this.attachmentName,
    this.attachmentKind,
    this.toolCalls,
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (isError) 'isError': true,
        if (hasImage) 'hasImage': true,
        if (attachmentName != null) 'attachmentName': attachmentName,
        if (attachmentKind != null) 'attachmentKind': attachmentKind,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: (j['role'] as String?) ?? 'user',
        content: (j['content'] as String?) ?? '',
        isError: (j['isError'] as bool?) ?? false,
        hasImage: (j['hasImage'] as bool?) ?? false,
        attachmentName: j['attachmentName'] as String?,
        attachmentKind: j['attachmentKind'] as String?,
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

  /// JSON serialization for continuous activity persistence (see
  /// AgentActivitySnapshot). Args must be JSON-safe (the registry only
  /// passes string/bool/num values).
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'tool': tool,
        'args': args,
        'status': status.name,
        if (detail != null) 'detail': detail,
      };

  factory AgentStep.fromJson(Map<String, dynamic> j) => AgentStep(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        tool: (j['tool'] as String?) ?? '',
        args: (j['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        status: AgentStepStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => AgentStepStatus.done,
        ),
        detail: j['detail'] as String?,
      );
}

/// Manus-style "What the agent did" roll-up — derived ONLY from real
/// executed [AgentStep]s, never fabricated. The activity panel renders this
/// when a task completes so the user can see the concrete outcome.
class AgentActionSummary {
  final List<String> filesChanged; // created / updated / moved paths
  final List<String> filesDeleted;
  final List<String> commandsRun;
  final List<String> commits; // commit messages (tool args)
  final int filesRead; // read_file + list_files executions
  final int searches;
  final int failedSteps;
  final int totalSteps;

  const AgentActionSummary({
    required this.filesChanged,
    required this.filesDeleted,
    required this.commandsRun,
    required this.commits,
    required this.filesRead,
    required this.searches,
    required this.failedSteps,
    required this.totalSteps,
  });

  factory AgentActionSummary.fromSteps(List<AgentStep> steps) {
    final changed = <String>[];
    final deleted = <String>[];
    final commands = <String>[];
    final commits = <String>[];
    var reads = 0;
    var searches = 0;
    var failed = 0;
    void addUnique(List<String> list, String? value) {
      final v = value?.trim();
      if (v == null || v.isEmpty || list.contains(v)) return;
      list.add(v);
    }

    for (final s in steps) {
      if (s.status == AgentStepStatus.failed) failed++;
      switch (s.tool) {
        case 'write_file':
        case 'create_file':
        case 'patch_file':
          addUnique(changed, s.args['path'] as String?);
          break;
        case 'move_file':
          addUnique(changed, (s.args['destination'] ?? s.args['to']) as String?);
          break;
        case 'delete_file':
          addUnique(deleted, s.args['path'] as String?);
          break;
        case 'run_command':
          addUnique(commands, s.args['command'] as String?);
          break;
        case 'git_commit':
          addUnique(commits, s.args['message'] as String?);
          break;
        case 'read_file':
        case 'list_files':
          reads++;
          break;
        case 'search_code':
          searches++;
          break;
      }
    }
    return AgentActionSummary(
      filesChanged: changed,
      filesDeleted: deleted,
      commandsRun: commands,
      commits: commits,
      filesRead: reads,
      searches: searches,
      failedSteps: failed,
      totalSteps: steps.length,
    );
  }

  bool get hasActions =>
      filesChanged.isNotEmpty ||
      filesDeleted.isNotEmpty ||
      commandsRun.isNotEmpty ||
      commits.isNotEmpty;

  /// One-line headline, e.g. "3 files changed · 2 commands run · 1 commit".
  String get headline {
    final parts = <String>[];
    if (filesChanged.isNotEmpty) parts.add('${filesChanged.length} file${filesChanged.length == 1 ? '' : 's'} changed');
    if (filesDeleted.isNotEmpty) parts.add('${filesDeleted.length} deleted');
    if (commandsRun.isNotEmpty) parts.add('${commandsRun.length} command${commandsRun.length == 1 ? '' : 's'} run');
    if (commits.isNotEmpty) parts.add('${commits.length} commit${commits.length == 1 ? '' : 's'}');
    if (parts.isEmpty) {
      if (filesRead > 0 || searches > 0) {
        parts.add('inspection only — no files were modified');
      } else {
        parts.add('no file actions');
      }
    }
    return parts.join(' · ');
  }
}

/// One file change reported by `git_status`.
class GitFileChange {
  final String path;
  final String status; // M | A | D | ?

  const GitFileChange(this.path, this.status);
}
