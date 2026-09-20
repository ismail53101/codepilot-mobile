import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_activity.dart';
import '../agent_loop.dart';
import '../models.dart';
import '../theme.dart';

/// Live agent activity panel — the "I can see what CodePilot is actually
/// doing" surface, in the reference Freebuff/Manus style:
///
///  ┌──────────────────────────────────────────────┐
///  │ ● Thinking · reasoning is streaming above 221s │ ← live status + REAL
///  │ ━━━━━━━━━━━━━━━░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │   elapsed time
///  │ ✓ Inspect project                            │ ← phase rollup over
///  │ ● Implement changes                          │   REAL steps only
///  │ Reasoning                                 ›  │ ← expandable cards,
///  │ >_ $ grep -rn "auth" …            DONE ›     │   every one backed by
///  │ Read files · lib/a.dart, lib/b.dart …     ›  │   an actual execution
///  │ ✓ Task completed                             │
///  │   What the agent did · 2 files changed …     │ ← computed from the
///  │   ─────────────────────────────────────      │   executed steps only
///  └──────────────────────────────────────────────┘
///
/// NOTHING here is fabricated: cards, phases, statistics, elapsed time and
/// verification lines are all derived from [AgentTimelineEntry]s emitted by
/// the agent loop while tools actually ran.
class AgentActivityPanel extends StatefulWidget {
  /// Ordered real timeline: reasoning notes interleaved with tool steps.
  final List<AgentTimelineEntry> timeline;

  final AgentTaskState state;
  final String? errorMessage;

  /// Real task start/end — the ONLY sources for the elapsed label.
  final DateTime? startedAt;
  final DateTime? endedAt;

  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  const AgentActivityPanel({
    super.key,
    required this.timeline,
    required this.state,
    this.errorMessage,
    this.startedAt,
    this.endedAt,
    this.onCancel,
    this.onRetry,
  });

  @override
  State<AgentActivityPanel> createState() => _AgentActivityPanelState();
}

class _AgentActivityPanelState extends State<AgentActivityPanel> {
  /// Ticks once per second WHILE the task runs so the elapsed label uses
  /// the real clock. Stopped the moment the task finalizes — never runs on
  /// restored/finished tasks.
  Timer? _tick;

  /// Card indices the user explicitly toggled (overrides auto-open rules).
  final Set<int> _toggled = {};

  void _toggle(int index) => setState(() {
        _toggled.contains(index) ? _toggled.remove(index) : _toggled.add(index);
      });

  /// "What the agent did" block open state (completed tasks).
  bool _summaryOpen = true;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AgentActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final active = widget.state == AgentTaskState.running ||
        widget.state == AgentTaskState.stopping;
    if (active && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  // ---------------- derived data (all real) ----------------

  List<AgentStep> get _steps =>
      [for (final e in widget.timeline) if (e is StepEntry) e.step];

  AgentStep? get _runningStep {
    for (final s in _steps.reversed) {
      if (s.status == AgentStepStatus.running) return s;
    }
    return null;
  }

  String? get _lastReasoning {
    for (final e in widget.timeline.reversed) {
      if (e is ReasoningEntry) return e.text;
    }
    return null;
  }

  String? get _elapsedLabel {
    final start = widget.startedAt;
    if (start == null) return null;
    final end = widget.endedAt ?? DateTime.now();
    final secs = end.difference(start).inSeconds.clamp(0, 599940);
    return '${secs}s';
  }

  /// Live status line — reflects the loop's actual position.
  String get _statusText => switch (widget.state) {
        AgentTaskState.running => _runningStep?.title ??
            (_lastReasoning != null
                ? 'Thinking · reasoning is streaming above'
                : 'Launching model · Waiting for the first model…'),
        AgentTaskState.stopping => 'Stopping…',
        AgentTaskState.completed => '✓ Task completed',
        AgentTaskState.failed => '✕ Task failed',
        AgentTaskState.cancelled => '⏹ Task cancelled',
        AgentTaskState.idle => 'Working…',
      };

  bool get _active =>
      widget.state == AgentTaskState.running ||
      widget.state == AgentTaskState.stopping;

  @override
  Widget build(BuildContext context) {
    if (widget.timeline.isEmpty && widget.state == AgentTaskState.idle) {
      return const SizedBox.shrink();
    }
    final blocks = groupActivity(widget.timeline);
    final steps = _steps;

    // Auto-open rule: while the task runs, the LATEST reasoning is expanded.
    var lastReasoningBlock = -1;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].type == AgentBlockType.reasoning) lastReasoningBlock = i;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          if (_active)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(2)),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: AppTheme.glowAccent,
                  backgroundColor: AppTheme.border,
                ),
              ),
            ),
          if (widget.state == AgentTaskState.failed &&
              widget.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: SelectableText(
                '✕ ${widget.errorMessage}',
                style: const TextStyle(
                    color: AppTheme.err, fontSize: 12, height: 1.4),
              ),
            ),
          // Phase checklist — only phases touched by REAL steps appear.
          if (_active)
            for (final phase in phasesFromSteps(steps)) _phaseRow(phase),
          for (var i = 0; i < blocks.length; i++)
            _blockCard(
              blocks[i],
              i,
              autoOpen: blocks[i].type == AgentBlockType.reasoning &&
                  _active &&
                  i == lastReasoningBlock,
            ),
          if (widget.state == AgentTaskState.completed)
            _summaryBlock(AgentActionSummary.fromSteps(steps)),
          if (widget.state == AgentTaskState.failed ||
              widget.state == AgentTaskState.cancelled)
            _incompleteBlock(steps),
          if ((widget.state == AgentTaskState.failed ||
                  widget.state == AgentTaskState.cancelled) &&
              widget.onRetry != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.surface,
                    foregroundColor: AppTheme.glowAccent,
                    side: const BorderSide(color: AppTheme.border),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry task'),
                ),
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ---------------- header ----------------

  Widget _header() {
    final running = widget.state == AgentTaskState.running;
    final stopping = widget.state == AgentTaskState.stopping;
    final elapsed = _elapsedLabel;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 10, 8, _active ? 8 : 6),
      child: Row(children: [
        // Motion ONLY while there is real work in flight.
        if (running || stopping)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: running ? AppTheme.glowAccent : AppTheme.warn,
            ),
          )
        else
          Icon(
            switch (widget.state) {
              AgentTaskState.completed => Icons.check_circle,
              AgentTaskState.failed => Icons.cancel,
              AgentTaskState.cancelled => Icons.stop_circle,
              _ => Icons.circle,
            },
            size: 14,
            color: switch (widget.state) {
              AgentTaskState.completed => AppTheme.ok,
              AgentTaskState.failed => AppTheme.err,
              AgentTaskState.cancelled => AppTheme.warn,
              _ => AppTheme.muted,
            },
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _statusText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: switch (widget.state) {
                AgentTaskState.completed => AppTheme.ok,
                AgentTaskState.failed => AppTheme.err,
                AgentTaskState.cancelled => AppTheme.warn,
                _ => AppTheme.text,
              },
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (elapsed != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(elapsed,
                style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500)),
          ),
        if (running && widget.onCancel != null)
          TextButton(
            onPressed: widget.onCancel,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: AppTheme.err,
            ),
            child: const Text('Stop'),
          )
        else if (stopping)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('Stopping…',
                style: TextStyle(color: AppTheme.muted, fontSize: 12)),
          ),
      ]),
    );
  }

  Widget _phaseRow(AgentPhase phase) {
    final (icon, color) = switch (phase.status) {
      AgentStepStatus.pending => (Icons.circle_outlined, AppTheme.muted),
      AgentStepStatus.running => (Icons.circle, AppTheme.glowAccent),
      AgentStepStatus.done => (Icons.check_circle, AppTheme.ok),
      AgentStepStatus.failed => (Icons.cancel, AppTheme.err),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 12, 2),
      child: Row(children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 8),
        Text(phase.label,
            style: TextStyle(
                color: phase.status == AgentStepStatus.failed
                    ? AppTheme.err
                    : AppTheme.text,
                fontSize: 12.5)),
      ]),
    );
  }

  // ---------------- activity cards ----------------

  bool _isOpen(int index, bool autoOpen) =>
      _toggled.contains(index) ? !autoOpen : autoOpen;

  Widget _blockCard(AgentActivityBlock block, int index,
      {required bool autoOpen}) {
    return switch (block.type) {
      AgentBlockType.reasoning => _reasoningCard(block, index, autoOpen),
      AgentBlockType.terminal => _terminalCard(block, index),
      _ => _filesCard(block, index),
    };
  }

  Widget _reasoningCard(AgentActivityBlock block, int index, bool autoOpen) {
    final open = _isOpen(index, autoOpen);
    return InkWell(
      onTap: () => _toggle(index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Reasoning',
                    style: TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    size: 15, color: AppTheme.muted),
              ]),
              if (open && block.reasoning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(
                    block.reasoning!,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 13, height: 1.45),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filesCard(AgentActivityBlock block, int index) {
    final open = _isOpen(index, false);
    final (icon, color) = switch (block.type) {
      AgentBlockType.read => (Icons.menu_book_outlined, AppTheme.muted),
      AgentBlockType.search => (Icons.search, AppTheme.muted),
      AgentBlockType.modify => (Icons.edit_note, AppTheme.glowAccent),
      AgentBlockType.del => (Icons.delete_outline, AppTheme.warn),
      AgentBlockType.move => (Icons.drive_file_move_outlined, AppTheme.glowAccent),
      AgentBlockType.inspect => (Icons.account_tree_outlined, AppTheme.muted),
      _ => (Icons.build_circle_outlined, AppTheme.muted),
    };
    final preview = block.items.isEmpty
        ? ''
        : ' · ${block.items.first}${block.items.length > 1 ? ', …' : ''}';
    return InkWell(
      onTap: () => _toggle(index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 3, 12, 3),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                _statusDot(block.status),
                const SizedBox(width: 8),
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${block.title}$preview',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 12.5),
                  ),
                ),
                if (block.countLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(block.countLabel,
                        style: const TextStyle(
                            color: AppTheme.muted, fontSize: 10.5)),
                  ),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    size: 15, color: AppTheme.muted),
              ]),
              if (open && block.items.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(left: 24, top: 4, bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in block.items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(item,
                              style: const TextStyle(
                                  color: AppTheme.text,
                                  fontSize: 11,
                                  fontFamily: 'monospace')),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _terminalCard(AgentActivityBlock block, int index) {
    final open = _isOpen(index, false);
    final ok = block.status == AgentStepStatus.done;
    final statusLabel = switch (block.status) {
      AgentStepStatus.running => 'RUN',
      AgentStepStatus.done => 'DONE',
      AgentStepStatus.failed => 'FAILED',
      AgentStepStatus.pending => '…',
    };
    return InkWell(
      onTap: () => _toggle(index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: ok
                          ? AppTheme.border
                          : AppTheme.err.withOpacity(.45)),
                ),
                child: Row(children: [
                  const Text('>_',
                      style: TextStyle(
                          color: AppTheme.muted,
                          fontSize: 11,
                          fontFamily: 'monospace')),
                  const SizedBox(width: 6),
                  const Text('$',
                      style: TextStyle(
                          color: AppTheme.text,
                          fontSize: 11.5,
                          fontFamily: 'monospace')),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(block.command ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.text,
                            fontSize: 11.5,
                            fontFamily: 'monospace')),
                  ),
                  const SizedBox(width: 6),
                  Text(statusLabel,
                      style: TextStyle(
                          color: ok ? AppTheme.ok : AppTheme.err,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .5)),
                  Icon(open ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: AppTheme.muted),
                ]),
              ),
              if (open) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(block.command ?? '',
                          style: const TextStyle(
                              color: AppTheme.muted,
                              fontSize: 11,
                              fontFamily: 'monospace')),
                      if (block.exitCode != null && block.exitCode != 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('Exit code: ${block.exitCode}',
                              style: const TextStyle(
                                  color: AppTheme.err, fontSize: 11)),
                        ),
                      if (block.output != null) ...[
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints:
                              const BoxConstraints(maxHeight: 180),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              block.output!,
                              style: const TextStyle(
                                  color: AppTheme.text,
                                  fontSize: 11,
                                  height: 1.35,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusDot(AgentStepStatus status) {
    return switch (status) {
      AgentStepStatus.running => const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
              strokeWidth: 1.6, color: AppTheme.glowAccent),
        ),
      AgentStepStatus.done =>
        const Icon(Icons.check, size: 12, color: AppTheme.ok),
      AgentStepStatus.failed =>
        const Icon(Icons.close, size: 12, color: AppTheme.err),
      AgentStepStatus.pending =>
        const Icon(Icons.circle_outlined, size: 11, color: AppTheme.muted),
    };
  }

  // ---------------- final sections ----------------

  /// "What the agent did" — every line computed from the executed steps.
  Widget _summaryBlock(AgentActionSummary summary) {
    final verifications = verificationFromSteps(_steps);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.ok.withOpacity(.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _summaryOpen = !_summaryOpen),
          child: Row(children: [
            const Icon(Icons.fact_check_outlined,
                size: 14, color: AppTheme.ok),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'What the agent did · ${summary.headline}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
            Icon(_summaryOpen ? Icons.expand_less : Icons.expand_more,
                size: 15, color: AppTheme.muted),
          ]),
        ),
        if (_summaryOpen) ...[
          const SizedBox(height: 6),
          if (summary.commits.isNotEmpty)
            _summaryRow(Icons.commit_outlined,
                'Committed: ${summary.commits.first}'),
          if (summary.commandsRun.isNotEmpty ||
              summary.filesRead > 0 ||
              summary.searches > 0)
            _summaryRow(
                Icons.route_outlined,
                [
                  if (summary.commandsRun.isNotEmpty)
                    'ran ${summary.commandsRun.length} command${summary.commandsRun.length == 1 ? '' : 's'}',
                  if (summary.filesRead > 0)
                    'read ${summary.filesRead} file${summary.filesRead == 1 ? '' : 's'}',
                  if (summary.searches > 0)
                    'searched ${summary.searches} time${summary.searches == 1 ? '' : 's'}',
                ].join(' · ')),
          if (summary.filesChanged.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final f in summary.filesChanged.take(8)) _pathChip(f),
              ],
            ),
          ],
          for (final f in summary.filesDeleted.take(4))
            _summaryRow(Icons.delete_outline, f, strike: true),
          if (verifications.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final v in verifications)
              _summaryRow(Icons.verified_outlined, v.label,
                  color: AppTheme.ok),
          ],
          if (summary.failedSteps > 0)
            _summaryRow(Icons.warning_amber_outlined,
                '${summary.failedSteps} step${summary.failedSteps == 1 ? '' : 's'} failed — see details above',
                color: AppTheme.warn),
        ],
      ]),
    );
  }

  Widget _pathChip(String path) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppTheme.border),
      ),
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text(path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: AppTheme.text,
              fontSize: 10.5,
              fontFamily: 'monospace')),
    );
  }

  Widget _summaryRow(IconData icon, String text,
      {Color? color, bool strike = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 13, color: color ?? AppTheme.muted),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color ?? AppTheme.muted,
              fontSize: 11.5,
              decoration: strike ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ]),
    );
  }

  /// "⚠ Task incomplete" — the honest alternative to a completion banner.
  /// Shows what ACTUALLY finished, what never ran, and why it ended.
  Widget _incompleteBlock(List<AgentStep> steps) {
    final cancelled = widget.state == AgentTaskState.cancelled;
    final doneSteps =
        steps.where((s) => s.status == AgentStepStatus.done).toList();
    final doneSummary = AgentActionSummary.fromSteps(doneSteps);
    final remaining = remainingWork(steps);
    final accent = cancelled ? AppTheme.warn : AppTheme.err;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withOpacity(.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(cancelled ? Icons.stop_circle : Icons.warning_amber_outlined,
              size: 14, color: accent),
          const SizedBox(width: 6),
          Text(cancelled ? 'Task stopped before completion' : 'Task incomplete',
              style: TextStyle(
                  color: accent, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 8),
        const Text('What was completed',
            style: TextStyle(
                color: AppTheme.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        if (doneSteps.isEmpty)
          const _Bullet('Nothing was completed yet — the task ended during inspection.',
              color: AppTheme.muted)
        else ...[
          if (doneSummary.filesChanged.isNotEmpty)
            for (final f in doneSummary.filesChanged.take(6))
              _Bullet(f, mono: true),
          if (doneSummary.filesRead > 0)
            _Bullet(
                'Read ${doneSummary.filesRead} file${doneSummary.filesRead == 1 ? '' : 's'} / listings'),
          if (doneSummary.searches > 0)
            _Bullet(
                'Searched ${doneSummary.searches} time${doneSummary.searches == 1 ? '' : 's'}'),
          if (doneSummary.commandsRun.isNotEmpty)
            _Bullet(
                'Ran ${doneSummary.commandsRun.length} command${doneSummary.commandsRun.length == 1 ? '' : 's'}'),
          if (doneSummary.commits.isNotEmpty)
            _Bullet('Committed: ${doneSummary.commits.first}'),
        ],
        const SizedBox(height: 8),
        const Text('What remains',
            style: TextStyle(
                color: AppTheme.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        if (remaining.isEmpty)
          const _Bullet('Only the final wrap-up — the work itself had finished.',
              color: AppTheme.muted)
        else
          for (final r in remaining) _Bullet(r),
        const SizedBox(height: 8),
        const Text('Reason',
            style: TextStyle(
                color: AppTheme.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        Text(
          widget.errorMessage ??
              (cancelled ? 'Stopped by the user.' : 'Unknown error.'),
          style: TextStyle(color: accent, fontSize: 11.5, height: 1.4),
        ),
      ]),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  final Color? color;
  final bool mono;

  const _Bullet(this.text, {this.color, this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('• ',
            style: TextStyle(color: AppTheme.muted, fontSize: 11)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color ?? AppTheme.text,
              fontSize: 11.5,
              height: 1.35,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
      ]),
    );
  }
}
