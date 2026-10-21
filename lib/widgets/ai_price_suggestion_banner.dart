import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../services/pricing_service.dart';
import 'assistant/scout_bits.dart';

class AiPriceSuggestionBanner extends StatelessWidget {
  final PriceSuggestion? suggestion;
  final bool loading;
  final VoidCallback onDismiss;
  final VoidCallback onDetails;
  final VoidCallback? onRetry;

  const AiPriceSuggestionBanner({
    super.key,
    required this.suggestion,
    required this.onDismiss,
    required this.onDetails,
    this.loading = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final price = suggestion;
    final amount = price?.suggestedPrice
        .toStringAsFixed(0)
        .replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (match) => '${match.group(1)},',
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackAction =
              constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(12) > 18;
          final Widget? action = price != null
              ? TextButton(onPressed: onDetails, child: const Text('Details'))
              : !loading && onRetry != null
              ? TextButton(onPressed: onRetry, child: const Text('Retry'))
              : null;
          final content = Row(
            crossAxisAlignment: stackAction
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              const ScoutAvatar(size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Suggested Price',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (loading && price == null)
                      Text(
                        'Reading demand...',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      )
                    else if (price == null || price.source == 'unavailable')
                      Text(
                        'Suggestion unavailable right now',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      )
                    else ...[
                      Text(
                        'PKR $amount/hr',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                      Text(
                        price.isModel
                            ? 'AI model suggestion'
                            : 'Rule-based estimate',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!stackAction && action != null) action,
              IconButton(
                tooltip: 'Dismiss price suggestion for 6 hours',
                onPressed: onDismiss,
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          );
          if (!stackAction || action == null) return content;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              content,
              Align(alignment: Alignment.centerRight, child: action),
            ],
          );
        },
      ),
    );
  }
}
