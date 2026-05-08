import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/main.dart';

void main() {
  testWidgets('SportLynk app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const SportLynkApp());
    await tester.pump();
    // App should build without errors
    expect(find.byType(SportLynkApp), findsOneWidget);
  });
}
