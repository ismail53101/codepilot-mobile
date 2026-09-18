import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'file_attachment_button.dart';

/// How the Home command bar routes a submitted prompt.
enum ComposerMode { ask, search }

/// Bottom composer on the Home screen — ONE unified card, modern
/// AI-assistant layout:
///
///   ┌──────────────────────────────────────┐
///   │ ⚡ Ask CodePilot…                 [↑] │  ← input + primary action
///   │ ──────────────────────────────────── │
///   │ 📎 File · ⚡ Ask · 🔗 Integrate      │  ← quiet secondary row
///   └──────────────────────────────────────┘
///
/// The neon outline + glow stays (CodePilot identity), but the interior is
/// calm: no nested bordered boxes, no competing buttons. [IntegrateButton]
/// and the mode chip are quiet text controls; only the circular send button
/// is a filled action.
class CodeSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSubmit;
  final VoidCallback onIntegrateTap;
  final ValueChanged<PlatformFile> onFilePicked;
  final ValueChanged<String>? onFileError;
  final Widget? attachmentStrip;
  final ComposerMode mode;
  final ValueChanged<ComposerMode> onModeChanged;

  const CodeSearchBar({
    super.key,
    required this.controller,
    required this.onSubmit,
    required this.onIntegrateTap,
    required this.onFilePicked,
    required this.mode,
    required this.onModeChanged,
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
              padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
              decoration: BoxDecoration(
                color: AppTheme.navyPanel,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppTheme.glowAccent, width: 1),
                boxShadow: const [
                  BoxShadow(color: AppTheme.glowSoft, blurRadius: 18, spreadRadius: 1),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _ComposerInput(
                  controller: controller,
                  focusNode: focusNode,
                  onSubmit: onSubmit,
                ),
                Divider(
                  height: 10,
                  thickness: 0.7,
                  color: AppTheme.border.withOpacity(.7),
                ),
                _ComposerActions(
                  onIntegrateTap: onIntegrateTap,
                  onFilePicked: onFilePicked,
                  onFileError: onFileError,
                  mode: mode,
                  onModeChanged: onModeChanged,
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top row: multi-line input with a bolt prefix and one circular submit.
/// Long text wraps up to 5 lines and the card grows with it.
class _ComposerInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSubmit;

  const _ComposerInput({
    required this.controller,
    required this.onSubmit,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.bolt, color: AppTheme.glowAccent, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: AppTheme.text, fontSize: 15, height: 1.35),
              cursorColor: AppTheme.glowAccent,
              decoration: const InputDecoration(
                hintText: 'Ask CodePilot…',
                hintStyle: TextStyle(fontSize: 15),
                border: InputBorder.none,
                isDense: true,
                filled: false,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // The single primary action: circular blue send. Fades in only
          // when there is text, keeping the resting state calm.
          AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: controller.text.trim().isEmpty ? 0.45 : 1.0,
            child: _SendButton(
              enabled: controller.text.trim().isNotEmpty,
              onSubmit: () => onSubmit(controller.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular electric-blue send button (48dp touch target).
class _SendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onSubmit;

  const _SendButton({required this.enabled, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.glowAccent,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: enabled ? onSubmit : null,
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.arrow_upward, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// Bottom row: quiet text+icon controls — File, mode toggle, Integrate.
/// None of them look like raised buttons; they are 44dp+ touch targets.
class _ComposerActions extends StatelessWidget {
  final VoidCallback onIntegrateTap;
  final ValueChanged<PlatformFile> onFilePicked;
  final ValueChanged<String>? onFileError;
  final ComposerMode mode;
  final ValueChanged<ComposerMode> onModeChanged;

  const _ComposerActions({
    required this.onIntegrateTap,
    required this.onFilePicked,
    required this.onFileError,
    required this.mode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      FileAttachmentButton(
        onFilePicked: onFilePicked,
        onError: onFileError,
        compact: true,
      ),
      const SizedBox(width: 4),
      _ModeChip(mode: mode, onChanged: onModeChanged),
      const Spacer(),
      IntegrateButton(onTap: onIntegrateTap, compact: true),
    ]);
  }
}

/// Ask / Search routing toggle — a quiet segmented chip, not a button box.
class _ModeChip extends StatelessWidget {
  final ComposerMode mode;
  final ValueChanged<ComposerMode> onChanged;

  const _ModeChip({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bg.withOpacity(.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _ModeSegment(
          selected: mode == ComposerMode.ask,
          icon: Icons.auto_awesome,
          label: 'Ask',
          onTap: () => onChanged(ComposerMode.ask),
        ),
        _ModeSegment(
          selected: mode == ComposerMode.search,
          icon: Icons.search,
          label: 'Search',
          onTap: () => onChanged(ComposerMode.search),
        ),
      ]),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ModeSegment({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppTheme.glowSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 14,
                color: selected ? AppTheme.glowAccent : AppTheme.muted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppTheme.text : AppTheme.muted,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ]),
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
