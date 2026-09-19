import 'package:flutter/material.dart';

import '../theme.dart';
import 'overflow_menu.dart';

/// CodePilot wordmark header: "Code" in light gray/white, "Pilot" in the
/// electric-blue accent, a prominent Create Project action, and a circular
/// 3-dot overflow button on the right. Tapping the button opens the
/// [OverflowMenu] directly beneath it.
class CodePilotHeader extends StatelessWidget {
  final List<OverflowMenuItem> menuItems;
  final ValueChanged<String> onMenuSelected;
  final VoidCallback? onCreateProject;

  const CodePilotHeader({
    super.key,
    required this.menuItems,
    required this.onMenuSelected,
    this.onCreateProject,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      child: Row(children: [
        // Flexible: the wordmark shrinks (never overflows) on narrow
        // screens where wordmark + Create Project + menu exceed the width.
        Flexible(
          child: const Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Code',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                TextSpan(
                  text: 'Pilot',
                  style: TextStyle(
                    color: AppTheme.glowAccent,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
            key: ValueKey('codepilot_wordmark'),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        if (onCreateProject != null)
          // Flexible + FittedBox: shrinks instead of overflowing on small
          // phones where wordmark + action + menu exceed the width.
          Flexible(
            child: GestureDetector(
              onTap: onCreateProject,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(Icons.add_circle_outline,
                        size: 18, color: AppTheme.text),
                    SizedBox(width: 6),
                    Text('Create Project',
                        style: TextStyle(
                            color: AppTheme.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
        // Builder context = the button itself, so the popup anchors here.
        Builder(
          builder: (buttonContext) => IconButton(
            key: menuButtonKey,
            onPressed: () =>
                OverflowMenu.show(buttonContext, menuItems, onMenuSelected),
            icon: const Icon(Icons.more_vert, color: AppTheme.muted, size: 24),
            tooltip: 'More options',
          ),
        ),
      ]),
    );
  }
}

/// Key used to find the 3-dot button (tests, scrolling to visibility).
const menuButtonKey = ValueKey('codepilot_overflow_button');
