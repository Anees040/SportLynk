// The phone-verification screen (OTP entry) is the one auth screen without a widget
// test, and the omission is deliberate rather than pending. `OtpScreen` builds its
// `FirebaseOtpService` in a `State` field initializer, and that service reads
// `FirebaseAuth.instance` the instant it is constructed. Under `flutter test` no
// `Firebase.initializeApp()` has run, so `FirebaseAuth.instance` throws
// `[core/no-app] No Firebase App '[DEFAULT]' has been created` before the first frame
// is built — the widget cannot be pumped at all. There is no seam to substitute a
// fake service, and everything the screen does that carries meaning (send the code,
// auto-retrieve it, verify it) is Firebase Phone Auth, which has no method channel
// bound under the test harness. The screen is therefore exercised on a device, in the
// same category as the camera-only QR scanner, not in this suite.
//
// This file records that boundary in the suite rather than leaving a silent gap. If a
// later change injects the OTP service, or the tree adopts Firebase core/auth test
// mocks, the pumpable states — the "sending" spinner, the six-box entry row, the
// resend countdown — become reachable and this skip should be replaced with them.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'OtpScreen is verified on-device: Firebase Phone Auth has no test seam',
    () {},
    skip: 'OtpScreen constructs FirebaseAuth.instance in a State field initializer, '
        'which throws [core/no-app] under flutter test; no injection seam exists to '
        'substitute a fake, and its behaviour is entirely Firebase Phone Auth.',
  );
}
