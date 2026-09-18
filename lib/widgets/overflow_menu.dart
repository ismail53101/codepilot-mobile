import 'package:flutter/material.dart';

import '../theme.dart';

/// One row of the CodePilot overflow menu.
class OverflowMenuItem {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool dividerBefore;

  const OverflowMenuItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.dividerBefore = false,
  });
}

/// Rounded dark popup menu shown under the header's 3-dot button.
///
/// Positioned so it appears directly below the button, sized to stay fully
/// visible on small screens, with a fade+scale entrance. Tap outside closes.
class OverflowMenu extends StatelessWidget {
  final List<OverflowMenuItem> items;
  final ValueChanged<String> onSelected;

  const OverflowMenu({super.key, required this.items, required this.onSelected});

  /// Popup padding from the screen edges. Keeps the panel on-screen on
  /// narrow/large phones alike.
  static const _edge = 12.0;

  /// Shows the menu anchored below the given [buttonContext] (the 3-dot
  /// button). Returns when the menu is dismissed.
  static Future<void> show(
    BuildContext buttonContext,
    List<OverflowMenuItem> items,
    ValueChanged<String> onSelected,
  ) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
    final buttonPos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonSize = box.size;
    final overlaySize = overlay.size;

    final left = (buttonPos.dx + buttonSize.width - _menuWidth - _edge)
        .clamp(_edge, overlaySize.width - _edge)
        .toDouble();
    // Directly below the button with a small gap.
    var top = buttonPos.dy + buttonSize.height + 8;

    // Panel is taller than the space below the button? Show the bottom of
    // the panel at the button's top so the whole menu stays visible.
    final spaceBelow = overlaySize.height - top - _edge;
    final menuH = menuHeight(items);
    if (menuH > spaceBelow) {
      top = (buttonPos.dy - menuH - 8).clamp(_edge, overlaySize.height - _edge).toDouble();
    }

    return Navigator.of(buttonContext).push(_OverflowMenuRoute(
      top: top,
      left: left,
      items: items,
      onSelected: onSelected,
    ));
  }

  static const _menuWidth = 296.0;

  static double menuHeight(List<OverflowMenuItem> items) {
    var h = 8.0; // vertical padding
    for (var i = 0; i < items.length; i++) {
      h += 64; // item height
      if (items[i].dividerBefore && i > 0) h += 9; // divider + margins
    }
    return h.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _menuWidth,
      constraints: BoxConstraints(maxHeight: menuHeight(items)),
      decoration: BoxDecoration(
        color: AppTheme.navyPanel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            AppTheme.navyPanel,
            AppTheme.surface,
          ],
          stops: const [0.0, 1.0],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < items.length; i++) ...[
            if (items[i].dividerBefore && i > 0)
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                color: AppTheme.border,
              ),
            _MenuRow(item: items[i], onTap: () => onSelected(items[i].id)),
          ],
        ]),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final OverflowMenuItem item;
  final VoidCallback onTap;

  const _MenuRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(item.icon, color: AppTheme.glowAccent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.title,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(item.subtitle,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: AppTheme.muted, size: 20),
          ]),
        ),
      ),
    );
  }
}

/// Page-route wrapper: barrier dismisses the menu, fade+scale animation.
class _OverflowMenuRoute<T> extends PopupRoute<T> {
  final double top;
  final double left;
  final List<OverflowMenuItem> items;
  final ValueChanged<String> onSelected;

  _OverflowMenuRoute({
    required this.top,
    required this.left,
    required this.items,
    required this.onSelected,
  });

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(context, animation, secondaryAnimation) {
    // top/left are overlay coordinates; no SafeArea here or the popup
    // would shift down by the status-bar height.
    return Stack(children: [
      Positioned(
        top: top,
        left: left,
        child: ScaleTransition(
          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: OverflowMenu(items: items, onSelected: onSelected),
          ),
        ),
      ),
    ]);
  }
}
