// Snackbar tests.
//
// One property is load-bearing here and it is the `clearSnackBars()` call: a failure
// reported immediately after a success must replace it, not queue behind it. Without
// that line the user reads a stale "Booking confirmed" for three seconds while the
// error that actually happened waits its turn off screen, which is the worst possible
// ordering for the one channel the app uses to surface failures.
//
// The second is that an error is given longer on screen than a success. A success
// confirms something the user just did and can be glanced at; an error has to be read.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/utils/snackbar_util.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  /// A scaffold whose body hands its context to [show], so the util is exercised
  /// through the same ScaffoldMessenger lookup a screen uses.
  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        }),
      ),
    ));
    return captured;
  }

  SnackBar bar(WidgetTester tester) => tester.widget<SnackBar>(find.byType(SnackBar));

  testWidgets('a success is green, carries a tick and shows the message', (tester) async {
    final context = await host(tester);
    SnackbarUtil.showSuccess(context, 'Booking confirmed');
    await tester.pump();

    expect(find.text('Booking confirmed'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(bar(tester).backgroundColor, AppColors.success);
    expect(bar(tester).duration, const Duration(seconds: 3));
  });

  testWidgets('an error is red and stays longer, because it has to be read',
      (tester) async {
    final context = await host(tester);
    SnackbarUtil.showError(context, 'Slot already taken');
    await tester.pump();

    expect(find.text('Slot already taken'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(bar(tester).backgroundColor, AppColors.error);
    expect(bar(tester).duration, const Duration(seconds: 4));
  });

  testWidgets('an informational notice is neither a success nor a failure',
      (tester) async {
    final context = await host(tester);
    SnackbarUtil.showInfo(context, 'Coming soon');
    await tester.pump();

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(bar(tester).backgroundColor, AppColors.primary);
    expect(bar(tester).duration, const Duration(seconds: 3));
  });

  testWidgets('a second message replaces the first rather than queueing behind it',
      (tester) async {
    final context = await host(tester);
    SnackbarUtil.showSuccess(context, 'Booking confirmed');
    await tester.pump();
    expect(find.text('Booking confirmed'), findsOneWidget);

    SnackbarUtil.showError(context, 'Payment failed');
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Booking confirmed'), findsNothing,
        reason: 'a stale success must not outlive the failure that followed it');
    expect(find.text('Payment failed'), findsOneWidget);
    expect(bar(tester).backgroundColor, AppColors.error);
  });

  testWidgets('a long message wraps instead of overflowing the bar', (tester) async {
    final context = await host(tester);
    const long = 'This venue has no open slots in the scheduling window - add slots '
        'first before creating a tournament here';
    SnackbarUtil.showError(context, long);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text(long)).height, greaterThan(30),
        reason: 'a 13px line is under 20 logical pixels tall, so this one wrapped');
  });

  testWidgets('an empty message still shows a bar rather than silently dropping it',
      (tester) async {
    final context = await host(tester);
    SnackbarUtil.showInfo(context, '');
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
  });
}
