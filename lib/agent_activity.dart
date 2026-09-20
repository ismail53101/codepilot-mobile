import 'models.dart';

/// Structured activity/event layer for the agent.
///
/// REAL ACTION → REAL EVENT → LIVE UI → FINAL SUMMARY.
/// Everything here is DERIVED from actual AgentLoop executions
/// ([AgentStep]s emitted by the tool loop + the model's per-round
/// narration). Nothing is fabricated: if a card, phase, statistic, or
/// verification line appears, a real tool execution produced it.
///
/// The timeline is also serializable so the whole task state (activity,
/// reasoning, progress, errors, final result) persists continuously and
/// survives app restarts / navigating away mid-run.

/// One entry in the ORDERED agent timeline. Reasoning entries interleave
/// with step entries exactly as they happened.
sealed class AgentTimelineEntry {
  const AgentTimelineEntry();

  Map<String, dynamic> toJson();

  static AgentTimelineEntry? fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'reasoning':
        final text = j['text'] as String?;
        if (text == null || text.isEmpty) return null;
        return ReasoningEntry(text);
      case 'step':
        final raw = j['step'];
        if (raw is Map<String, dynamic>) return StepEntry(AgentStep.fromJson(raw));
        return null;
      default:
        return null;
    }
  }
}

/// A concise, user-facing reasoning note emitted by the model between tool
/// rounds ("First I'll inspect the project structure."). This is the
/// model's own action-oriented narration — private chain-of-thought is
/// never exposed (the loop only narrates between tool calls).
class ReasoningEntry extends AgentTimelineEntry {
  final String text;

  const ReasoningEntry(this.text);

  @override
  Map<String, dynamic> toJson() => {'kind': 'reasoning', 'text': text};
}

/// One real tool execution (started → finished) in timeline order.
class StepEntry extends AgentTimelineEntry {
  final AgentStep step;

  const StepEntry(this.step);

  @override
  Map<String, dynamic> toJson() => {'kind': 'step', 'step': step.toJson()};
}

/// Persisted task-activity snapshot. Saved continuously (task start, every
/// finished step, final outcome) so reopening the conversation restores the
/// exact state — activity, reasoning, progress, errors, and result.
class AgentActivitySnapshot {
  final String state; // AgentTaskState.name
  final List<AgentTimelineEntry> entries;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String? error;

  const AgentActivitySnapshot({
    required this.state,
    required this.entries,
    this.startedAt,
    this.endedAt,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'state': state,
        'entries': [for (final e in entries) e.toJson()],
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
        if (error != null) 'error': error,
      };

  static AgentActivitySnapshot fromJson(Map<String, dynamic> j) {
    DateTime? parse(String? s) => s == null ? null : DateTime.tryParse(s);
    return AgentActivitySnapshot(
      state: (j['state'] as String?) ?? 'idle',
      entries: [
        for (final e in (j['entries'] as List?) ?? const [])
          if (e is Map<String, dynamic>)
            if (AgentTimelineEntry.fromJson(e) case final entry?)
              entry,
      ],
      startedAt: parse(j['startedAt'] as String?),
      endedAt: parse(j['endedAt'] as String?),
      error: j['error'] as String?,
    );
  }
}

// ----------------------------------------------------------------------
// Grouped activity cards (the expandable UI cards)
// ----------------------------------------------------------------------

/// What kind of real activity a card represents.
enum AgentBlockType { reasoning, inspect, read, search, modify, del, move, terminal, git, tool }

/// An expandable activity card: consecutive same-kind tool executions are
/// grouped (e.g. 3 read_file calls → one "Read files" card with 3 paths),
/// every terminal command gets its own card. All content is real.
class AgentActivityBlock {
  final AgentBlockType type;

  /// Aggregate status of the member steps (running > failed > done).
  final AgentStepStatus status;

  /// Paths (read/modified/deleted) or queries (search) — the card's items.
  final List<String> items;

  /// Terminal cards: the real command and its real output / exit code.
  final String? command;
  final String? output;
  final int? exitCode;

  /// Reasoning cards: the narration text.
  final String? reasoning;

  final int stepCount;

  const AgentActivityBlock({
    required this.type,
    required this.status,
    this.items = const [],
    this.command,
    this.output,
    this.exitCode,
    this.reasoning,
    this.stepCount = 0,
  });

  String get title => switch (type) {
        AgentBlockType.reasoning => 'Reasoning',
        AgentBlockType.inspect => 'Inspected project structure',
        AgentBlockType.read => 'Read files',
        AgentBlockType.search => 'Searched code',
        AgentBlockType.modify => 'Modified files',
        AgentBlockType.del => 'Deleted files',
        AgentBlockType.move => 'Moved files',
        AgentBlockType.terminal => 'Terminal',
        AgentBlockType.git => 'Git',
        AgentBlockType.tool => 'Tool',
      };

  String get countLabel => switch (type) {
        AgentBlockType.read => '$stepCount file${stepCount == 1 ? '' : 's'} read',
        AgentBlockType.search => '$stepCount search${stepCount == 1 ? '' : 'es'}',
        AgentBlockType.modify ||
        AgentBlockType.del ||
        AgentBlockType.move =>
          '$stepCount file${stepCount == 1 ? '' : 's'} changed',
        _ => '',
      };
}

AgentBlockType _typeFor(String tool) => switch (tool) {
      'list_files' => AgentBlockType.inspect,
      'read_file' => AgentBlockType.read,
      'search_code' => AgentBlockType.search,
      'write_file' || 'create_file' || 'patch_file' => AgentBlockType.modify,
      'delete_file' => AgentBlockType.del,
      'move_file' => AgentBlockType.move,
      'run_command' || 'ci_status' => AgentBlockType.terminal,
      'git_status' || 'git_commit' || 'git_push' || 'create_branch' ||
      'create_pull_request' =>
        AgentBlockType.git,
      _ => AgentBlockType.tool,
    };

AgentStepStatus _aggregateStatus(List<AgentStep> steps) {
  if (steps.any((s) => s.status == AgentStepStatus.running)) {
    return AgentStepStatus.running;
  }
  if (steps.any((s) => s.status == AgentStepStatus.failed)) {
    return AgentStepStatus.failed;
  }
  return AgentStepStatus.done;
}

/// Build the ordered card list from the real timeline. Consecutive
/// same-kind file steps collapse into one card; each terminal command is
/// its own card (like a real terminal log).
List<AgentActivityBlock> groupActivity(List<AgentTimelineEntry> entries) {
  final blocks = <AgentActivityBlock>[];
  var bucketType = AgentBlockType.read;
  var bucket = <AgentStep>[];

  void flush() {
    if (bucket.isEmpty) return;
    blocks.add(AgentActivityBlock(
      type: bucketType,
      status: _aggregateStatus(bucket),
      items: [
        for (final s in bucket)
          switch (bucketType) {
            AgentBlockType.move =>
              '${s.args['source'] ?? ''} → ${s.args['destination'] ?? ''}',
            AgentBlockType.tool => s.title,
            _ => (s.args['path'] ?? s.args['query'] ?? '') as String,
          },
      ].where((s) => s.trim().isNotEmpty).toList(),
      stepCount: bucket.length,
    ));
    bucket = <AgentStep>[];
  }

  for (final entry in entries) {
    if (entry is ReasoningEntry) {
      flush();
      blocks.add(AgentActivityBlock(
        type: AgentBlockType.reasoning,
        status: AgentStepStatus.done,
        reasoning: entry.text,
      ));
      continue;
    }
    final step = (entry as StepEntry).step;
    final type = _typeFor(step.tool);
    if (type == AgentBlockType.terminal) {
      flush();
      blocks.add(_terminalBlock(step));
      continue;
    }
    if (type != bucketType) {
      flush();
      bucketType = type;
    }
    bucket.add(step);
  }
  flush();
  return blocks;
}

/// One terminal card per real command. Exit code and output are parsed from
/// the tool's real result ("exit=N\n<output>" — see ToolRegistry._runCommand).
AgentActivityBlock _terminalBlock(AgentStep step) {
  final raw = step.detail ?? '';
  var exitCode = 0;
  var output = raw;
  if (raw.startsWith('exit=')) {
    final nl = raw.indexOf('\n');
    final head = nl == -1 ? raw : raw.substring(0, nl);
    exitCode = int.tryParse(head.substring(5).trim()) ?? -1;
    output = nl == -1 ? '' : raw.substring(nl + 1);
  } else if (step.status == AgentStepStatus.failed) {
    exitCode = 1;
  }
  return AgentActivityBlock(
    type: AgentBlockType.terminal,
    status: step.status == AgentStepStatus.done && exitCode == 0
        ? AgentStepStatus.done
        : AgentStepStatus.failed,
    command: (step.args['command'] as String?) ?? step.title,
    output: output.trim().isEmpty ? null : output.trim(),
    exitCode: exitCode,
    stepCount: 1,
  );
}

// ----------------------------------------------------------------------
// Task progress (phase rollup over REAL steps)
// ----------------------------------------------------------------------

/// One pipeline phase rolled up from actual tool executions. A phase only
/// APPEARS once real work touched it, and only turns ✓ when its real steps
/// finished.
class AgentPhase {
  final String label;
  final AgentStepStatus status;

  const AgentPhase(this.label, this.status);
}

const _phaseOrder = <(String, Set<String>)>[
  ('Inspect project', {'list_files', 'search_code'}),
  ('Read relevant files', {'read_file'}),
  ('Implement changes', {
    'write_file', 'create_file', 'patch_file', 'delete_file', 'move_file',
  }),
  ('Run commands & checks', {'run_command', 'ci_status'}),
  ('Git operations', {
    'git_status', 'git_commit', 'git_push', 'create_branch', 'create_pull_request',
  }),
];

/// Phases that actually saw activity, in pipeline order, with honest
/// status: running if any member step is in flight, failed if any failed,
/// done only when every member step completed.
List<AgentPhase> phasesFromSteps(List<AgentStep> steps) {
  final phases = <AgentPhase>[];
  for (final (label, tools) in _phaseOrder) {
    final members = steps.where((s) => tools.contains(s.tool)).toList();
    if (members.isEmpty) continue;
    phases.add(AgentPhase(label, _aggregateStatus(members)));
  }
  return phases;
}

/// Honest "What remains" for incomplete tasks — only claims about work
/// that verifiably did not happen: phases with zero real steps, plus phases
/// that were started but never finished ("interrupted").
List<String> remainingWork(List<AgentStep> steps) {
  final remaining = <String>[];
  for (final (label, tools) in _phaseOrder) {
    final members = steps.where((s) => tools.contains(s.tool)).toList();
    if (members.isEmpty) {
      remaining.add(label);
    } else if (members.any((s) => s.status != AgentStepStatus.done)) {
      remaining.add('$label (interrupted)');
    }
  }
  return remaining;
}

// ----------------------------------------------------------------------
// Verification (derived from real run_command steps — never claimed)
// ----------------------------------------------------------------------

/// One verification line: "✓ flutter analyze passed" — only produced when a
/// real command actually ran and its real exit code was 0.
class AgentVerification {
  final String label;
  final bool passed;

  const AgentVerification(this.label, this.passed);
}

List<AgentVerification> verificationFromSteps(List<AgentStep> steps) {
  final out = <AgentVerification>[];
  for (final s in steps) {
    if (s.tool != 'run_command' || s.status != AgentStepStatus.done) continue;
    final cmd = ((s.args['command'] as String?) ?? '').toLowerCase();
    if (cmd.isEmpty) continue;
    final detail = s.detail ?? '';
    final nl = detail.indexOf('\n');
    final exit = detail.startsWith('exit=')
        ? int.tryParse(
            detail.substring(5, nl == -1 ? detail.length : nl).trim())
        : null;
    if (exit != 0) continue; // a failing check is not a verification pass
    String? label;
    if (cmd.contains('analyze')) label = 'Static analysis passed';
    if (cmd.contains('test')) label = 'Tests passed';
    if (cmd.contains('build')) label = 'Build completed';
    if (label != null && !out.any((v) => v.label == label)) {
      out.add(AgentVerification(label, true));
    }
  }
  return out;
}
