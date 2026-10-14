// AppCard is the app's standard elevated section surface. These pin only the
// contract the screens depend on — that it renders its child and that an optional
// onTap fires — not its decoration values, which are deliberately free to be tuned.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/app_card.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders its child', (tester) async {
    await tester.pumpWidget(host(const AppCard(child: Text('hello'))));

    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('a tap fires onTap when one is given', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(AppCard(onTap: () => taps++, child: const Text('tap me'))),
    );

    await tester.tap(find.text('tap me'));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('without onTap it renders and throws nothing', (tester) async {
    await tester.pumpWidget(
      host(const AppCard(padding: EdgeInsets.all(20), child: Text('plain'))),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('plain'), findsOneWidget);
  });
}
