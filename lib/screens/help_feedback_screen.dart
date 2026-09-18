import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Help & Feedback screen: quick answers, documentation links, and a way to
/// contact support. Opens a separate route from the overflow menu.
class HelpFeedbackScreen extends StatelessWidget {
  const HelpFeedbackScreen({super.key});

  static const _faqs = [
    (
      'How do I add my project?',
      'Tap the File button next to the search bar and pick a ZIP archive, or '
          'open Projects from the ⋮ menu and use Import. The project is '
          'extracted on-device and nothing is uploaded anywhere.'
    ),
    (
      'Where does my API key go?',
      'Settings → Custom API Provider. The key is stored in Android secure '
          'storage (Keystore-backed) and is sent only in the Authorization '
          'header to your provider — never in logs, chats, or exports.'
    ),
    (
      'Which commands can I type in the search bar?',
      'Anything: "Find the login screen", "Fix this error", "Explain this '
          'code", or "Search my project". Search-style requests open Search '
          'Results; everything else goes to the AI chat.'
    ),
    (
      'How do I connect GitHub?',
      'Open Integrations (link icon or ⋮ menu) and tap GitHub. Sign in once '
          'with the secure device flow to import repositories and publish '
          'confirmed changes.'
    ),
  ];

  Future<void> _launch(String uri) async {
    final parsed = Uri.tryParse(uri);
    if (parsed != null) await launchUrl(parsed, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('Help & Feedback'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Frequently asked',
            style: TextStyle(
                color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          for (final faq in _faqs) ...[
            _FaqCard(question: faq.$1, answer: faq.$2),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 12),
          const Text(
            'Get support',
            style: TextStyle(
                color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          _SupportTile(
            icon: Icons.bug_report_outlined,
            title: 'Report a bug',
            subtitle: 'Open an issue on GitHub',
            onTap: () => _launch('https://github.com/codepilot-mobile/issues'),
          ),
          const SizedBox(height: 10),
          _SupportTile(
            icon: Icons.mail_outline,
            title: 'Email support',
            subtitle: 'support@codepilot.app',
            onTap: () => _launch('mailto:support@codepilot.app'),
          ),
          const SizedBox(height: 10),
          _SupportTile(
            icon: Icons.chat_bubble_outline,
            title: 'Community',
            subtitle: 'Ask questions and share feedback',
            onTap: () => _launch('https://github.com/codepilot-mobile/discussions'),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'CodePilot Mobile v1.0.0',
              style: TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FaqCard extends StatelessWidget {
  final String question;
  final String answer;

  const _FaqCard({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          iconColor: AppTheme.glowAccent,
          collapsedIconColor: AppTheme.muted,
          title: Text(question,
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(answer,
                  style:
                      const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SupportTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(children: [
            Icon(icon, color: AppTheme.glowAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.muted),
          ]),
        ),
      ),
    );
  }
}
