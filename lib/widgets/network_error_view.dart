import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';

/// The "error with a retry" state the project mandates for anything that waits on
/// the network, as a scroll view so a pull-to-refresh still works when the body is
/// an error rather than a list.
///
/// It exists so a failed request is never disguised as an empty result: a screen
/// that swallows its error into the same "nothing here" view tells the user to
/// change a search that never ran. Given a [message] — the human-readable sentence
/// `ApiClient` already returns on the `{success: false}` envelope — and an
/// [onRetry], it names the failure and offers the one action that can fix it.
///
/// Styled to match `MatchEmptyState`: the same 60px muted icon, centred body and
/// generous top offset, so an error and an empty state read as the same family.
class NetworkErrorView extends StatelessWidget {
  /// The sentence to show. Callers pass `ApiClient`'s `message`, which is already
  /// phrased for a user ("No internet connection. Check your mobile data or
  /// Wi-Fi.") rather than a raw exception.
  final String message;

  /// Re-runs the load the error interrupted. The button is labelled, so the icon
  /// beside it is decorative and needs no semantics of its own.
  final Future<void> Function() onRetry;

  /// The heading above [message]. The default suits a connection failure; a screen
  /// with a more specific cause can override it.
  final String title;

  final IconData icon;

  const NetworkErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.title = 'Could not load',
    this.icon = Icons.cloud_off_outlined,
  });

  @override
  Widget build(BuildContext context) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: MediaQuery.sizeOf(context).height * .12),
        children: [
          Icon(icon, size: 60, color: AppColors.disabled),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 14,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh, size: 18, color: AppColors.accent),
              label: Text(
                'Retry',
                style: GoogleFonts.poppins(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                side: const BorderSide(color: AppColors.accent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ],
      );
}
