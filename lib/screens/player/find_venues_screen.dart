import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class FindVenuesScreen extends StatelessWidget {
  const FindVenuesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // You can receive arguments if passed
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final sport = args?['sport'];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(sport != null && sport.isNotEmpty ? 'Find $sport Venues' : 'Find Venues',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search, size: 64, color: AppColors.disabled),
            const SizedBox(height: 16),
            Text('Search feature coming soon!',
              style: GoogleFonts.poppins(fontSize: 16, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
