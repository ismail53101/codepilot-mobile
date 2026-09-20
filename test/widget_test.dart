import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:codepilot_mobile/main.dart';
import 'package:codepilot_mobile/widgets/codepilot_header.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // In-memory prefs + a no-op secure-storage channel so screens opened by
    // the tests (Custom API Provider) can load without real plugins.
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  testWidgets('CodePilot app starts with minimal home screen', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    // The wordmark is rendered as a two-tone rich-text span.
    final wordmark = tester.widget<Text>(
        find.byKey(const ValueKey('codepilot_wordmark')));
    final spans = (wordmark.textSpan! as TextSpan).children!;
    expect(spans.length, 2);
    expect((spans[0] as TextSpan).text, 'Code');
    expect((spans[1] as TextSpan).text, 'Pilot');
    // Unified composer: quiet actions row + circular send button.
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Integrate'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    // Compact header controls: Create Project (+), gold API-key, 3-dot menu.
    expect(find.byKey(createButtonKey), findsOneWidget);
    expect(find.byKey(apiKeyButtonKey), findsOneWidget);
    expect(find.byKey(menuButtonKey), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    // No text label beside the plus icon (reference design).
    expect(find.text('Create Project'), findsNothing);
    // No project cards, quick-action grid, or recent-changes list on Home.
    expect(find.text('Import ZIP'), findsNothing);
    expect(find.text('Recent changes'), findsNothing);
  });

  testWidgets('3-dot button opens overflow menu', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    await tester.tap(find.byKey(const ValueKey('codepilot_overflow_button')));
    await tester.pumpAndSettle();
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Search History'), findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Help & Feedback'), findsOneWidget);
    // Subtitles shown for each item.
    expect(find.text('View & manage projects'), findsOneWidget);
    expect(find.text('GitHub, GitLab, etc.'), findsOneWidget);
  });

  testWidgets('tapping outside closes the overflow menu', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    await tester.tap(find.byKey(const ValueKey('codepilot_overflow_button')));
    await tester.pumpAndSettle();
    expect(find.text('App preferences'), findsOneWidget);
    // Barrier tap (center of the empty workspace) dismisses the menu.
    await tester.tapAt(const Offset(60, 400));
    await tester.pumpAndSettle();
    expect(find.text('App preferences'), findsNothing);
  });

  testWidgets('create-project and API-key header controls navigate',
      (tester) async {
    await tester.pumpWidget(const CodePilotApp());

    // '+' opens the existing Create Project flow.
    await tester.tap(find.byKey(createButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('New Project'), findsOneWidget);
    expect(find.text('Choose a template'), findsOneWidget);

    // Back to Home, then the gold key opens the Custom API Provider screen.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(apiKeyButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('Custom API Provider'), findsOneWidget);
  });

  testWidgets('typing a command shows the composer input', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    expect(find.text('Ask CodePilot…'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Find the login screen');
    await tester.pump();
    expect(find.text('Find the login screen'), findsOneWidget);
  });
}
