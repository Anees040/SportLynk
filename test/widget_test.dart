// The one widget-level test: that the app's root builds and that the wiring no
// screen can assert for itself still holds.
//
// The previous version pumped SportLynkApp and then asserted SportLynkApp was in the
// tree, which can only fail if the constructor throws. What is worth pinning is the
// navigator key: a tray tap is handled by PushService, which has no BuildContext and
// on a cold start has no mounted widget either, so DeepLink.navigatorKey is the only
// route to the navigator. Replacing it with a fresh key breaks every notification tap
// and nothing else, which is exactly the kind of change that ships unnoticed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/app_theme.dart';
import 'package:sportlynk/main.dart';
import 'package:sportlynk/utils/deep_link.dart';

void main() {
  testWidgets('the app root builds one MaterialApp with the shared wiring',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SportLynkApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.navigatorKey, same(DeepLink.navigatorKey));
    expect(app.theme, AppTheme.light);
    expect(app.title, 'SportLynk');
    expect(app.debugShowCheckedModeBanner, isFalse);
  });
}
