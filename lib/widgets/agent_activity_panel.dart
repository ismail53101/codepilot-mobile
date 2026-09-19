import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_loop.dart';
import '../models.dart';
import '../theme.dart';

/// Live agent activity panel: one row per real tool execution.
/// ● running · ✓ done · ✗ failed — tap to expand and see the tool, its
/// arguments, and the real output. Nothing here is fabricated: rows appear
/// only when AgentLoop emits events from actual executions.
class AgentActivityPanel extends StatelessWidget {
  final List<AgentStep> steps;
  final String? currentThought;
  final VoidCallback? onCancel;

  const AgentActivityPanel({
    super.key,
    required this.steps,
    this.currentThought,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty && currentThought == null) return const SizedBox.shrink();
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
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.glowAccent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  currentThought == null ? 'Working…' : _firstLine(currentThought!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (onCancel != null)
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppTheme.err,
                  ),
                  child: const Text('Stop'),
                ),
            ]),
          ),
          for (final s in steps) _StepRow(step: s),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  static String _firstLine(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
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
