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
  bool _projectMode = false;
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

    // Home Search always means conversation search. Project file search is
    // available separately from Project Mode.
    final isSearch = _mode == ComposerMode.search;
    if (isSearch) {
      Navigator.pushNamed(
        context,
        '/search',
        arguments: {'query': text},
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: _ModeSwitcher(
                projectMode: _projectMode,
                onChanged: (project) => setState(() => _projectMode = project),
              ),
            ),
            Expanded(
              child: _projectMode ? _ProjectWorkspace(onOpen: () => Navigator.pushNamed(context, '/projects')) : const SizedBox.shrink(),
            ),
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

class _ModeSwitcher extends StatelessWidget {
  final bool projectMode;
  final ValueChanged<bool> onChanged;

  const _ModeSwitcher({required this.projectMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.navyPanel.withOpacity(.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Expanded(child: _ModeButton(
          icon: Icons.chat_bubble_outline,
          label: 'Chat',
          selected: !projectMode,
          onTap: () => onChanged(false),
        )),
        const SizedBox(width: 3),
        Expanded(child: _ModeButton(
          icon: Icons.code,
          label: 'Project',
          selected: projectMode,
          onTap: () => onChanged(true),
        )),
      ]),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.glowSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: selected ? AppTheme.glowAccent : AppTheme.muted),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: selected ? AppTheme.text : AppTheme.muted, fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ]),
      ),
    );
  }
}

class _ProjectWorkspace extends StatelessWidget {
  final VoidCallback onOpen;

  const _ProjectWorkspace({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final name = projectService.projectName;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.folder_copy_outlined, size: 48, color: AppTheme.glowAccent.withOpacity(.8)),
          const SizedBox(height: 12),
          Text(name == null ? 'Project Mode' : name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(name == null ? 'Open or create a project to work with project files.' : 'Project workspace is ready. Use Chat Mode for normal conversation.', textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.folder_open), label: Text(name == null ? 'Open Projects' : 'Manage Project')),
        ]),
      ),
    );
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
