import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/main.dart';

void main() {
  testWidgets('CodePilot app starts', (tester) async {
    await tester.pumpWidget(const CodePilotApp());
    expect(find.text('CodePilot'), findsOneWidget);
  });
}
