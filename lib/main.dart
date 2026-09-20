import 'package:flutter/material.dart';

import 'agent_service.dart';
import 'api_client.dart';
import 'github_service.dart';
import 'project_service.dart';
import 'providers/provider_router.dart';
import 'providers/provider_store.dart';
import 'screens/api_key_manager_screen.dart';
import 'screens/api_settings_screen.dart';
import 'screens/build_logs_screen.dart';
import 'screens/change_diff_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/export_screen.dart';
import 'screens/explorer_screen.dart';
import 'screens/file_preview_screen.dart';
import 'screens/help_feedback_screen.dart';
import 'screens/home_screen.dart';
import 'screens/github_screen.dart';
import 'screens/import_screen.dart';
import 'screens/integrations_screen.dart';
import 'screens/new_project_screen.dart';
import 'screens/preview_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/search_history_screen.dart';
import 'screens/search_results_screen.dart';
import 'screens/settings_screen.dart';
import 'stores.dart';
import 'theme.dart';
import 'widgets/integration_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore the previously opened project so the agent's workspace context
  // survives app restarts (projectId/projectPath persistence).
  final restored = await projectService.restoreLastProject();
  if (restored) await projectService.loadManifest();
  runApp(const CodePilotApp());
}

/// App-wide singletons (simple service locator).
final projectService = ProjectService();
final settingsStore = SettingsStore();
final apiClient = ApiClient(settingsStore); // legacy single-provider client (settings screen + streaming)
final providerStore = ProviderStore();
final aiRouter = ProviderRouter(store: providerStore, legacy: settingsStore);
final agentService = AgentService(projectService);
final githubService = GitHubService(settingsStore);
final githubProjectStore = GitHubProjectStore(settingsStore);
final searchHistoryStore = SearchHistoryStore();
final chatSessionStore = ChatSessionStore();
final integrationManager = IntegrationManager();
final emailOtpService = EmailOtpService();

class CodePilotApp extends StatelessWidget {
  const CodePilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CodePilot',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/import': (_) => const ImportScreen(),
        '/explorer': (_) => const ExplorerScreen(),
        '/chat': (_) => const ChatScreen(),
        '/search': (_) => const SearchResultsScreen(),
        '/preview': (_) => const FilePreviewScreen(),
        '/live-preview': (_) => const LivePreviewRoute(),
        '/diff': (_) => const ChangeDiffScreen(),
        '/build': (_) => const BuildLogsScreen(),
        '/export': (_) => const ExportScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/api': (_) => const ApiSettingsScreen(),
        '/keys': (_) => const ApiKeyManagerScreen(),
        '/github': (_) => const GitHubScreen(),
        '/projects': (_) => const ProjectsScreen(),
        '/new-project': (_) => const NewProjectScreen(),
        '/history': (_) => const SearchHistoryScreen(),
        '/integrations': (_) => const IntegrationsScreen(),
        '/help': (_) => const HelpFeedbackScreen(),
      },
    );
  }
}
