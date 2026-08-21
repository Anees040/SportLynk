import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Help & Support', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How can we help you?', style: GoogleFonts.poppins(
              fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text('Find answers to common questions or reach out to our team.',
              style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            
            // ── CONTACT CARDS ──────────────────────
            Row(
              children: [
                Expanded(child: _contactCard(
                  icon: Icons.chat_bubble_outline,
                  title: 'Live Chat',
                  subtitle: 'Typically replies in minutes',
                  color: Colors.blue,
                  onTap: () {},
                )),
                const SizedBox(width: 16),
                Expanded(child: _contactCard(
                  icon: Icons.email_outlined,
                  title: 'Email Us',
                  subtitle: 'support@sportlynk.com',
                  color: AppColors.accent,
                  onTap: () {},
                )),
              ],
            ),
            const SizedBox(height: 32),

            // ── FAQs ───────────────────────────────
            Text('Frequently Asked Questions', style: GoogleFonts.poppins(
              fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 12),
            _faqItem('How does the escrow work?',
              'When you book a venue, the full slot price is frozen in your wallet. It is released to the venue owner only when you check in with your QR code. 20% of the price is the at-risk deposit you can lose on a late cancellation or a no-show.'),
            _faqItem('What happens if I cancel a booking?',
              'If you cancel more than 24 hours before the start time, the full amount is refunded. If you cancel within 24 hours, you get 80% back and the 20% deposit goes to the venue owner.'),
            _faqItem('How can I top up my wallet?', 
              'Currently, wallet top-ups are handled manually by administrators during our beta phase. Soon you will be able to top up via credit card and JazzCash.'),
          ],
        ),
      ),
    );
  }

  Widget _contactCard({required IconData icon, required String title, required String subtitle, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 16),
            Text(title, style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            Text(subtitle, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _faqItem(String question, String answer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: ExpansionTile(
        title: Text(question, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600)),
        iconColor: AppColors.accent,
        collapsedIconColor: AppColors.textSecondary,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(answer, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
        ],
      ),
    );
  }
}
