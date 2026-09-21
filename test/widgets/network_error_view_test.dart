// The "error with a retry" state, the fourth of the four the project mandates for
// anything that waits on the network.
//
// The widget's whole reason to exist is that a failed request must not be disguised
// as an empty result, so the tests assert the two things that keep them apart: the
// caller's message reaches the user verbatim (it is `ApiClient`'s already-translated
// sentence, not a raw exception), and the one action that can recover — Retry —
// fires the callback it was given. The rest pins the contract every scroll-view
// state in this app shares: it scrolls, so pull-to-refresh still works over an
// error, and it does not clip at a doubled text scale.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/network_error_view.dart';

import 'widget_harness.dart';

void main() {
  testWidgets('shows the message it was given', (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(
        message: 'No internet connection. Check your mobile data or Wi-Fi.',
        onRetry: () async {},
      ),
    );

    expect(
      find.text('No internet connection. Check your mobile data or Wi-Fi.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the default heading and a Retry action', (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(message: 'Something went wrong.', onRetry: () async {}),
    );

    expect(find.text('Could not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a caller can override the heading and icon', (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(
        message: 'The server took too long to respond.',
        title: 'Server is slow',
        icon: Icons.hourglass_empty,
        onRetry: () async {},
      ),
    );

    expect(find.text('Server is slow'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });

  testWidgets('tapping Retry fires the callback exactly once', (tester) async {
    useDeviceSurface(tester);
    var retries = 0;

    await pumpApp(
      tester,
      NetworkErrorView(
        message: 'Could not reach the server.',
        onRetry: () async => retries++,
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('the Retry button clears the minimum tap target', (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(message: 'Could not reach the server.', onRetry: () async {}),
    );

    // The label carries the button, so measuring the button by its text finds the
    // whole tap target rather than the glyphs.
    expectTapTarget(
      tester,
      find.ancestor(
        of: find.text('Retry'),
        matching: find.byType(OutlinedButton),
      ),
    );
  });

  testWidgets('it scrolls, so a pull-to-refresh still works over an error',
      (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(message: 'Could not reach the server.', onRetry: () async {}),
    );

    // A physics that always scrolls is what lets a RefreshIndicator above this widget
    // receive an over-scroll drag when the content is shorter than the viewport.
    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.physics, isA<AlwaysScrollableScrollPhysics>());
  });

  testWidgets('it does not clip at a doubled text scale', (tester) async {
    useDeviceSurface(tester);

    await pumpApp(
      tester,
      NetworkErrorView(
        message: 'No internet connection. Check your mobile data or Wi-Fi.',
        onRetry: () async {},
      ),
      textScale: 2.0,
    );

    expectNoOverflow(tester);
  });
}
