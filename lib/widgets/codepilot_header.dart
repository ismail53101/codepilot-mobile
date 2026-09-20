import 'package:flutter/material.dart';

import '../theme.dart';
import 'overflow_menu.dart';

/// CodePilot wordmark header: "Code" in light gray/white, "Pilot" in the
/// electric-blue accent, then three compact glowing controls on the right:
///
///   [+] Create Project   [🔑 gold key → API keys]   [⋮ overflow menu]
///
/// No text labels beside the icons. Tapping the 3-dot button opens the
/// [OverflowMenu] directly beneath it.
class CodePilotHeader extends StatelessWidget {
  final List<OverflowMenuItem> menuItems;
  final ValueChanged<String> onMenuSelected;
  final VoidCallback? onCreateProject;
  final VoidCallback? onOpenApiKeys;

  const CodePilotHeader({
    super.key,
    required this.menuItems,
    required this.onMenuSelected,
    this.onCreateProject,
    this.onOpenApiKeys,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 14, 0),
      child: Row(children: [
        // Flexible: the wordmark shrinks (never overflows) on narrow
        // screens where wordmark + 3 controls exceed the width.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              const TextSpan(
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
              maxLines: 1,
            ),
          ),
        ),
        const Spacer(),
        // Three compact controls, evenly spaced, equal proportions.
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (onCreateProject != null) ...[
            _HeaderIconButton(
              key: createButtonKey,
              icon: Icons.add,
              iconColor: AppTheme.text,
              glowColor: AppTheme.glowAccent.withOpacity(.38),
              tooltip: 'Create project',
              onTap: onCreateProject,
            ),
            const SizedBox(width: 10),
          ],
          if (onOpenApiKeys != null) ...[
            _HeaderIconButton(
              key: apiKeyButtonKey,
              icon: Icons.vpn_key_outlined,
              iconColor: AppTheme.gold,
              glowColor: AppTheme.goldSoft,
              tooltip: 'API keys & settings',
              onTap: onOpenApiKeys,
            ),
            const SizedBox(width: 10),
          ],
          // Builder context = the button itself, so the popup anchors here.
          Builder(
            builder: (buttonContext) => _HeaderIconButton(
              key: menuButtonKey,
              icon: Icons.more_vert,
              iconColor: AppTheme.muted,
              glowColor: const Color(0x14FFFFFF),
              tooltip: 'More options',
              onTap: () =>
                  OverflowMenu.show(buttonContext, menuItems, onMenuSelected),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Circular transparent header control with a soft glow behind it.
/// 44dp touch target; the icon stays centered and is never clipped.
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color glowColor;
  final String tooltip;
  final VoidCallback? onTap;

  const _HeaderIconButton({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.glowColor,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        // The glow lives behind the button, not on the icon itself.
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: glowColor, blurRadius: 14, spreadRadius: 1),
          ],
        ),
        child: Material(
          color: AppTheme.navyPanel.withOpacity(.5),
          shape: CircleBorder(
            side: BorderSide(color: AppTheme.border.withOpacity(.55)),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 22, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

/// Key used to find the 3-dot button (tests, scrolling to visibility).
const menuButtonKey = ValueKey('codepilot_overflow_button');

/// Key for the compact Create Project (+) control.
const createButtonKey = ValueKey('codepilot_create_button');

/// Key for the gold API-keys control.
const apiKeyButtonKey = ValueKey('codepilot_key_button');
