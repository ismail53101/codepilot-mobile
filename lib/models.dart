/// Data models shared across screens and services.
library models;

import 'dart:convert';

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
    this.requestTimeout = 3600,
    this.streaming = true,
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
        requestTimeout: (j['requestTimeout'] as num?)?.toInt() == 180
            ? 3600
            : ((j['requestTimeout'] as num?)?.toInt() ?? 3600),
        streaming: (j['streaming'] as bool?) ?? true,
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

  /// Stable unique identity for this message. Created once when the message
  /// is added and NEVER mutated afterwards — it keys the message bubble and
  /// its attachment widgets so streaming updates elsewhere in the screen can
  /// rebuild (even the same list slot) without remounting the image element.
  /// Persisted so a restored transcript keeps the same identity too.
  final String id;

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

  ChatMessage({
    required this.role,
    required this.content,
    this.isError = false,
    this.imageDataUrl,
    this.hasImage = false,
    this.attachmentName,
    this.attachmentKind,
    this.toolCalls,
    this.toolCallId,
    String? id,
  }) : id = id ??
            // Time-derived + process-wide counter: unique within the app run
            // and effectively collision-free across restarts.
            'm${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
                '${(++_idSeq).toRadixString(36)}';

  /// Monotonic suffix counter so two messages created in the same
  /// microsecond still get different ids.
  static int _idSeq = 0;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'id': id,
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
        id: j['id'] as String?,
      );
}

/// Collapse runs of identical consecutive persisted system-error cards.
///
/// Older builds appended one error card per failed action/poll, so restored
/// transcripts could contain 5–10 identical "Connect and import…" cards for
/// a single error condition. This keeps the FIRST card of each identical
/// consecutive run and drops the repeats — errors are shown once, honestly.
List<ChatMessage> collapseDuplicateSystemErrors(List<ChatMessage> messages) {
  final out = <ChatMessage>[];
  for (final m in messages) {
    final last = out.isEmpty ? null : out.last;
    if (m.isError &&
        m.role == 'system' &&
        last != null &&
        last.role == 'system' &&
        last.isError &&
        last.content == m.content) {
      continue;
    }
    out.add(m);
  }
  return out;
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
        case 'git_push':
          // Count a commit ONLY if the tool actually succeeded. A failed
          // commit (no linked repository, API error, denied) must never be
          // reported as committed — the summary stays honest.
          if (s.status != AgentStepStatus.failed &&
              (s.detail ?? '').startsWith('OK:')) {
            addUnique(commits, s.args['message'] as String?);
          }
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

// ------------------------------------------------------------------
// Model capability detection + provider error parsing
// ------------------------------------------------------------------

/// What request parameters a model accepts. The app sends the same body
/// shape to every OpenAI-compatible model today; some families (reasoning
/// models, several Anthropic OpenAI-compat gateways) reject sampling
/// controls with HTTP 400, so the request builder must be
/// capability-aware instead of blindly sending `temperature` everywhere.
class ModelCapabilities {
  /// Whether `temperature` / `top_p` may be sent.
  final bool supportsSamplingControls;

  /// Fixed request cap for Anthropic-native `max_tokens` (required field).
  final int maxTokens;

  const ModelCapabilities({
    required this.supportsSamplingControls,
    this.maxTokens = 8192,
  });

  static const ModelCapabilities standard = ModelCapabilities(
      supportsSamplingControls: true);

  static const ModelCapabilities reasoning = ModelCapabilities(
      supportsSamplingControls: false);
}

/// Detect capabilities from the model id. Deliberately conservative:
/// unknown models keep the current behavior (sampling controls sent).
///
/// Known reasoning-first families that reject `temperature`/`top_p` with
/// HTTP 400 ("temperature does not support ..."):
/// - OpenAI o-series (o1/o3/o4…, incl. suffixed variants)
/// - OpenAI gpt-5* reasoning line
/// - Anthropic Claude Opus 4.5+ / extended-thinking line (claude-opus-5.5
///   via OpenAI-compatible gateways 400s on temperature)
ModelCapabilities modelCapabilitiesFor(String modelId) {
  final id = modelId.trim().toLowerCase();
  if (id.isEmpty) return ModelCapabilities.standard;

  // OpenAI o-series: o1, o3-mini, o4-mini-2025-04-16, openai/o1-preview…
  if (RegExp(r'(^|[/:.])o[134]([-._a-z0-9]*)$').hasMatch(id)) {
    return ModelCapabilities.reasoning;
  }
  // gpt-5 reasoning line (gpt-5, gpt-5-mini, openai/gpt-5.2…).
  if (RegExp(r'(^|[/:])gpt-5').hasMatch(id)) {
    return ModelCapabilities.reasoning;
  }
  // Claude Opus 4.5+ / Claude 5+ (claude-opus-5.5, claude-opus-4-5, …).
  // Older claude-3*/claude-4* (non-opus-4-5) keep sampling controls.
  if (RegExp(r'claude-(opus-[5-9]|opus-[4-9]-[5-9]|[5-9])').hasMatch(id) ||
      RegExp(r'claude-opus-4-[5-9]').hasMatch(id)) {
    return ModelCapabilities.reasoning;
  }
  return ModelCapabilities.standard;
}

/// A provider HTTP error decoded into its structured parts. OpenAI-style
/// gateways answer `{"error":{"message","type","param","code"}}`;
/// Anthropic uses `type`/`message` at the top level.
class ProviderErrorDetail {
  final int status;
  final String? code;
  final String? param;
  final String? message;
  final String? type;

  const ProviderErrorDetail({
    required this.status,
    this.code,
    this.param,
    this.message,
    this.type,
  });

  /// Parse from any HTTP response body; never throws.
  static ProviderErrorDetail? fromBody(int status, String body) {
    Map<String, dynamic>? obj;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) obj = decoded;
    } catch (_) {
      obj = null;
    }
    if (obj == null) return null;

    final err = obj['error'];
    if (err is Map) {
      return ProviderErrorDetail(
        status: status,
        code: err['code'] is String ? err['code'] as String : null,
        param: err['param'] is String ? err['param'] as String : null,
        message: err['message'] is String ? err['message'] as String : null,
        type: err['type'] is String ? err['type'] as String : null,
      );
    }
    // Anthropic-style top-level error object.
    if (obj['type'] is String && obj['message'] is String) {
      return ProviderErrorDetail(
        status: status,
        message: obj['message'] as String,
        type: obj['type'] as String,
        code: obj['code'] is String ? obj['code'] as String : null,
      );
    }
    return null;
  }

  /// Human-readable one-liner carrying EVERYTHING the provider disclosed:
  /// status, type, code, param and message. `param` is the key detail for
  /// 400s — it names the exact rejected request field (e.g. `temperature`).
  String describe() {
    final parts = <String>[
      'HTTP $status',
      if (type != null && type!.isNotEmpty) 'type=$type',
      if (code != null && code!.isNotEmpty) 'code=$code',
      if (param != null && param!.isNotEmpty) 'param=$param',
      if (message != null && message!.isNotEmpty) 'message=$message',
    ];
    return parts.join(' · ');
  }
}
