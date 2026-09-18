import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/main.dart';

void main() {
  testWidgets('CodePilot app starts with minimal home screen', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    // The wordmark is rendered as a two-tone rich-text span.
    final wordmark = tester.widget<Text>(
        find.byKey(const ValueKey('codepilot_wordmark')));
    final spans = (wordmark.textSpan! as TextSpan).children!;
    expect(spans.length, 2);
    expect((spans[0] as TextSpan).text, 'Code');
    expect((spans[1] as TextSpan).text, 'Pilot');
    // Bottom command bar pieces are present on Home.
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Integrate'), findsOneWidget);
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

  testWidgets('typing a command shows the search field', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    expect(find.text('Ask, search, or build anything...'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Find the login screen');
    await tester.pump();
    expect(find.text('Find the login screen'), findsOneWidget);
  });
}
