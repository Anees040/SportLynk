import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/stable_refresh_indicator.dart';

import 'widget_harness.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final itemCount in [1, 30]) {
      testWidgets(
        '$platform refreshes $itemCount items without moving the content',
        (tester) async {
          useDeviceSurface(tester);
          final refresh = Completer<void>();
          var refreshCount = 0;
          await pumpApp(
            tester,
            Theme(
              data: ThemeData(platform: platform, useMaterial3: true),
              child: Scaffold(
                appBar: AppBar(title: const Text('Fixed header')),
                body: StableRefreshIndicator(
                  onRefresh: () {
                    refreshCount++;
                    return refresh.future;
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      for (var index = 0; index < itemCount; index++)
                        SizedBox(height: 72, child: Text('Item $index')),
                    ],
                  ),
                ),
              ),
            ),
          );

          final initialContent = tester.getTopLeft(find.text('Item 0'));
          final initialHeader = tester.getTopLeft(find.text('Fixed header'));
          final gesture = await tester.startGesture(
            tester.getCenter(find.text('Item 0')),
          );
          await gesture.moveBy(const Offset(0, 24));
          await tester.pump();
          await gesture.moveBy(const Offset(0, 360));
          await tester.pump();

          expect(tester.getTopLeft(find.text('Item 0')), initialContent);
          expect(tester.getTopLeft(find.text('Fixed header')), initialHeader);
          expect(find.byType(StretchingOverscrollIndicator), findsNothing);
          expect(find.byType(GlowingOverscrollIndicator), findsNothing);

          await gesture.up();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(refreshCount, 1);
          expect(tester.getTopLeft(find.text('Item 0')), initialContent);

          refresh.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
