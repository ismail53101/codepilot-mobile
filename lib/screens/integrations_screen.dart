import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/integration_manager.dart';

/// Integrations screen: connect/disconnect external providers (GitHub,
/// GitLab, Bitbucket, Google Drive, Dropbox, plus user-defined ones).
/// Architecture is extensible via [IntegrationManager].
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyBg,
        title: const Text('Integrations'),
      ),
      body: AnimatedBuilder(
        animation: integrationManager,
        builder: (context, _) {
          final integrations = integrationManager.all;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Connect CodeFexa Mobile to your repositories and cloud storage. '
                'Connected providers unlock import and export from the Home command bar.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              for (final integration in integrations) ...[
                IntegrationCard(
                  integration: integration,
                  connected: integrationManager.isConnected(integration.id),
                  onTap: integration.available ? () => _toggle(integration) : null,
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              Center(
                child: OutlinedButton.icon(
                  onPressed: _addCustom,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add integration'),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'More integrations coming soon',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggle(Integration integration) async {
    if (!integration.available) return;
    if (integration.id == 'github') {
      // GitHub has a real flow (OAuth device flow) in this app already.
      if (!mounted) return;
      Navigator.pushNamed(context, '/github');
      return;
    }
    final connected = integrationManager.isConnected(integration.id);
    await integrationManager.setConnected(integration.id, !connected);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '${integration.name} ${connected ? 'disconnected' : 'connected'}.'),
    ));
  }

  Future<void> _addCustom() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Add integration'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Provider name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await integrationManager.addCustom(name);
  }
}
