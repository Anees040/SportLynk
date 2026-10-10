import 'package:flutter/foundation.dart';

/// App-wide "data behind more than one screen just changed" signal.
///
/// The player shell keeps Home, Bookings and Wallet alive together in an
/// `IndexedStack`, so a mutation on one of them — a cancellation refunding the
/// wallet, a booking made through Scout — leaves the other two showing stale
/// figures until the user pulls to refresh each in turn. This notifier is the one
/// place those cross-screen changes are announced: a mutation calls
/// [bookingsChanged] or [walletChanged], and every mounted listener reloads itself,
/// honouring its own offline and staleness rules.
///
/// It carries no data. Each screen already owns its fetch; this only says *when* to
/// run it, so there is never a second copy of a booking or a balance to drift from
/// the list it links to.
///
/// Listeners compare the revision for their own concern and skip a reload when only
/// the other moved — a top-up must not reload the bookings list.
class DataSyncProvider extends ChangeNotifier {
  int _bookingsRevision = 0;
  int _walletRevision = 0;

  /// Bumped whenever the set of bookings changes (made, cancelled, auto-decided).
  int get bookingsRevision => _bookingsRevision;

  /// Bumped whenever the wallet balance moves (booking, refund, top-up, withdrawal).
  int get walletRevision => _walletRevision;

  /// A booking was created or cancelled. Money moves with it — a cancellation
  /// refunds the wallet, a booking freezes escrow — so both revisions bump and the
  /// Home dashboard, the Bookings list and the Wallet all refresh together.
  void bookingsChanged() {
    _bookingsRevision++;
    _walletRevision++;
    notifyListeners();
  }

  /// The wallet moved without a booking change — a top-up or a withdrawal request.
  void walletChanged() {
    _walletRevision++;
    notifyListeners();
  }
}
