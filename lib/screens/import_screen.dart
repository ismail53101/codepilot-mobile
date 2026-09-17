import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../project_service.dart';
import '../theme.dart';

/// Import Project screen: pick a ZIP from Android storage, extract, list.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String? _message;
  bool _isError = false;
  List<String> _projects = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final projects = await projectService.listProjects();
    if (mounted) setState(() => _projects = projects);
  }

  Future<void> _pickAndImport() async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['zip'],
      );
      final path = result?.files.single.path;
      if (path == null) {
        setState(() { _busy = false; _message = 'No file selected.'; _isError = false; });
        return;
      }
      final msg = await projectService.importZip(path);
      await _refresh();
      setState(() { _message = msg; _isError = false; _busy = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        Navigator.pushReplacementNamed(context, '/explorer');
      }
    } on ProjectException catch (e) {
      setState(() { _message = e.message; _isError = true; _busy = false; });
    } catch (e) {
      setState(() { _message = 'Import failed: $e'; _isError = true; _busy = false; });
    }
  }

  Future<void> _open(String name) async {
    try {
      await projectService.openProject(name);
      if (mounted) Navigator.pushReplacementNamed(context, '/explorer');
    } on ProjectException catch (e) {
      setState(() { _message = e.message; _isError = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import Project')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Import from ZIP', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Supported: Flutter, Android, React, Next.js, Python, HTML/CSS/JS — any text project.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: _busy ? null : _pickAndImport,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file),
              label: Text(_busy ? 'Extracting…' : 'Select ZIP file'),
            )),
          ]),
        )),
        if (_message != null) Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: TextStyle(color: _isError ? AppTheme.err : AppTheme.ok)),
        ),
        const SizedBox(height: 16),
        Text('Projects on this device (${_projects.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        for (final name in _projects) Card(child: ListTile(
          leading: const Icon(Icons.folder, color: AppTheme.accent),
          title: Text(name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(name),
        )),
        if (_projects.isEmpty) Padding(
          padding: const EdgeInsets.all(8),
          child: Text('No projects yet. Import a ZIP to get started.', style: TextStyle(color: AppTheme.muted)),
        ),
      ]),
    );
  }
}
