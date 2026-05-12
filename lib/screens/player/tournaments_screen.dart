import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class TournamentsScreen extends StatelessWidget {
  const TournamentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Tournaments', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primary, Color(0xFF166534)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(30), bottomRight: Radius.circular(30)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)),
                    child: Text('FEATURED', style: GoogleFonts.poppins(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ),
                  const SizedBox(height: 12),
                  Text('Ramadan Futsal Cup 2026', style: GoogleFonts.poppins(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text('Starts: 1st June, 2026', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12)),
                      const SizedBox(width: 16),
                      const Icon(Icons.emoji_events, color: Colors.amber, size: 14),
                      const SizedBox(width: 4),
                      Text('Prize: 50k PKR', style: GoogleFonts.poppins(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                    child: Text('Register Team', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Filters
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    _filterChip('All', true),
                    _filterChip('Football', false),
                    _filterChip('Cricket', false),
                    _filterChip('Basketball', false),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Upcoming List
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Upcoming Tournaments', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            ),
            const SizedBox(height: 12),
            
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 3,
              itemBuilder: (context, index) => _tournamentCard(index),
            ),
            
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, bool isSelected) {
    return Container(
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: isSelected ? AppColors.accent : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isSelected ? AppColors.accent : AppColors.border),
      ),
      child: Text(
        label,
        style: GoogleFonts.poppins(
          color: isSelected ? Colors.white : AppColors.textSecondary,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _tournamentCard(int index) {
    final titles = ['Summer Smash Cricket', 'Islamabad City League', 'Weekend Warriors'];
    final sports = ['Cricket', 'Football', 'Basketball'];
    final prizes = ['100k PKR', '30k PKR', '15k PKR'];
    final spots = ['4 spots left', 'Registration closed', '12 spots left'];
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Date Box
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text('JUN', style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold)),
                  Text('${15 + index}', style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            
            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titles[index], style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(4)),
                        child: Text(sports[index], style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
                      ),
                      const SizedBox(width: 8),
                      Text('🏆 ${prizes[index]}', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(spots[index], style: GoogleFonts.poppins(
                    fontSize: 11, 
                    color: index == 1 ? AppColors.error : AppColors.accent,
                    fontWeight: FontWeight.w500,
                  )),
                ],
              ),
            ),
            
            // Action
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
