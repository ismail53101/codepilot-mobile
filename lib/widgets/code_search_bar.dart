import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'file_attachment_button.dart';

/// Bottom command bar on the Home screen: one unified, neon-outlined
/// container holding the [FileAttachmentButton], the [CodeSearchBar] input,
/// and the [IntegrateButton] — visually a single component.
///
/// Lives inside a SafeArea + viewInsets-aware wrapper so the keyboard and the
/// Android gesture bar never overlap it.
class CodeSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSubmit;
  final VoidCallback onIntegrateTap;
  final ValueChanged<PlatformFile> onFilePicked;
  final ValueChanged<String>? onFileError;
  final Widget? attachmentStrip;

  const CodeSearchBar({
    super.key,
    required this.controller,
    required this.onSubmit,
    required this.onIntegrateTap,
    required this.onFilePicked,
    this.focusNode,
    this.onFileError,
    this.attachmentStrip,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (attachmentStrip != null) attachmentStrip!,
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.navyPanel,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.glowAccent, width: 1),
                boxShadow: const [
                  BoxShadow(color: AppTheme.glowSoft, blurRadius: 18, spreadRadius: 1),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  FileAttachmentButton(
                    onFilePicked: onFilePicked,
                    onError: onFileError,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SearchField(
                      controller: controller,
                      focusNode: focusNode,
                      onSubmit: onSubmit,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IntegrateButton(onTap: onIntegrateTap),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rounded input field with the bolt icon and circular blue submit.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSubmit;

  const _SearchField({
    required this.controller,
    required this.onSubmit,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        const Icon(Icons.bolt, color: AppTheme.glowAccent, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.send,
            onSubmitted: onSubmit,
            style: const TextStyle(color: AppTheme.text, fontSize: 15),
            cursorColor: AppTheme.glowAccent,
            decoration: const InputDecoration(
              hintText: 'Ask, search, or build anything...',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _SubmitButton(onSubmit: () => onSubmit(controller.text)),
      ]),
    );
  }
}

/// Circular electric-blue search/submit button.
class _SubmitButton extends StatelessWidget {
  final VoidCallback onSubmit;

  const _SubmitButton({required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.glowAccent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onSubmit,
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.search, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// Small removable chip representing an attached file, shown above the bar.
class FileAttachmentChip extends StatelessWidget {
  final PlatformFile file;
  final VoidCallback onRemove;

  const FileAttachmentChip({
    super.key,
    required this.file,
    required this.onRemove,
  });

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isZip = file.extension?.toLowerCase() == 'zip';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.navyPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Icon(
          isZip ? Icons.folder_zip : Icons.description,
          color: AppTheme.glowAccent,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.text, fontSize: 13),
          ),
        ),
        const SizedBox(width: 8),
        if (file.size > 0)
          Text(
            _sizeLabel(file.size),
            style: const TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onRemove,
          child: const Icon(Icons.close, color: AppTheme.muted, size: 18),
        ),
      ]),
    );
  }
}
