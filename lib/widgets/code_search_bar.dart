import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'file_attachment_button.dart';

/// How the Home command bar routes a submitted prompt.
enum ComposerMode { ask, search }

/// Bottom composer on the Home screen — ONE unified glass card matching the
/// reference layout:
///
///   ╭──────────────────────────────────────────╮
///   │ ⚡  Ask CodePilot…                   (↑)  │  ← input row + blue send
///   │ ──────────────────────────────────────── │  ← hairline divider
///   │ 📎 File │ ✨Ask  🔍Search        🔗Integrate│  ← actions row
///   ╰──────────────────────────────────────────╯
///
/// Thin electric-blue outline, subtle outer glow, dark translucent panel.
/// Only the selected mode pill and the circular send button are filled;
/// everything else stays quiet. The selected mode pill glows blue with an
/// AI-sparkle icon (Ask) / magnifier (Search).
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
        padding: const EdgeInsets.only(left: 14, right: 14, bottom: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (attachmentStrip != null) attachmentStrip!,
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 4),
              decoration: BoxDecoration(
                // Dark translucent glass over the ambient background.
                color: AppTheme.navyPanel.withOpacity(.82),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: AppTheme.glowAccent.withOpacity(.85),
                  width: 1,
                ),
                boxShadow: const [
                  // Subtle neon-blue glow.
                  BoxShadow(
                      color: AppTheme.glowSoft,
                      blurRadius: 24,
                      spreadRadius: 2),
                  // Grounding shadow so the card floats above the page.
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
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
                  color: AppTheme.border.withOpacity(.55),
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
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 15, height: 1.35),
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
          // The single primary action: circular blue send with a soft glow.
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

/// Circular electric-blue send button (48dp touch target) with a neon halo.
class _SendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onSubmit;

  const _SendButton({required this.enabled, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: AppTheme.glowSoft, blurRadius: 14, spreadRadius: 1),
        ],
      ),
      child: Material(
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
      ),
    );
  }
}

/// Bottom row: 📎 File │ mode pill (Ask / Search) … Integrate.
/// A thin vertical divider separates File from the mode pill; Integrate
/// hugs the right edge. End controls shrink (never overflow) on small
/// phones while the mode pill keeps its natural size.
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
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: FileAttachmentButton(
            onFilePicked: onFilePicked,
            onError: onFileError,
            compact: true,
          ),
        ),
      ),
      _VerticalDivider(),
      _ModeChip(mode: mode, onChanged: onModeChanged),
      const Spacer(),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: IntegrateButton(onTap: onIntegrateTap, compact: true),
        ),
      ),
    ]);
  }
}

/// Thin vertical separator between the File button and the mode pill.
class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: AppTheme.border.withOpacity(.8),
    );
  }
}

/// Ask / Search routing toggle. The ACTIVE pill is filled electric blue
/// with a subtle glow; the inactive one stays quiet gray text.
class _ModeChip extends StatelessWidget {
  final ComposerMode mode;
  final ValueChanged<ComposerMode> onChanged;

  const _ModeChip({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
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
    ]);
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
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppTheme.glowAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            boxShadow: selected
                ? const [
                    BoxShadow(
                        color: AppTheme.glowSoft,
                        blurRadius: 12,
                        spreadRadius: 1),
                  ]
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 14,
                color: selected ? Colors.white : AppTheme.muted),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : AppTheme.muted,
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
        border: Border.all(color: AppTheme.glowAccent.withOpacity(.4)),
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
