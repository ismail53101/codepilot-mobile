import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// "File" button on the Home command bar: opens the Android file picker so
/// the user can attach a code/project file or a ZIP archive to the prompt.
class FileAttachmentButton extends StatelessWidget {
  final ValueChanged<PlatformFile> onFilePicked;
  final ValueChanged<String>? onError;

  /// Compact inline variant for the composer's quiet actions row.
  final bool compact;

  const FileAttachmentButton({
    super.key,
    required this.onFilePicked,
    this.onError,
    this.compact = false,
  });

  /// Code/project file extensions commonly attached to prompts.
  static const _codeExtensions = [
    'zip', // full project archives
    'dart', 'kt', 'java', 'swift', 'm', 'mm', 'h', 'c', 'cpp', 'cs', 'go',
    'rs', 'rb', 'php', 'py', 'js', 'jsx', 'ts', 'tsx', 'json', 'yaml', 'yml',
    'xml', 'html', 'css', 'scss', 'sql', 'sh', 'bat', 'gradle', 'properties',
    'toml', 'md', 'txt', 'csv', 'lock',
  ];

  Future<void> _pick() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _codeExtensions,
        withData: false,
      );
      final file = result?.files.single;
      if (file != null) onFilePicked(file);
    } catch (e) {
      onError?.call('File picker unavailable: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return _QuietAction(
        icon: Icons.attach_file,
        label: 'File',
        onTap: _pick,
      );
    }
    return _ActionChipButton(
      icon: Icons.attach_file,
      label: 'File',
      onTap: _pick,
    );
  }
}

/// "Integrate" entry point on the Home composer: opens the Integrations
/// screen. Visually quiet so it never competes with the Ask/Search action.
class IntegrateButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool compact;

  const IntegrateButton({super.key, required this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return _QuietAction(
        icon: Icons.link,
        label: 'Integrate',
        onTap: onTap,
      );
    }
    return _ActionChipButton(
      icon: Icons.link,
      label: 'Integrate',
      onTap: onTap,
    );
  }
}

/// Quiet icon+label text control used inside the composer's actions row.
class _QuietAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuietAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: AppTheme.muted, size: 18),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

/// Shared visual for the File / Integrate buttons: small rounded navy chip
/// with an icon above a tiny label, matching the reference design.
class _ActionChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChipButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.navyPanel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 62,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: AppTheme.glowAccent, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.text,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
