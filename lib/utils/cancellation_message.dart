import 'num_util.dart';

/// One sentence describing what a cancellation did, built from the server's own
/// numbers so every screen says the same thing.
///
/// The server returns the authoritative figures — `refund`, `penalty`, `late` and
/// the post-refund `balanceAfter` — alongside its own `message`. The cancellation
/// entry points (the Bookings list for a single booking, the group cancel, and the
/// booking-detail screen) used to phrase this three different ways, two of them
/// dropping the late-cancellation deduction and all of them silent on the resulting
/// balance. This renders one consistent line: what came back, what the venue kept
/// if the cancellation was late, and the wallet balance afterwards.
///
/// A refund of zero is stated plainly rather than hidden: a legacy booking whose
/// whole escrow was the deposit genuinely returns nothing on a late cancellation,
/// and "PKR 0 refunded, PKR N kept by the venue" is the honest sentence.
String cancellationMessage(Map data, {int count = 1}) {
  final refund = asNum(data['refund']);
  final penalty = asNum(data['penalty']);
  final late = data['late'] == true;
  final hasBalance = data['balanceAfter'] != null;
  final balance = asNum(data['balanceAfter']);

  final head = count > 1 ? '$count slots cancelled' : 'Booking cancelled';
  final refundPart = 'PKR ${refund.toStringAsFixed(0)} refunded to your wallet';
  final penaltyPart = (late && penalty > 0)
      ? ', PKR ${penalty.toStringAsFixed(0)} deposit kept by the venue (cancelled within 24h)'
      : '';
  final balancePart =
      hasBalance ? '. New balance: PKR ${balance.toStringAsFixed(0)}' : '';
  return '$head — $refundPart$penaltyPart$balancePart.';
}
