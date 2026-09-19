import 'package:flutter/material.dart';

import '../agent_loop.dart';
import '../models.dart';
import '../theme.dart';

/// Live agent activity panel: one row per real tool execution.
/// ● running · ✓ done · ✗ failed — tap to expand and see the tool, its
/// arguments, and the real output. Nothing here is fabricated: rows appear
/// only when AgentLoop emits events from actual executions.
///
/// [state] drives the header: the spinner shows ONLY while the task is
/// running/stopping; COMPLETED / FAILED / CANCELLED each render a final
/// banner and stop all motion. The Stop button is active only while work
/// is actually cancellable.
class AgentActivityPanel extends StatelessWidget {
  final List<AgentStep> steps;
  final String? currentThought;
  final AgentTaskState state;
  final String? errorMessage;
  final VoidCallback? onCancel;

  /// One-tap retry after a failed/stopped task (the screen supplies it).
  final VoidCallback? onRetry;

  const AgentActivityPanel({
    super.key,
    required this.steps,
    required this.state,
    this.currentThought,
    this.errorMessage,
    this.onCancel,
    this.onRetry,
  });

  bool get _isRunning => state == AgentTaskState.running;
  bool get _isStopping => state == AgentTaskState.stopping;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty && currentThought == null && state == AgentTaskState.idle) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(children: [
              // Spinner ONLY while there is real work in flight.
              if (_isRunning)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.glowAccent,
                  ),
                )
              else if (_isStopping)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.warn,
                  ),
                )
              else
                Icon(_finalIcon, size: 14, color: _finalColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _headerText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _headerColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (_isRunning && onCancel != null)
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppTheme.err,
                  ),
                  child: const Text('Stop'),
                )
              else if (_isStopping)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Stopping…',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                ),
            ]),
          ),
          if (state == AgentTaskState.failed && errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: SelectableText(
                '✕ $errorMessage',
                style: const TextStyle(color: AppTheme.err, fontSize: 12, height: 1.4),
              ),
            ),
          for (final s in steps) _StepRow(step: s),
          // Manus-style "what the agent did" roll-up, computed ONLY from
          // real executed steps — never fabricated.
          if (state == AgentTaskState.completed)
            _ActionSummaryBlock(summary: AgentActionSummary.fromSteps(steps)),
          // One-tap Retry after a failure or an accidental Stop.
          if ((state == AgentTaskState.failed ||
                  state == AgentTaskState.cancelled) &&
              onRetry != null)
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
                  onPressed: onRetry,
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

  IconData get _finalIcon => switch (state) {
        AgentTaskState.completed => Icons.check_circle,
        AgentTaskState.failed => Icons.cancel,
        AgentTaskState.cancelled => Icons.stop_circle,
        _ => Icons.circle,
      };

  Color get _finalColor => switch (state) {
        AgentTaskState.completed => AppTheme.ok,
        AgentTaskState.failed => AppTheme.err,
        AgentTaskState.cancelled => AppTheme.warn,
        _ => AppTheme.muted,
      };

  String get _headerText => switch (state) {
        AgentTaskState.idle => 'Working…',
        AgentTaskState.running => currentThought == null
            ? 'Working…'
            : _firstLine(currentThought!),
        AgentTaskState.stopping => 'Stopping…',
        AgentTaskState.completed => '✓ Task completed',
        AgentTaskState.failed => '✕ Task failed',
        AgentTaskState.cancelled => '⏹ Task cancelled',
      };

  Color get _headerColor => switch (state) {
        AgentTaskState.completed => AppTheme.ok,
        AgentTaskState.failed => AppTheme.err,
        AgentTaskState.cancelled => AppTheme.warn,
        _ => AppTheme.text,
      };

  static String _firstLine(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
  }
}

/// "What the agent did" — compact action roll-up shown when the task
/// completes, like Manus/Freebuff. Data comes ONLY from the real executed
/// steps ([AgentActionSummary.fromSteps]); nothing is invented.
class _ActionSummaryBlock extends StatelessWidget {
  final AgentActionSummary summary;

  const _ActionSummaryBlock({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.fact_check_outlined,
              size: 14, color: AppTheme.glowAccent),
          const SizedBox(width: 6),
          Expanded(
            child: Text('What the agent did · ${summary.headline}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
        if (summary.commits.isNotEmpty)
          _row(Icons.commit_outlined, 'Committed: ${summary.commits.first}'),
        if (summary.commandsRun.isNotEmpty)
          _row(Icons.terminal,
              'Ran ${summary.commandsRun.length} command${summary.commandsRun.length == 1 ? '' : 's'}'),
        if (summary.filesRead > 0)
          _row(Icons.menu_book_outlined,
              'Read ${summary.filesRead} file${summary.filesRead == 1 ? '' : 's'} / listings'),
        if (summary.searches > 0)
          _row(Icons.search,
              'Searched ${summary.searches} time${summary.searches == 1 ? '' : 's'}'),
        for (final f in summary.filesChanged.take(6))
          _row(Icons.edit_note, f, mono: true),
        for (final f in summary.filesDeleted.take(3))
          _row(Icons.delete_outline, f, mono: true, strike: true),
        if (summary.failedSteps > 0)
          _row(Icons.warning_amber_outlined,
              '${summary.failedSteps} step${summary.failedSteps == 1 ? '' : 's'} failed — see rows above'),
      ]),
    );
  }

  Widget _row(IconData icon, String text,
      {bool mono = false, bool strike = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 13, color: AppTheme.muted),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.muted,
              fontSize: 11.5,
              fontFamily: mono ? 'monospace' : null,
              decoration: strike ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ]),
    );
  }
}

class _StepRow extends StatelessWidget {
  final AgentStep step;

  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (step.status) {
      AgentStepStatus.pending => (Icons.circle_outlined, AppTheme.muted),
      AgentStepStatus.running => (Icons.circle, AppTheme.glowAccent),
      AgentStepStatus.done => (Icons.check_circle, AppTheme.ok),
      AgentStepStatus.failed => (Icons.cancel, AppTheme.err),
    };
    return InkWell(
      onTap: () {
        step.expanded = !step.expanded;
        (context as Element).markNeedsBuild();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                step.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: step.status == AgentStepStatus.failed
                        ? AppTheme.err
                        : AppTheme.text,
                    fontSize: 13),
              ),
            ),
            Text(step.tool,
                style: const TextStyle(color: AppTheme.muted, fontSize: 10.5)),
          ]),
          if (step.expanded) _detail(),
        ]),
      ),
    );
  }

  Widget _detail() {
    final argsBuf = StringBuffer();
    step.args.forEach((k, v) {
      var value = v.toString();
      if (value.length > 200) value = '${value.substring(0, 200)}…';
      argsBuf.writeln('$k: $value');
    });
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(left: 22, top: 4, bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (argsBuf.isNotEmpty)
          Text(argsBuf.toString().trim(),
              style: const TextStyle(
                  color: AppTheme.muted, fontSize: 11, fontFamily: 'monospace')),
        if (step.detail != null) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: SelectableText(
                step.detail!,
                style: const TextStyle(
                    color: AppTheme.text, fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}
