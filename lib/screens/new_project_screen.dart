import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// New Project: create a REAL local workspace from a template.
/// GitHub is NOT required — created projects live on-device and the agent
/// works on them exactly like imported ones.
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
    });
    try {
      final created = await projectService.createProjectFromTemplate(
          name, _template);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Created "$created" — workspace ready for the agent.')));
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
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: AppTheme.text),
                  cursorColor: AppTheme.glowAccent,
                  decoration: InputDecoration(
                    labelText: 'Project name',
                    hintText: 'e.g. My Expense App',
                    labelStyle: const TextStyle(color: AppTheme.muted),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 20),
                Text('Template',
                    style: TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .4)),
                const SizedBox(height: 8),
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
                  child: Row(children: [
                    Icon(Icons.info_outline,
                        size: 16, color: AppTheme.glowAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Created locally on this device. GitHub is optional — '
                        'you can connect a repository later from Integrations.',
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
              height: 48,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.glowAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _creating ? null : _create,
                icon: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(_creating ? 'Creating…' : 'Create Project'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

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
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AppTheme.surface2 : AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: selected ? AppTheme.glowAccent : AppTheme.border,
                  width: selected ? 1.4 : 1),
            ),
            child: Row(children: [
              Icon(template.icon,
                  size: 20,
                  color: selected ? AppTheme.glowAccent : AppTheme.muted),
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
