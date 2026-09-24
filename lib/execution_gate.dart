// ERROR-GATED EXECUTION LIFECYCLE.
//
// One task traverses: INSPECTING → EDITING → VALIDATING → (FIXING loop) →
// COMMITTING → PUSHING → CI RUNNING → (CI FAILED — FIXING loop) →
// CI PASSED → COMPLETED. Success is VERIFIED state, never agent narration.
//
// Everything in this file is deterministic, unit-testable Dart: no network
// access, no Flutter imports.
//
// ---------------------------------------------------------------------------
// 1. Execution phases (the UI state machine)
// ---------------------------------------------------------------------------

/// The visible execution lifecycle. [idle]..[validating] mirror the
/// classic loop; the delivery states exist only when a repo is linked and
/// the task actually asked to deliver (commit/push) or CI already failed.
enum ExecutionPhase {
  idle,
  inspecting,
  editing,
  validating,
  fixing,
  committing,
  pushing,
  verifyingRemote,
  ciRunning,
  ciFailedFixing,
  ciPassed,
  completed,
  failed,
  blocked,
}

extension ExecutionPhaseX on ExecutionPhase {
  bool get isFinal =>
      this == ExecutionPhase.completed ||
      this == ExecutionPhase.failed ||
      this == ExecutionPhase.blocked;

  bool get isDelivery =>
      this == ExecutionPhase.committing ||
      this == ExecutionPhase.pushing ||
      this == ExecutionPhase.verifyingRemote ||
      this == ExecutionPhase.ciRunning ||
      this == ExecutionPhase.ciFailedFixing ||
      this == ExecutionPhase.ciPassed;

  /// Uppercase label exactly as the UI state machine requires.
  String get label => switch (this) {
        ExecutionPhase.idle => 'IDLE',
        ExecutionPhase.inspecting => 'INSPECTING',
        ExecutionPhase.editing => 'EDITING',
        ExecutionPhase.validating => 'VALIDATING',
        ExecutionPhase.fixing => 'FIXING',
        ExecutionPhase.committing => 'COMMITTING',
        ExecutionPhase.pushing => 'PUSHING',
        ExecutionPhase.verifyingRemote => 'VERIFYING REMOTE',
        ExecutionPhase.ciRunning => 'CI RUNNING',
        ExecutionPhase.ciFailedFixing => 'CI FAILED — FIXING',
        ExecutionPhase.ciPassed => 'CI PASSED',
        ExecutionPhase.completed => 'COMPLETED',
        ExecutionPhase.failed => 'FAILED',
        ExecutionPhase.blocked => 'BLOCKED',
      };
}

// ---------------------------------------------------------------------------
// 2. Failure classification (environment limitation vs project failure)
// ---------------------------------------------------------------------------

/// Why a tool/command failed. Drives the loop's recovery policy:
/// - [environmentLimitation]: the sandbox physically lacks the binary /
///   capability. Retrying is pointless; the loop must switch to native
///   project tools (read_file / search_code / patch_file / write_file).
/// - [projectFailure]: the project itself is broken (analyzer, build,
///   tests). The loop must stop, diagnose, fix, and re-validate.
/// - [policyRejection]: the command was refused before execution (safety
///   denylist). Not an environment limitation — the model should rephrase,
///   but repeated refusals must not be retried identically.
enum FailureKind {
  environmentLimitation,
  projectFailure,
  policyRejection,
  notFailure,
}

/// TerminalExecutor result shape: "exit=N\n<output>" (see
/// ToolRegistry._runCommand), plus the registry's error prefixes.
class ParsedCommandResult {
  final int exitCode;
  final String output;
  const ParsedCommandResult(this.exitCode, this.output);
}

/// Parse a run_command tool result into (exitCode, output) without magic
/// offsets. Recognizes:
/// - "exit=126\n..." / "exit=timeout\n..." (registry format)
/// - "ERROR: ..." / "DENIED: ..." (registry error prefixes)
ParsedCommandResult parseCommandResult(String result) {
  final t = result.trim();
  if (t.startsWith('ERROR') || t.startsWith('DENIED')) {
    return ParsedCommandResult(1, t);
  }
  if (t.startsWith('exit=')) {
    final nl = t.indexOf('\n');
    final head = nl < 0 ? t : t.substring(0, nl);
    final codeRaw = head.substring(5).trim();
    final code = codeRaw == 'timeout' ? 124 : int.tryParse(codeRaw) ?? 1;
    final out = nl < 0 ? '' : t.substring(nl + 1);
    return ParsedCommandResult(code, out);
  }
  // No explicit code → success by convention (tool returned plain output).
  return ParsedCommandResult(0, t);
}

/// Classify ANY tool result (run_command or otherwise) for the completion
/// gate. Denials/known rejections are policy, unknown-tool crashes are
/// environment, plain "ERROR" (e.g. missing file, invalid path) is a real
/// project failure, and successes are [notFailure]. [command] (run_command
/// only) enables absent-binary classification.
FailureKind classifyToolResult(String tool, String result,
    {String command = ''}) {
  if (result.startsWith('DENIED')) return FailureKind.policyRejection;
  if (tool == 'run_command') {
    if (isPolicyRejection(result)) return FailureKind.policyRejection;
    final parsed = parseCommandResult(result);
    if (parsed.exitCode == 0) return FailureKind.notFailure;
    return classifyCommandFailure(
      command: command,
      exitCode: parsed.exitCode,
      output: parsed.output.isEmpty ? '(no output)' : parsed.output,
    );
  }
  return FailureKind.projectFailure;
}


/// Extract the first binary name of a shell command for classification.
String firstBinary(String command) {
  final t = command.trim();
  if (t.isEmpty) return '';
  // Strip env-var prefixes: FOO=1 bar baz → bar
  var rest = t;
  while (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S*\s+').hasMatch(rest)) {
    rest = rest.replaceFirst(RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S*\s+'), '');
  }
  // Skip path prefix and take the first token.
  final first = rest.split(RegExp(r'\s+')).first;
  return first.split('/').last;
}

/// Classify a `run_command` failure from its combined output + exit code.
FailureKind classifyCommandFailure({
  required String command,
  required int exitCode,
  required String output,
}) {
  if (exitCode == 0) return FailureKind.notFailure;
  final bin = firstBinary(command);
  final out = output.toLowerCase();
  final notFoundSignals = [
    'not found',
    'no such file or directory',
    'command not found',
    'not executable',
    'permission denied',
    'shell unavailable',
  ];
  for (final s in notFoundSignals) {
    // exit 127/126 with these phrases = the binary/toolchain is absent.
    if (out.contains(s) && (exitCode == 127 || exitCode == 126)) {
      return FailureKind.environmentLimitation;
    }
  }
  // toybox's explicit missing-binary shape ("sh: sed: not found") is an
  // environment limitation at any exit code; a script's own "sh: file: …"
  // error (no ": not found") is NOT and falls through to project failure.
  if (RegExp(r'sh: \S+: not found').hasMatch(out)) {
    return FailureKind.environmentLimitation;
  }
  // Known on-device ABSENT toolchains/binary families (android toybox lacks
  // them). Even without a matching stderr phrase, these names + nonzero exit
  // are an environment limitation, not a project failure.
  const absentBins = {
    'sed', 'head', 'tail', 'wc', 'grep', 'sort', 'uniq', 'cut', 'tr',
    'awk', 'gawk', 'perl', 'python', 'python3', 'pip', 'pip3',
    'node', 'npm', 'npx', 'yarn', 'pnpm', 'bun', 'deno',
    'dart', 'flutter', 'gradle', 'gradlew', 'java', 'javac', 'kotlinc',
    'git', 'curl', 'wget', 'make', 'cmake', 'gcc', 'g++', 'clang', 'tsc',
    'cargo', 'go', 'rustc', 'dotnet', 'php', 'ruby', 'zip', 'unzip',
  };
  if (absentBins.contains(bin)) {
    // In the Android sandbox these are provided by app-native tooling or do
    // not exist at all; a nonzero exit here is an environment limitation.
    // (grep/wc/head/tail exist in some toyboxes — classification still holds
    // because output above already matched "not found".)
    return FailureKind.environmentLimitation;
  }
  // Anything else: the command ran and failed → treat as a project failure.
  return FailureKind.projectFailure;
}

/// Whether a policy-rejected (denylist) run_command should be converted into
/// native-tool guidance instead of surfacing a raw FAILED card.
///
/// Matches BOTH shapes the executor produces: a bare rejection reason and
/// the `exit=126\n<reason>` form (ToolRegistry._runCommand always prefixes
/// the code, so startsWith-only matching never fired in practice).
bool isPolicyRejection(String output) =>
    output.contains('Command rejected for safety:') ||
    output.contains('Shell redirection is not allowed') ||
    output.contains('sleep is not allowed');

/// Native fallbacks for read-only commands the model commonly reaches for.
/// Each maps the ORIGINAL command to an equivalent the loop can run through
/// the registry's project tools — so a failed `sed -n '110,220p' lib/x.dart`
/// becomes a real read_file of that region instead of a dead end.
NativeFallback? nativeFallbackFor(String command) {
  final bin = firstBinary(command);
  final args = command.trim().split(RegExp(r'\s+'));
  String? targetFile;
  for (final a in args.skip(1)) {
    // A file-looking argument: not a flag, not a glob, and not the bare
    // current-directory operands ('.' / './' / '..') find/ls commonly take.
    if (!a.startsWith('-') &&
        a != '.' &&
        a != '..' &&
        !a.startsWith('./') &&
        (a.contains('.') || a.contains('/')) &&
        !a.contains('*')) {
      targetFile = a;
    }
  }
  int? startLine;
  int? endLine;
  final rangeMatch = RegExp(r"'?(\d+),(\d+)'?").firstMatch(command);
  if (rangeMatch != null) {
    startLine = int.tryParse(rangeMatch.group(1)!);
    endLine = int.tryParse(rangeMatch.group(2)!);
  }
  switch (bin) {
    case 'sed':
    case 'cat':
      if (targetFile == null) return null;
      return NativeFallback(
        tool: 'read_file',
        args: {'path': targetFile},
        note: startLine != null
            ? 'showing the whole file — locate lines $startLine-$endLine inside it'
            : null,
      );
    case 'head':
    case 'tail':
      if (targetFile == null) return null;
      return NativeFallback(
        tool: 'read_file',
        args: {'path': targetFile},
        note: bin == 'head'
            ? 'showing the whole file — the head portion is at the top'
            : 'showing the whole file — the tail portion is at the end',
      );
    case 'grep':
      final q = _grepPattern(command);
      if (q == null) return null;
      return NativeFallback(
        tool: 'search_code',
        args: {'query': q, 'regex': 'true'},
        note: targetFile != null
            ? 'search results include $targetFile when it matches'
            : null,
      );
    case 'wc':
      if (targetFile == null) {
        return const NativeFallback(
          tool: 'list_files',
          args: {},
          note: 'project-wide listing replaces wc output',
        );
      }
      return NativeFallback(
        tool: 'read_file',
        args: {'path': targetFile},
        note: 'line counts are not available; the full file is returned',
      );
    case 'find':
    case 'ls':
      // find/ls DIRECTORY listings map to the project tree — a leading path
      // operand becomes the list_files directory argument.
      final dir = _dirOperand(command);
      return NativeFallback(
        tool: 'list_files',
        args: (dir != null && !dir.startsWith('/')) ? {'path': dir} : const {},
        note: 'project-wide listing replaces ls/find output',
      );
    default:
      return null;
  }
}

/// First path operand of a find/ls command: skips '.'/'..' and stops at the
/// first option flag. Returns null when no directory operand is present.
String? _dirOperand(String command) {
  final args = command.trim().split(RegExp(r'\s+'));
  for (final a in args.skip(1)) {
    if (a == '.' || a == '..') continue;
    if (a.startsWith('-')) return null; // options begin; no path operand
    return a;
  }
  return null;
}

String? _grepPattern(String command) {
  final m = RegExp('''['"](.+?)['"]''').firstMatch(command);
  if (m != null) return m.group(1);
  final parts = command.trim().split(RegExp(r'\s+'));
  for (final part in parts.skip(1)) {
    if (!part.startsWith('-')) return part;
  }
  return null;
}

/// One deterministic fallback the loop executes through the tool registry.
class NativeFallback {
  final String tool;
  final Map<String, dynamic> args;

  /// Short guidance appended to the tool result for the model.
  final String? note;
  const NativeFallback({required this.tool, required this.args, this.note});
}

// ---------------------------------------------------------------------------
// 3. Lightweight project validation
// ---------------------------------------------------------------------------

/// One tool step that FAILED and was never resolved. A failure is resolved
/// when the loop auto-recovers it via native tools (environment limitations),
/// when the model corrects course after a policy rejection, or when a later
/// identical call succeeds (project failures). Only UNRESOLVED failures gate
/// completion.
class UnresolvedFailure {
  /// Tool-call id this failure belongs to (the resolution key).
  final String id;
  final String tool;

  /// First line of the real error output — enough to diagnose, no spam.
  final String detail;

  /// Why the step failed (environment limitation vs project failure vs
  /// policy rejection) — drives whether and how it can be resolved.
  final FailureKind kind;
  const UnresolvedFailure(this.id, this.tool, this.detail, this.kind);

  @override
  String toString() => '$tool: $detail';
}

/// Result of validating the workspace after edits.
class ValidationResult {
  final bool ok;

  /// Machine-readable findings; each carries the file it came from when known.
  final List<ValidationIssue> issues;

  /// Human summary rendered in the activity panel / final message.
  final String summary;
  const ValidationResult(this.ok, this.issues, this.summary);
}

class ValidationIssue {
  final String file;
  final String message;
  const ValidationIssue(this.file, this.message);

  @override
  String toString() => file.isEmpty ? message : '$file: $message';
}

/// Braces/brackets/parens balance check for common source files.
/// Tolerates strings, line comments, and block comments so ordinary code
/// containing braces in string literals does not false-positive.
ValidationResult validateSyntax(List<({String path, String content})> files) {
  final issues = <ValidationIssue>[];
  const sourceExt = ['.dart', '.js', '.ts', '.tsx', '.jsx', '.java', '.kt',
    '.swift', '.c', '.h', '.cpp', '.hpp', '.cs', '.go', '.rs', '.php'];
  for (final f in files) {
    final path = f.path.toLowerCase();
    if (!sourceExt.any(path.endsWith)) continue;
    final bal = _balance(f.content);
    if (bal != null) {
      issues.add(ValidationIssue(f.path, bal));
    }
  }
  if (issues.isEmpty) {
    return const ValidationResult(true, [], 'Syntax validation passed.');
  }
  return ValidationResult(
    false,
    issues,
    'Syntax validation failed:\n${issues.map((i) => '• $i').join('\n')}',
  );
}

/// Returns null when balanced; otherwise a human-readable problem.
String? _balance(String src) {
  final pairs = {'}': '{', ')': '(', ']': '['};
  final stack = <String>[];
  var inLineComment = false;
  var inBlockComment = false;
  var inString = false;
  String? stringChar;
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (inLineComment) {
      if (c == '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        i++;
      }
      continue;
    }
    if (inString) {
      if (c == '\\') {
        i++; // skip escaped char
      } else if (c == stringChar) {
        inString = false;
        stringChar = null;
      }
      continue;
    }
    if (c == '/' && next == '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    if (c == "'" || c == '"' || c == '`') {
      inString = true;
      stringChar = c;
      continue;
    }
    if (c == '{' || c == '(' || c == '[') {
      stack.add(c);
    } else if (c == '}' || c == ')' || c == ']') {
      if (stack.isEmpty || stack.last != pairs[c]) {
        return 'unbalanced "$c" (unmatched)';
      }
      stack.removeLast();
    }
  }
  if (stack.isNotEmpty) {
    return 'unclosed "${stack.last}" (${stack.length} unclosed)';
  }
  return null;
}

// ---------------------------------------------------------------------------
// 4. Delivery (commit → push → verify → CI) verification records
// ---------------------------------------------------------------------------

/// Verified delivery state produced by the loop's delivery gate.
class DeliveryRecord {
  /// Local commit sha created by git_commit, when one was made.
  final String? commitSha;

  /// The remote head sha observed AFTER pushing (must equal [commitSha]
  /// for success when a commit was part of the task).
  final String? remoteHeadSha;

  /// CI conclusion for the pushed head: 'success', 'failure', or null when
  /// no workflow exists / CI was not required.
  final String? ciConclusion;

  /// Non-empty when delivery could not be verified.
  final String? problem;
  const DeliveryRecord({
    this.commitSha,
    this.remoteHeadSha,
    this.ciConclusion,
    this.problem,
  });

  bool get committed => commitSha != null && commitSha!.isNotEmpty;
  bool get pushedAndVerified =>
      committed &&
      remoteHeadSha != null &&
      remoteHeadSha!.startsWith(commitSha!);
  bool get ciGreen => ciConclusion == 'success';
  bool get ciRed => ciConclusion == 'failure';
}

// ---------------------------------------------------------------------------
// 5. The hard success gate
// ---------------------------------------------------------------------------

/// Input evidence the completion gate evaluates. Built by the loop from real
/// tool results — never from model narration.
class GateEvidence {
  /// Tool steps that FAILED and were never resolved (see [UnresolvedFailure]).
  final List<UnresolvedFailure> unresolvedFailures;

  /// Validation result after the last edit (null when no edits were made).
  final ValidationResult? validation;

  /// Files the task actually wrote (from agentHistory).
  final List<({String tool, String path, String kind})> writtenFiles;

  /// Delivery outcome when the task involved commit/push.
  final DeliveryRecord? delivery;

  /// Whether the user's task explicitly asked for commit/push/PR.
  final bool deliveryRequested;

  /// Whether a linked GitHub repo exists (delivery possible at all).
  final bool repoLinked;

  /// Whether the repo has any CI workflow (CI check only applies then).
  final bool repoHasWorkflows;

  const GateEvidence({
    this.unresolvedFailures = const [],
    this.validation,
    this.writtenFiles = const [],
    this.delivery,
    this.deliveryRequested = false,
    this.repoLinked = false,
    this.repoHasWorkflows = false,
  });

  /// Evidence copies for tests and repair simulations.
  GateEvidence copyWith({
    List<UnresolvedFailure>? unresolvedFailures,
    ValidationResult? validation,
    List<({String tool, String path, String kind})>? writtenFiles,
    DeliveryRecord? delivery,
    bool? deliveryRequested,
    bool? repoLinked,
    bool? repoHasWorkflows,
  }) =>
      GateEvidence(
        unresolvedFailures: unresolvedFailures ?? this.unresolvedFailures,
        validation: validation ?? this.validation,
        writtenFiles: writtenFiles ?? this.writtenFiles,
        delivery: delivery ?? this.delivery,
        deliveryRequested: deliveryRequested ?? this.deliveryRequested,
        repoLinked: repoLinked ?? this.repoLinked,
        repoHasWorkflows: repoHasWorkflows ?? this.repoHasWorkflows,
      );
}

/// The verdict of the hard success gate.
sealed class GateVerdict {
  const GateVerdict();
}

class GatePassed extends GateVerdict {
  /// Human-readable evidence summary for the final message.
  final String evidence;
  const GatePassed(this.evidence);
}

class GateBlocked extends GateVerdict {
  /// Why completion is refused, exactly.
  final String reason;

  /// Machine-actionable instruction fed back to the model.
  final String nextAction;
  const GateBlocked(this.reason, this.nextAction);
}

/// THE HARD SUCCESS GATE.
///
/// Evaluates real evidence and returns [GatePassed] only when every
/// requirement holds. Any failed step, validation failure, commit failure,
/// push failure, missing remote commit, RED CI, or failed required check
/// produces [GateBlocked] with a concrete next action.
GateVerdict evaluateCompletionGate(GateEvidence e) {
  // 1. Unresolved tool failures block completion. Environment limitations
  //    and policy rejections never reach here (the loop resolves them);
  //    what blocks is a REAL project failure the model did not fix.
  if (e.unresolvedFailures.isNotEmpty) {
    final projectOnes =
        e.unresolvedFailures.where((f) => f.kind == FailureKind.projectFailure);
    final names = (projectOnes.isNotEmpty ? projectOnes : e.unresolvedFailures)
        .take(4)
        .map((f) => '${f.tool}: ${_firstLine(f.detail)}')
        .join('; ');
    return GateBlocked(
      'Actionable project errors remain '
      '(${e.unresolvedFailures.length} failed step'
      '${e.unresolvedFailures.length == 1 ? '' : 's'}: $names).',
      'Diagnose and fix the failed step(s) with the file tools, then '
      'validate again before finishing.',
    );
  }

  // 2. Validation must pass after edits.
  final v = e.validation;
  if (v != null && !v.ok) {
    return GateBlocked(
      'Validation failed: ${_firstLine(v.summary)}',
      'Fix the reported validation issues (patch_file/write_file), then '
      'validate again.',
    );
  }

  // 3. Edits were made but nothing was committed while a repo is linked
  //    and delivery was requested/expected.
  if (e.repoLinked &&
      e.deliveryRequested &&
      e.writtenFiles.isNotEmpty &&
      (e.delivery == null || !e.delivery!.committed)) {
    return GateBlocked(
      'Files were modified but no commit was created.',
      'Run git_commit with a clear message, then continue the delivery '
      'flow (push → CI).',
    );
  }

  // 4. Delivery verification (only when a delivery was attempted).
  final d = e.delivery;
  if (d != null && d.committed && e.repoLinked) {
    // Push happened (or was requested) but remote head does not match.
    if (e.deliveryRequested && !d.pushedAndVerified) {
      if (!d.ciRed) {
        return GateBlocked(
          'The expected remote commit is missing: local commit '
          '${d.commitSha!.substring(0, 8)} is not the branch head '
          '(remote head: ${d.remoteHeadSha ?? 'unknown'}).',
          'Run git_push again, then verify the remote head matches the '
          'commit before finishing.',
        );
      }
    }
    // RED CI blocks completion.
    if (d.ciRed) {
      return GateBlocked(
        'GitHub Actions for the latest commit is RED '
        '(conclusion=failure).',
        'Fetch the CI failure details (ci_status), fix the root cause, '
        'commit and push again, then wait for CI to pass.',
      );
    }
    // CI exists and is still running/pending → not yet verifiable.
    if (e.repoHasWorkflows &&
        e.deliveryRequested &&
        d.ciConclusion == null) {
      return GateBlocked(
        'CI has not reported a conclusion for the pushed commit.',
        'Run ci_status {"wait": true} and only finish after CI passes.',
      );
    }
  }

  // 5. Genuine external blocker (no repo, delivery impossible) — blocked,
  //    not completed.
  if (e.deliveryRequested && !e.repoLinked) {
    return GateBlocked(
      'The task asks for commit/push but no GitHub repository is linked.',
      'Tell the user to connect a repository via Integrations → GitHub, '
      'or finish the task by reporting the local changes only.',
    );
  }

  final bits = <String>[
    if (e.validation != null && e.validation!.ok)
      'validation passed',
    if (e.writtenFiles.isNotEmpty) '${e.writtenFiles.length} file(s) changed',
    if (d?.pushedAndVerified ?? false)
      'commit ${d!.commitSha!.substring(0, 8)} verified on remote',
    if (d?.ciGreen ?? false) 'CI GREEN',
  ];
  return GatePassed(bits.isEmpty ? 'no changes to verify' : bits.join(', '));
}

String _firstLine(String s) {
  final t = s.trim();
  if (t.isEmpty) return '(no detail)';
  final nl = t.indexOf('\n');
  return nl < 0 ? t : t.substring(0, nl);
}

// ---------------------------------------------------------------------------
// 6. CI verdict parsing (shared by the loop's CI-recovery stage)
// ---------------------------------------------------------------------------

/// A completed CI observation for the pushed head.
class CiVerdict {
  final String status;
  final String? conclusion;

  /// The run's head sha — lets the loop confirm the run belongs to ITS push.
  final String? headSha;
  final String? logExcerpt;
  const CiVerdict({
    required this.status,
    this.conclusion,
    this.headSha,
    this.logExcerpt,
  });

  bool get completed => status == 'completed';
  bool get green => completed && conclusion == 'success';
  bool get red => completed && conclusion == 'failure';
}

// ---------------------------------------------------------------------------
// 7. Failure bookkeeping (record / resolve / reclassify)
// ---------------------------------------------------------------------------

/// Deterministic bookkeeping the agent loop uses instead of ad-hoc list
/// surgery. Unit-testable without Flutter or network.
///
/// A step's identity is its tool-call id. The same id is recorded when the
/// step fails and RESOLVED when the loop recovers it (native fallback) or a
/// later retry succeeds — only unresolved failures gate completion.
/// Reclassification (see [reclassifyFailure]) lets a later REAL run_command
/// override an earlier inherited classification.
void recordFailure(
  List<UnresolvedFailure> failures,
  String id,
  UnresolvedFailure failure,
) {
  failures.removeWhere((f) => f.id == id);
  failures.add(failure);
}

void resolveFailure(List<UnresolvedFailure> failures, String id) {
  failures.removeWhere((f) => f.id == id);
}

/// A step whose first failure could not be classified (e.g. "exit=1" with
/// no recognizable output) gets its kind and detail corrected once a
/// definitive observation arrives.
void reclassifyFailure(
  List<UnresolvedFailure> failures,
  String id,
  FailureKind kind, {
  required String detail,
}) {
  for (var i = 0; i < failures.length; i++) {
    if (failures[i].id == id) {
      failures[i] = UnresolvedFailure(id, failures[i].tool, detail, kind);
      return;
    }
  }
}

/// Build the NEXT model instruction after a RED CI run. [logExcerpt] carries
/// the real GitHub log so the model diagnoses the actual failure.
String ciFailureRepairInstruction(
    CiVerdict verdict, String branch, String remoteHead) {
  final log = (verdict.logExcerpt ?? '').trim();
  final logBlock = log.isEmpty
      ? '(log unavailable — diagnose from the run URL)'
      : log.length > 6000
          ? '${log.substring(0, 6000)}\n… (truncated)'
          : log;
  return 'REQUIRED: CI FAILED for commit ${remoteHead.isEmpty ? '(head)' : remoteHead.substring(0, 8)} on branch $branch.\n'
      'Failure log:\n$logBlock\n\n'
      'Fix the root cause in the project files (not the CI system), validate, '
      'git_commit, git_push, then run ci_status {"wait": true} again. Do not '
      'report completion while CI is RED.';
}
