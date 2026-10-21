import 'num_util.dart';

double venueDepositPercent(Map<String, dynamic> venue) {
  final percent = asNumOrNull(venue['effective_deposit_pct'] ?? venue['deposit_pct']);
  return percent != null && percent >= 0 && percent <= 100 ? percent : 20;
}

String formatPercent(num percent) => percent == percent.roundToDouble()
    ? percent.toStringAsFixed(0)
    : percent.toString();
