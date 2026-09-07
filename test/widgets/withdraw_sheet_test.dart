// WithdrawSheet: the one screen in the app that moves a player's money out, and the
// several places where a convenience would become a way to lose track of it.
//
// The money timing is the contract worth protecting. The amount leaves the available
// balance the moment the request is made, not when the payout completes, because
// otherwise a player could spend money they had already asked to withdraw. That is not
// obvious from the outside — the wallet card simply drops — so the sheet has to say it in
// words, on both faces, and those sentences are asserted verbatim. A payout that silently
// deducts is indistinguishable from a bug report.
//
// Only one withdrawal may be in flight at a time, and that rule lives in a partial unique
// index in the database rather than in this widget. So the sheet has two entirely
// different faces depending on what the server says is pending, and the tests drive both
// from the envelope rather than from any local flag. The 409 path is the interesting one:
// when another request wins the race for the single pending slot, the sheet must reload
// and show that request instead of leaving a form that can only fail again.
//
// The Cancel button on the pending face is not a nicety. Without it a single test
// withdrawal locks the feature for a whole settlement window, and the settlement window
// is configurable, which is why the sheet reads the server's `settleMinutes` instead of
// printing "24 hours" — a demo running with a short window must not promise a day.
//
// Client-side validation is asserted for the message it produces, not as a security
// boundary: the same four rules are enforced again by the server because the balance can
// change between the two checks. What matters here is that each rejection names the
// specific number the player needs, and that none of them reach the network — a request
// that was going to be refused is a slower way of saying nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/withdraw_sheet.dart';

import '../services/http_seam.dart';
import 'widget_harness.dart';

/// One pending withdrawal as `GET /api/wallet/withdrawals` returns it — snake_case,
/// straight out of SQL.
Map<String, dynamic> pending({
  String id = 'w1',
  num amount = 1500,
  String method = 'easypaisa',
  String number = '03001234567',
  String? requestedAt = '2026-03-18T09:30:00Z',
}) =>
    {
      'id': id,
      'amount': amount,
      'method': method,
      'account_number': number,
      'requested_at': requestedAt,
    };

/// The envelope the sheet loads on open.
Map<String, dynamic> withdrawals({
  Map<String, dynamic>? inFlight,
  num minAmount = 200,
  int settleMinutes = 24 * 60,
}) =>
    {
      'pending': inFlight,
      'minAmount': minAmount,
      'settleMinutes': settleMinutes,
    };

void main() {
  tearDown(resetApiClient);

  /// Pumps the sheet directly rather than through `showModalBottomSheet`, so no
  /// transition has to be settled before a tap lands. With [resolve] false the frame is
  /// taken before the reply is rendered, which is the only way to see the spinner.
  Future<void> pumpSheet(
    WidgetTester tester, {
    double available = 5000,
    bool resolve = true,
    double textScale = 1.0,
  }) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: Colors.white,
        body: WithdrawSheet(token: 'tok-1', available: available),
      ),
      textScale: textScale,
    );
    if (resolve) await tester.pump();
  }

  group('opening the sheet', () {
    testWidgets('a spinner stands in until the server answers', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester, resolve: false);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Withdraw Funds'), findsNothing,
            reason: 'the form must not be drawn before it is known whether one is pending');
      });
    });

    testWidgets('the token goes out as a bearer on the withdrawals route',
        (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        expect(api.endpoint(), '/wallet/withdrawals');
        expect(api.method(), 'GET');
        expect(api.token(), 'tok-1');
      });
    });

    testWidgets('with nothing pending the form is shown', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester, available: 5000);
        expect(find.text('Withdraw Funds'), findsOneWidget);
        expect(find.text('Available to withdraw: PKR 5000'), findsOneWidget);
        expect(find.text('Request Withdrawal'), findsOneWidget);
        expect(find.text('Withdrawal in Progress'), findsNothing);
      });
    });

    // The pending face is chosen by the envelope, never by a local flag, so a request
    // made on another device is visible here too.
    testWidgets('a withdrawal already in flight replaces the form entirely',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Withdrawal in Progress'), findsOneWidget);
        expect(find.text('Request Withdrawal'), findsNothing,
            reason: 'a second request cannot succeed, so it is not offered');
        expect(find.text('Cancel Withdrawal'), findsOneWidget);
      });
    });
  });

  group('when the withdrawals cannot be loaded', () {
    testWidgets('the server\'s own sentence is shown', (tester) async {
      final api = FakeApi()..fail('Payouts are paused for maintenance.');
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Payouts are paused for maintenance.'), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });

    // A dead server and a missing `adb reverse` are the same failure to the widget.
    // ApiClient translates the transport failure into a sentence of its own before the
    // sheet sees it, so the widget's `Could not load your withdrawals.` fallback is
    // reached only by an envelope that carries no message at all.
    testWidgets('an unreachable server falls back to a sentence of its own',
        (tester) async {
      final api = FakeApi()..offline();
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Could not reach the server. Make sure it is running.'),
            findsOneWidget);
      });
    });

    // Pinned as it behaves, not as it should: the load failure clears the spinner and
    // shows the sentence, but the form is drawn beneath it with defaults, so the only
    // way to retry is to close and reopen the sheet. The project's four-states rule
    // wants a Retry here — see lib/widgets/withdraw_sheet.dart:98.
    testWidgets('there is no retry, only the form beneath the message',
        (tester) async {
      final api = FakeApi()..fail('Payouts are paused for maintenance.');
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Retry'), findsNothing);
        expect(find.text('Request Withdrawal'), findsOneWidget);
        expect(api.sent.length, 1);
      });
    });
  });

  group('what the player is told about the timing', () {
    // The deduction is immediate and the wallet card drops straight away, so the sheet
    // has to say so or the drop reads as a bug.
    testWidgets('the form says the money leaves immediately', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        expect(
          find.text('The amount leaves your available balance immediately and is paid '
              'out within 24 hours. You can cancel any time before it completes.'),
          findsOneWidget,
        );
      });
    });

    testWidgets('the pending face says it has already left', (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      await api.run(() async {
        await pumpSheet(tester);
        expect(
          find.text('The amount has already left your available balance. Payout '
              'completes within 24 hours. Cancel to put it straight back in your wallet.'),
          findsOneWidget,
        );
      });
    });

    // A demo running with a short settlement window must not promise a day.
    testWidgets('a short window is described in minutes, not as 24 hours',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(settleMinutes: 2));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.textContaining('within 2 minutes'), findsOneWidget);
        expect(find.textContaining('24 hours'), findsNothing);
      });
    });

    testWidgets('a single minute is not pluralised', (tester) async {
      final api = FakeApi()..ok(withdrawals(settleMinutes: 1));
      await api.run(() async {
        await pumpSheet(tester);
        // The full stop is part of the assertion: without it "1 minutes" would pass.
        expect(find.textContaining('within 1 minute.'), findsOneWidget);
      });
    });

    testWidgets('a single hour is not pluralised', (tester) async {
      final api = FakeApi()..ok(withdrawals(settleMinutes: 60));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.textContaining('within 1 hour'), findsOneWidget);
      });
    });

    testWidgets('a part hour carries its remainder', (tester) async {
      final api = FakeApi()..ok(withdrawals(settleMinutes: 90));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.textContaining('within 1 hour 30 min'), findsOneWidget);
      });
    });

    // A missing figure must not become "0 minutes"; the fallback is the real default.
    testWidgets('a missing window falls back to the documented default',
        (tester) async {
      final api = FakeApi()..ok({'pending': null});
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.textContaining('within 24 hours'), findsOneWidget);
      });
    });
  });

  group('a balance too small to withdraw', () {
    // Escrow is the usual reason, and naming it is the difference between a limit and
    // a bug: the money is visibly in the wallet card and cannot be taken out.
    testWidgets('the minimum and the escrow reason are both named', (tester) async {
      final api = FakeApi()..ok(withdrawals(minAmount: 200));
      await api.run(() async {
        await pumpSheet(tester, available: 150);
        expect(
          find.text('You need at least PKR 200 in available balance to withdraw. '
              'Money held in escrow for active bookings cannot be withdrawn until '
              'those bookings finish.'),
          findsOneWidget,
        );
      });
    });

    testWidgets('no form is offered when it could only be refused', (tester) async {
      final api = FakeApi()..ok(withdrawals(minAmount: 200));
      await api.run(() async {
        await pumpSheet(tester, available: 150);
        expect(find.text('Request Withdrawal'), findsNothing);
        expect(find.byType(TextField), findsNothing);
      });
    });

    // The server's own minimum governs, not a constant in the widget.
    testWidgets('a server minimum below the balance opens the form', (tester) async {
      final api = FakeApi()..ok(withdrawals(minAmount: 100));
      await api.run(() async {
        await pumpSheet(tester, available: 150);
        expect(find.text('Request Withdrawal'), findsOneWidget);
      });
    });
  });

  group('the amount the player may ask for', () {
    FakeApi formApi({num minAmount = 200}) =>
        FakeApi()..ok(withdrawals(minAmount: minAmount));

    testWidgets('the field states both bounds', (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester, available: 5000);
        expect(find.text('Min 200 · max 5000'), findsOneWidget);
      });
    });

    // Typing the exact balance by hand is the easiest way to land on an off-by-one
    // rejection, so the balance is offered as a button.
    testWidgets('withdraw-all fills in exactly the available balance',
        (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester, available: 4800);
        await tester.tap(find.text('Withdraw all (PKR 4800)'));
        await tester.pump();
        expect(find.text('4800'), findsOneWidget);
      });
    });

    testWidgets('an empty amount is refused before anything is sent',
        (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('Enter the amount you want to withdraw.'), findsOneWidget);
        expect(api.sent.length, 1, reason: 'only the initial load went out');
      });
    });

    testWidgets('an amount under the minimum names the minimum', (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '50');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('Minimum withdrawal is PKR 200.'), findsOneWidget);
        expect(api.sent.length, 1);
      });
    });

    testWidgets('an amount over the balance names the ceiling', (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester, available: 4800);
        await tester.enterText(find.byType(TextField).first, '9000');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('You can withdraw up to PKR 4800.'), findsOneWidget);
        expect(api.sent.length, 1);
      });
    });

    testWidgets('a zero is refused as an absent amount', (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '0');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('Enter the amount you want to withdraw.'), findsOneWidget);
      });
    });

    // Editing the amount is the player answering the complaint, so the complaint goes.
    testWidgets('typing again clears the message', (tester) async {
      final api = formApi();
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('Enter the amount you want to withdraw.'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.pump();
        expect(find.text('Enter the amount you want to withdraw.'), findsNothing);
      });
    });
  });

  group('where the money is being sent', () {
    testWidgets('a mobile wallet asks for a mobile number', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Mobile number'), findsOneWidget);
        expect(find.text('e.g. 03001234567'), findsOneWidget);
      });
    });

    testWidgets('choosing bank relabels the field and its example',
        (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Easypaisa'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bank Account').last);
        await tester.pumpAndSettle();
        expect(find.text('Account number'), findsOneWidget);
        expect(find.text('e.g. PK00 ABCD 0000 0000 0000'), findsOneWidget);
        expect(find.text('Mobile number'), findsNothing);
      });
    });

    testWidgets('a too-short number names the provider it belongs to',
        (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '0300');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(
          find.text('Enter the mobile number registered with Easypaisa.'),
          findsOneWidget,
        );
        expect(api.sent.length, 1);
      });
    });

    // Spaces are how people write an IBAN, so they do not count towards the length.
    testWidgets('spaces do not make a short number long enough', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03 0 0');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.textContaining('Enter the mobile number'), findsOneWidget);
      });
    });

    testWidgets('the bank message asks for an account number', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Easypaisa'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bank Account').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '123');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        expect(find.text('Enter your bank account number.'), findsOneWidget);
      });
    });

    testWidgets('the holder name is optional', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..ok({'id': 'w9'});
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03001234567');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        await tester.pump();
        expect(api.body(1)['accountName'], '');
      });
    });
  });

  group('requesting the payout', () {
    Future<void> fillAndSubmit(WidgetTester tester,
        {String amount = '1500', String number = '03001234567', String name = ''}) async {
      await tester.enterText(find.byType(TextField).first, amount);
      await tester.enterText(find.byType(TextField).at(1), number);
      if (name.isNotEmpty) {
        await tester.enterText(find.byType(TextField).at(2), name);
      }
      await tester.tap(find.text('Request Withdrawal'));
      await tester.pump();
    }

    testWidgets('the request carries the amount, method and account',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..ok({'id': 'w9'});
      await api.run(() async {
        await pumpSheet(tester);
        await fillAndSubmit(tester, name: '  Ali Raza  ');
        await tester.pump();
        expect(api.endpoint(1), '/wallet/withdraw');
        expect(api.method(1), 'POST');
        expect(api.token(1), 'tok-1');
        final body = api.body(1);
        expect(body['amount'], 1500);
        expect(body['method'], 'easypaisa');
        expect(body['accountNumber'], '03001234567');
        expect(body['accountName'], 'Ali Raza', reason: 'trimmed before it is sent');
      });
    });

    testWidgets('the chosen method reaches the server', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..ok({'id': 'w9'});
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Easypaisa'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('JazzCash').last);
        await tester.pumpAndSettle();
        await fillAndSubmit(tester);
        await tester.pump();
        expect(api.body(1)['method'], 'jazzcash');
      });
    });

    // The in-flight frame is taken before the reply is applied rather than by holding
    // the request open: ApiClient arms a timeout timer per request, and a request still
    // open when the test ends is reported as a leaked timer instead of a busy button.
    testWidgets('the button becomes a spinner and cannot be pressed twice',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..fail('Payouts are paused for maintenance.');
      await api.run(() async {
        await pumpSheet(tester);
        await fillAndSubmit(tester);
        expect(find.text('Request Withdrawal'), findsNothing);
        expect(
          tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
          isNull,
          reason: 'a second tap would be a second payout request',
        );
        await tester.pump();
        expect(api.sent.length, 2,
            reason: 'the disabled button let nothing further out');
      });
    });

    // The sheet returns true so the wallet reloads; a stale balance after a payout is
    // the most alarming number the app can show.
    testWidgets('a successful request closes the sheet asking for a reload',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..ok({'id': 'w9'});
      final results = <bool?>[];
      await api.run(() async {
        useDeviceSurface(tester);
        await pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => results.add(await WithdrawSheet.show(
                  context,
                  token: 'tok-1',
                  available: 5000,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await fillAndSubmit(tester);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(results.single, isTrue);
      });
    });
  });

  group('when the request is refused', () {
    testWidgets('the server\'s reason is shown and the form is left intact',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..fail('Your account is under review.');
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03001234567');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Your account is under review.'), findsOneWidget);
        expect(find.text('1500'), findsOneWidget,
            reason: 'the typed amount must survive so it can be retried');
        expect(find.text('Request Withdrawal'), findsOneWidget);
      });
    });

    // The message comes from ApiClient, which fills one in from the status code before
    // the sheet is reached, so the sheet's own `Withdrawal failed.` string is a second
    // line of defence that a real response never reaches.
    testWidgets('a refusal with no message still says something', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..json({'success': false}, status: 500);
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03001234567');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Something went wrong on the server.'), findsOneWidget);
      });
    });

    // Another request won the race for the single pending slot. Leaving the form up
    // would offer a retry that can only fail again, so the sheet reloads and shows the
    // request that won.
    testWidgets('a conflict reloads and shows the withdrawal that won',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..json({
          'success': false,
          'message': 'A withdrawal is already pending.',
          'statusCode': 409,
        }, status: 409)
        ..ok(withdrawals(inFlight: pending(amount: 2200)));
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03001234567');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(api.sent.length, 3, reason: 'the 409 triggers a reload');
        expect(api.endpoint(2), '/wallet/withdrawals');
        expect(find.text('Withdrawal in Progress'), findsOneWidget);
        expect(find.text('PKR 2200'), findsOneWidget);
      });
    });

    testWidgets('a non-conflict refusal does not reload', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals())
        ..fail('Your account is under review.');
      await api.run(() async {
        await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, '1500');
        await tester.enterText(find.byType(TextField).at(1), '03001234567');
        await tester.tap(find.text('Request Withdrawal'));
        await tester.pump();
        await tester.pump();
        expect(api.sent.length, 2);
      });
    });
  });

  group('the withdrawal already in flight', () {
    testWidgets('its amount, destination and state are all shown',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending(amount: 1500)));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('PKR 1500'), findsOneWidget);
        expect(find.text('to Easypaisa ••••4567'), findsOneWidget);
        expect(find.text('PROCESSING'), findsOneWidget);
        expect(find.byIcon(Icons.schedule), findsOneWidget);
      });
    });

    // Only the last four digits, because the sheet is read in public and the full
    // number adds nothing the player does not already know.
    testWidgets('only the last four digits of the account are printed',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending(number: '03001234567')));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('to Easypaisa ••••4567'), findsOneWidget);
        expect(find.textContaining('0300123'), findsNothing);
      });
    });

    testWidgets('a short number is shown as it is rather than masked wrongly',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending(number: '123')));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('to Easypaisa 123'), findsOneWidget);
      });
    });

    testWidgets('an empty number leaves the destination unqualified',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending(number: '')));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('to Easypaisa'), findsOneWidget);
      });
    });

    // A method the client does not know must not print a raw enum value.
    testWidgets('an unknown method is described in words', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending(method: 'raast', number: '')));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('to your account'), findsOneWidget);
        expect(find.textContaining('raast'), findsNothing);
      });
    });

    testWidgets('the request time is shown', (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.textContaining('Requested 18 Mar, 2026'), findsOneWidget);
      });
    });

    testWidgets('a missing request time is a dash, not a wrong date',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending(requestedAt: null)));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Requested —'), findsOneWidget);
      });
    });

    // pg returns DECIMAL columns as strings, so the amount arrives as "1500.00".
    testWidgets('a string amount out of pg is still printed as a figure',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: {
            ...pending(),
            'amount': '1500.00',
          }));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('PKR 1500'), findsOneWidget);
      });
    });
  });

  group('cancelling the withdrawal', () {
    testWidgets('the cancel goes to the withdrawal\'s own route', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending(id: 'w-77')))
        ..ok({'refunded': 1500});
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Cancel Withdrawal'));
        await tester.pump();
        expect(api.endpoint(1), '/wallet/withdraw/w-77');
        expect(api.method(1), 'DELETE');
        expect(api.token(1), 'tok-1');
      });
    });

    // As above, the busy frame is read before the refusal lands rather than by leaving
    // the DELETE open, which would leak ApiClient's timeout timer past the test.
    testWidgets('the button reports itself busy and cannot be pressed twice',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending()))
        ..fail('This payout has already been sent.');
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Cancel Withdrawal'));
        await tester.pump();
        expect(find.text('Cancelling…'), findsOneWidget);
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
        );
        await tester.pump();
        expect(api.sent.length, 2, reason: 'no second cancel was sent');
      });
    });

    testWidgets('a refused cancel keeps the withdrawal on screen', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending()))
        ..fail('This payout has already been sent.');
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Cancel Withdrawal'));
        await tester.pump();
        await tester.pump();
        expect(find.text('This payout has already been sent.'), findsOneWidget);
        expect(find.text('Withdrawal in Progress'), findsOneWidget);
        expect(find.text('Cancel Withdrawal'), findsOneWidget);
      });
    });

    testWidgets('a refusal with no message still says something', (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending()))
        ..json({'success': false}, status: 500);
      await api.run(() async {
        await pumpSheet(tester);
        await tester.tap(find.text('Cancel Withdrawal'));
        await tester.pump();
        await tester.pump();
        // ApiClient supplies the sentence for a bare 500, so the sheet's own
        // `Could not cancel the withdrawal.` fallback is never the one shown.
        expect(find.text('Something went wrong on the server.'), findsOneWidget);
      });
    });

    // The refund is a real ledger row, so the wallet must be reloaded to see it.
    testWidgets('a successful cancel closes the sheet asking for a reload',
        (tester) async {
      final api = FakeApi()
        ..ok(withdrawals(inFlight: pending()))
        ..ok({'refunded': 1500});
      final results = <bool?>[];
      await api.run(() async {
        useDeviceSurface(tester);
        await pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => results.add(await WithdrawSheet.show(
                  context,
                  token: 'tok-1',
                  available: 5000,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.tap(find.text('Cancel Withdrawal'));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(results.single, isTrue);
      });
    });

    testWidgets('closing without cancelling reports no change', (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      final results = <bool?>[];
      await api.run(() async {
        useDeviceSurface(tester);
        await pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => results.add(await WithdrawSheet.show(
                  context,
                  token: 'tok-1',
                  available: 5000,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(results.single, isFalse,
            reason: 'nothing moved, so the wallet need not reload');
      });
    });

    // A dismissal is not a cancellation, and the static helper turns the null into
    // false so no caller has to handle three outcomes.
    testWidgets('a dismissal is reported as no change, not as null',
        (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      final results = <bool?>[];
      await api.run(() async {
        useDeviceSurface(tester);
        await pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => results.add(await WithdrawSheet.show(
                  context,
                  token: 'tok-1',
                  available: 5000,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.drag(find.text('Withdrawal in Progress'), const Offset(0, 600));
        await tester.pumpAndSettle();
        expect(results.single, isFalse);
      });
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the form still lays out', (tester) async {
      final api = FakeApi()..ok(withdrawals());
      await api.run(() async {
        await pumpSheet(tester, textScale: 2.0);
        expect(find.text('Withdraw Funds'), findsOneWidget);
        expectNoOverflow(tester);
      });
    });

    testWidgets('the pending face still lays out', (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      await api.run(() async {
        await pumpSheet(tester, textScale: 2.0);
        expect(find.text('Withdrawal in Progress'), findsOneWidget);
        expectNoOverflow(tester);
      });
    });

    testWidgets('both footer buttons stay pressable', (tester) async {
      final api = FakeApi()..ok(withdrawals(inFlight: pending()));
      await api.run(() async {
        await pumpSheet(tester, textScale: 2.0);
        expectTapTarget(tester, find.byType(OutlinedButton));
        expectTapTarget(tester, find.byType(TextButton));
      });
    });
  });
}
