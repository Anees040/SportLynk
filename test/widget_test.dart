import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/main.dart';

void main() {
  testWidgets('SportLynk app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SportLynkApp());
    expect(find.byType(SportLynkApp), findsOneWidget);
  });
}
