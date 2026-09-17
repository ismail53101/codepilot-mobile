import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../models.dart';
import '../project_service.dart';
import '../theme.dart';

/// Export Project screen: re-zip the modified project and share/save it.
/// The API key never appears here — it lives in secure storage, outside the
/// project directory, and .codepilot_exclude entries are stripped from the ZIP.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  bool _busy = false;
  String? _path;
  String? _error;
  String? _excludeHint;

  Future<void> _export() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _path = null; });
    try {
      final path = await projectService.exportZip();
      final exclude = File('${projectService.root.path}/.codepilot_exclude');
      setState(() {
        _path = path;
        _excludeHint = exclude.existsSync()
            ? 'Excluded per .codepilot_exclude: ${exclude.readAsLinesSync().where((l) => l.trim().isNotEmpty).join(', ')}'
            : null;
        _busy = false;
      });
    } on ProjectException catch (e) {
      setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      setState(() { _error = 'Export failed: $e'; _busy = false; });
    }
  }

  Future<void> _share() async {
    if (_path == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    await Share.shareXFiles([XFile(_path!)], subject: 'CodePilot export', sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    if (projectService.projectName == null) {
      return Scaffold(appBar: AppBar(title: const Text('Export')), body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('No project open.'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pushNamed(context, '/import'), child: const Text('Import Project')),
        ])));
    }
    final nodes = projectService.projectName == null ? <FileNode>[] : projectService.fileTree();
    final fileCount = nodes.where((n) => !n.isDir).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Export Project')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Project: ${projectService.projectName}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$fileCount files · type ${projectService.detectType()}', style: TextStyle(color: AppTheme.muted)),
          const SizedBox(height: 12),
          Text('The exported ZIP contains the current state of every project file, including your AI-applied edits. Your API key is NOT part of the project — it is stored in Android secure storage and can never be exported.',
              style: TextStyle(color: AppTheme.muted, fontSize: 13)),
        ]))),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _busy ? null : _export,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
          label: Text(_busy ? 'Creating ZIP…' : 'Create export ZIP')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: AppTheme.err))),
        if (_path != null) ...[
          const SizedBox(height: 16),
          Card(color: AppTheme.ok.withOpacity(.12), child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('✓ Export ready', style: TextStyle(color: AppTheme.ok, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(_path!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            if (_excludeHint != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_excludeHint!, style: TextStyle(color: AppTheme.muted, fontSize: 12))),
          ]))),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _share, icon: const Icon(Icons.share), label: const Text('Share / save ZIP')),
        ],
      ]),
    );
  }
}
