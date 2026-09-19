import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// New Project: create a REAL local workspace from a template.
/// GitHub is NOT required — created projects live on-device and the agent
/// works on them exactly like imported ones.
///
/// Two stages:
/// 1. PICK — project name + template cards.
/// 2. CREATING — an animated step timeline driven by REAL creation progress
///    (one tick per file actually written; no fake timers), Manus-style.
class NewProjectScreen extends StatefulWidget {
  const NewProjectScreen({super.key});

  @override
  State<NewProjectScreen> createState() => _NewProjectScreenState();
}

class _NewProjectScreenState extends State<NewProjectScreen> {
  final _name = TextEditingController();
  ProjectTemplate _template = ProjectTemplate.blank;
  bool _creating = false;
  String? _error;

  // Creation-timeline state (real progress from ProjectService).
  final List<_CreationStep> _steps = [];
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the project a name.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
      _steps
        ..clear()
        ..addAll([
          _CreationStep('Preparing workspace')..status = _CreationStepStatus.running,
          _CreationStep('Writing template files'),
          _CreationStep('Registering workspace'),
        ]);
    });
    try {
      final created = await projectService.createProjectFromTemplate(
        name,
        _template,
        onProgress: (done, total, path) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _steps[0].complete();
            _steps[1].status = _CreationStepStatus.running;
            _steps[1].detail = path;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        // Templates with zero files never emit onProgress — complete every
        // step here so the timeline always ends all-green.
        for (final s in _steps) {
          s.complete();
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      Navigator.pop(context, created);
    } on ProjectException catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = 'Could not create the project: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('New Project'),
      ),
      body: SafeArea(
        child: _creating
            ? _CreatingTimeline(
                name: _name.text.trim().isEmpty
                    ? 'project'
                    : _name.text.trim(),
                template: _template,
                steps: _steps,
                done: _done,
                total: _total,
              )
            : _buildPicker(),
      ),
    );
  }

  Widget _buildPicker() {
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: AppTheme.text, fontSize: 16),
              cursorColor: AppTheme.glowAccent,
              decoration: InputDecoration(
                labelText: 'Project name',
                hintText: 'e.g. My Expense App',
                labelStyle: const TextStyle(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppTheme.border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: AppTheme.glowAccent, width: 1.4)),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 20),
            const Text('Choose a template',
                style: TextStyle(
                    color: AppTheme.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Each template creates real files the agent can edit.',
                style: TextStyle(color: AppTheme.muted, fontSize: 12.5)),
            const SizedBox(height: 12),
            for (final t in ProjectTemplate.all)
              _TemplateCard(
                template: t,
                selected: _template.id == t.id,
                onTap: () => setState(() => _template = t),
              ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(children: const [
                Icon(Icons.info_outline,
                    size: 16, color: AppTheme.glowAccent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Created locally on this device — no GitHub needed. '
                    'You can connect a repository later from Integrations.',
                    style: TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                        height: 1.35),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.glowAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _create,
            icon: const Icon(Icons.rocket_launch_outlined, size: 19),
            label: const Text('Create Project',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    ]);
  }
}

// ----------------------------------------------------------------------
// Creation timeline (stage 2)
// ----------------------------------------------------------------------

enum _CreationStepStatus { pending, running, done }

class _CreationStep {
  final String title;
  String? detail;
  _CreationStepStatus status = _CreationStepStatus.pending;

  _CreationStep(this.title);

  void complete() => status = _CreationStepStatus.done;
}

/// Manus-style animated build timeline. Every check that appears here was
/// driven by a real `onProgress` callback from ProjectService — no timers.
class _CreatingTimeline extends StatelessWidget {
  final String name;
  final ProjectTemplate template;
  final List<_CreationStep> steps;
  final int done;
  final int total;

  const _CreatingTimeline({
    required this.name,
    required this.template,
    required this.steps,
    required this.done,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.glowSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.glowAccent.withOpacity(.4)),
              ),
              child: Icon(template.icon, color: AppTheme.glowAccent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('Creating ${template.label}…',
                        style: const TextStyle(
                            color: AppTheme.muted, fontSize: 12.5)),
                  ]),
            ),
          ]),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress == 1.0 ? null : progress,
              minHeight: 5,
              backgroundColor: AppTheme.surface2,
              color: AppTheme.glowAccent,
            ),
          ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('$done / $total files',
                  style: const TextStyle(
                      color: AppTheme.muted, fontSize: 11.5)),
            ),
          const SizedBox(height: 28),
          for (final s in steps) _StepRow(step: s),
          const Spacer(),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final _CreationStep step;

  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final isRunning = step.status == _CreationStepStatus.running;
    final color = switch (step.status) {
      _CreationStepStatus.pending => AppTheme.muted,
      _CreationStepStatus.running => AppTheme.glowAccent,
      _CreationStepStatus.done => AppTheme.ok,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        isRunning
            ? SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: color))
            : Icon(
                step.status == _CreationStepStatus.done
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                size: 16,
                color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title,
                    style: TextStyle(
                        color: step.status == _CreationStepStatus.pending
                            ? AppTheme.muted
                            : AppTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                if (step.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(step.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.muted,
                            fontSize: 11,
                            fontFamily: 'monospace')),
                  ),
              ]),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------------
// Template picker card (stage 1)
// ----------------------------------------------------------------------

class _TemplateCard extends StatelessWidget {
  final ProjectTemplate template;
  final bool selected;
  final VoidCallback onTap;

  const _TemplateCard({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? AppTheme.surface2 : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: selected ? AppTheme.glowAccent : AppTheme.border,
                  width: selected ? 1.4 : 1),
            ),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.glowSoft
                      : AppTheme.bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(template.icon,
                    size: 19,
                    color: selected ? AppTheme.glowAccent : AppTheme.muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(template.label,
                          style: TextStyle(
                              color: AppTheme.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(template.description,
                          style: const TextStyle(
                              color: AppTheme.muted, fontSize: 12)),
                    ]),
              ),
              if (selected)
                const Icon(Icons.check_circle,
                    size: 18, color: AppTheme.glowAccent),
            ]),
          ),
        ),
      ),
    );
  }
}
