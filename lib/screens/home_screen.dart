import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/code_search_bar.dart';
import '../widgets/codepilot_header.dart';
import '../widgets/overflow_menu.dart';

/// Home screen — intentionally minimal, matching the reference design:
/// CodePilot header with a 3-dot overflow menu, a large empty workspace,
/// and a single unified File + Search + Integrate bar fixed near the bottom.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _command = TextEditingController();
  final _searchFocus = FocusNode();
  ComposerMode _mode = ComposerMode.ask;
  PlatformFile? _attachment;
  String? _attachmentContent;

  String? _readAttachmentContent(PlatformFile file) {
    final path = file.path;
    if (path == null) return null;
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final bytes = f.readAsBytesSync();
      // Skip anything that looks binary (images, binaries, exotic encodings).
      for (final b in bytes.take(512)) {
        if (b < 9 || (b > 13 && b < 32)) return null;
      }
      final content = utf8.decode(bytes, allowMalformed: true);
      return content.length > 12000 ? content.substring(0, 12000) : content;
    } catch (_) {
      return null;
    }
  }

  static const _menuItems = [
    OverflowMenuItem(
      id: 'new_project',
      title: 'New Project',
      subtitle: 'Create a local workspace',
      icon: Icons.note_add_outlined,
    ),
    OverflowMenuItem(
      id: 'projects',
      title: 'Projects',
      subtitle: 'View & manage projects',
      icon: Icons.folder_outlined,
    ),
    OverflowMenuItem(
      id: 'history',
      title: 'Search History',
      subtitle: 'Recent searches',
      icon: Icons.history,
    ),
    OverflowMenuItem(
      id: 'integrations',
      title: 'Integrations',
      subtitle: 'GitHub, GitLab, etc.',
      icon: Icons.hub_outlined,
    ),
    OverflowMenuItem(
      id: 'settings',
      title: 'Settings',
      subtitle: 'App preferences',
      icon: Icons.settings_outlined,
      dividerBefore: true,
    ),
    OverflowMenuItem(
      id: 'help',
      title: 'Help & Feedback',
      subtitle: 'Get support',
      icon: Icons.help_outline,
    ),
  ];

  void _onMenuSelected(String id) {
    switch (id) {
      case 'new_project':
        Navigator.pushNamed(context, '/new-project');
      case 'projects':
        Navigator.pushNamed(context, '/projects');
      case 'history':
        Navigator.pushNamed(context, '/history');
      case 'integrations':
        Navigator.pushNamed(context, '/integrations');
      case 'settings':
        Navigator.pushNamed(context, '/settings');
      case 'help':
        Navigator.pushNamed(context, '/help');
    }
  }

  void _runCommand(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    _searchFocus.unfocus();

    // Record every submitted query for the Search History screen.
    searchHistoryStore.add(text);

    final attachment = _attachment;
    final content = _attachmentContent;
    final attachmentName = attachment?.name;
    setState(() {
      _attachment = null;
      _attachmentContent = null;
    });

    // Explicit mode wins; Ask stays on chat. Search with no open project
    // falls back to chat (nothing to search yet).
    final isSearch = _mode == ComposerMode.search;
    if (isSearch && projectService.projectName != null) {
      Navigator.pushNamed(
        context,
        '/search',
        arguments: attachmentName == null ? text : '$attachmentName\n$text',
      );
      _command.clear();
      return;
    }

    final Object chatArgs;
    if (attachmentName != null && content != null) {
      // The AI receives the real file content, not just the name.
      chatArgs = {
        'query': text,
        'attachmentName': attachmentName,
        'attachmentContent': content,
        'fresh': true,
      };
    } else if (attachmentName != null) {
      chatArgs = {'query': '$attachmentName\n$text', 'fresh': true};
    } else {
      // Fresh: Home always starts a NEW conversation (previous thread is
      // kept in Chats), matching other chatbots' behavior.
      chatArgs = {'query': text, 'fresh': true};
    }
    Navigator.pushNamed(context, '/chat', arguments: chatArgs);
    _command.clear();
  }

  Future<void> _onFilePicked(PlatformFile file) async {
    // ZIPs can go straight into the on-device workspace.
    if (file.extension?.toLowerCase() == 'zip' && file.path != null) {
      try {
        final message = await projectService.importZip(file.path!);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        return;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not import ZIP: $e')));
        return;
      }
    }
    setState(() {
      _attachment = file;
      _attachmentContent = _readAttachmentContent(file);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      resizeToAvoidBottomInset: true,
      body: Stack(children: [
        // Premium dark gradient + subtle ambient blue glow behind everything.
        const _AmbientBackdrop(),
        SafeArea(
          top: true,
          bottom: false,
          child: Column(children: [
            CodePilotHeader(
              menuItems: _menuItems,
              onMenuSelected: _onMenuSelected,
              onCreateProject: () =>
                  Navigator.pushNamed(context, '/new-project'),
              onOpenApiKeys: () => Navigator.pushNamed(context, '/keys'),
            ),
            // Large intentionally empty workspace.
            const Expanded(child: SizedBox.shrink()),
            CodeSearchBar(
              controller: _command,
              focusNode: _searchFocus,
              onSubmit: _runCommand,
              mode: _mode,
              onModeChanged: (m) => setState(() => _mode = m),
              onIntegrateTap: () =>
                  Navigator.pushNamed(context, '/integrations'),
              onFilePicked: _onFilePicked,
              onFileError: (message) => ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(message))),
              attachmentStrip: _attachment == null
                  ? null
                  : FileAttachmentChip(
                      file: _attachment!,
                      onRemove: () => setState(() => _attachment = null),
                    ),
            ),
          ]),
        ),
      ]),
    );
  }

  @override
  void dispose() {
    _command.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

/// Full-bleed ambient background: near-black navy gradient plus two or
/// three faint radial blue glows. Purely decorative (ignores pointers) so
/// it never steals taps from the empty workspace.
class _AmbientBackdrop extends StatelessWidget {
  const _AmbientBackdrop();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: const Stack(fit: StackFit.expand, children: [
        DecoratedBox(
          decoration: BoxDecoration(gradient: AppTheme.homeBackground),
        ),
        // Faint electric-blue haze rising behind the header (top-right).
        Align(
          alignment: Alignment(1.05, -0.9),
          child: _Glow(size: 320, opacity: .10),
        ),
        // Even fainter counter-glow on the left edge.
        Align(
          alignment: Alignment(-1.1, -0.35),
          child: _Glow(size: 260, opacity: .07),
        ),
        // Deep haze settling behind the composer.
        Align(
          alignment: Alignment(0.15, 1.08),
          child: _Glow(size: 360, opacity: .08),
        ),
      ]),
    );
  }
}

class _Glow extends StatelessWidget {
  final double size;
  final double opacity;

  const _Glow({required this.size, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [
          AppTheme.glowAccent.withOpacity(opacity),
          AppTheme.glowAccent.withOpacity(0),
        ]),
      ),
    );
  }
}
