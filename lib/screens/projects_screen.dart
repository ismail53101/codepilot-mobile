import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Projects screen: every imported project on the device. Opens one, offers
/// deletion, and links to ZIP import. Never shown on the Home screen.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<String> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final projects = await projectService.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  Future<void> _open(String name) async {
    try {
      await projectService.openProject(name);
      if (!mounted) return;
      Navigator.pushNamed(context, '/explorer');
    } on ProjectException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete project?'),
        content: Text('$name and all its files will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.err)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final dir = await projectService.projectsDir();
    final target = Directory(p.join(dir.path, name));
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('Projects'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Import project ZIP',
            onPressed: () => Navigator.pushNamed(context, '/import'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: _projects.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Column(children: [
                          Icon(Icons.folder_open,
                              size: 56, color: AppTheme.muted),
                          SizedBox(height: 12),
                          Text('No projects yet',
                              style: TextStyle(
                                  color: AppTheme.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          SizedBox(height: 6),
                          Text(
                              'Import a project ZIP to start working with CodePilot.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.muted)),
                        ]),
                      ),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _projects.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final name = _projects[index];
                        final isCurrent = projectService.projectName == name;
                        return Container(
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color:
                                    isCurrent ? AppTheme.glowAccent : AppTheme.border),
                          ),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            leading: Icon(
                              isCurrent ? Icons.folder : Icons.folder_open,
                              color: AppTheme.glowAccent,
                            ),
                            title: Text(name,
                                style: const TextStyle(
                                    color: AppTheme.text,
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              isCurrent ? 'Currently open' : 'Tap to open',
                              style: const TextStyle(
                                  color: AppTheme.muted, fontSize: 12),
                            ),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: AppTheme.muted, size: 20),
                                tooltip: 'Delete project',
                                onPressed: () => _delete(name),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: AppTheme.muted),
                            ]),
                            onTap: () => _open(name),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
