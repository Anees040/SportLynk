import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../constants/colors.dart';
import '../providers/connectivity_provider.dart';
import '../services/offline_cache.dart';

/// The thin strip that appears when the app cannot reach the server.
///
/// Modelled on how a messaging app handles the same state: the content stays on
/// screen and a single unobtrusive line explains why it is not moving. It replaces
/// the pattern this app used before — a full-screen error with a Retry button over
/// data the phone already had — which threw away everything the user could still
/// usefully read.
///
/// It animates in and out rather than appearing instantly, because a strip that
/// pops into the layout on every brief socket blip reads as a fault in itself. A
/// screen places it directly under its app bar; when online it occupies no space.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.cachedAt});

  /// When the data behind this screen was last fetched, if it came from the cache.
  ///
  /// Supplying it is strongly preferred: "Offline" alone leaves the user to guess
  /// whether a booking shown as confirmed is current, while "saved 10 min ago"
  /// lets them judge it. Null renders the generic wording, for a screen whose body
  /// has no single timestamp.
  final DateTime? cachedAt;

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityProvider>().isOffline;
    final at = cachedAt;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: offline
          ? Container(
              width: double.infinity,
              color: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.cloud_off_outlined,
                      size: 14, color: AppColors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      at == null
                          ? 'Offline — showing saved data'
                          : 'Offline — saved ${describeCacheAge(at)}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.white,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

/// The "this action needs the network" message, for a write that must not be
/// queued.
///
/// A cached read is safe because the user has already seen it. A queued write is
/// only safe when it cannot fail on arrival, which is true of a chat message and
/// false of anything that competes for a slot or moves money: flushed an hour
/// later it would meet a taken slot, a repriced hour or a different wallet
/// balance, and a clock icon that silently becomes "sorry, gone" after the user
/// has walked away is worse than being told now.
///
/// So money and booking actions call this instead of optimistically succeeding.
class OfflineActionNotice {
  OfflineActionNotice._();

  /// Shown when the user taps something that cannot work offline. Returns true
  /// when the action may proceed, so a call site reads as one guard:
  ///
  /// ```dart
  /// if (!await OfflineActionNotice.guard(context, 'Booking')) return;
  /// ```
  static Future<bool> guard(BuildContext context, String action) async {
    if (context.read<ConnectivityProvider>().isOnline) return true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('You are offline',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Text(
          '$action needs a connection, so it cannot be saved for later — the slot '
          'or the price could change before it goes through. Reconnect and try '
          'again.',
          style: GoogleFonts.poppins(
              fontSize: 13, height: 1.5, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('OK',
                style: GoogleFonts.poppins(
                    color: AppColors.accent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    return false;
  }
}
