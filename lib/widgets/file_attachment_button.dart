import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// "File" button on the Home command bar: opens the Android file picker so
/// the user can attach a code/project file or a ZIP archive to the prompt.
class FileAttachmentButton extends StatelessWidget {
  final ValueChanged<PlatformFile> onFilePicked;
  final ValueChanged<String>? onError;

  const FileAttachmentButton({
    super.key,
    required this.onFilePicked,
    this.onError,
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
    return _ActionChipButton(
      icon: Icons.attach_file,
      label: 'File',
      onTap: _pick,
    );
  }
}

/// "Integrate" button on the Home command bar: opens the Integrations screen.
class IntegrateButton extends StatelessWidget {
  final VoidCallback onTap;

  const IntegrateButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _ActionChipButton(
      icon: Icons.link,
      label: 'Integrate',
      onTap: onTap,
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
