import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';

class PasswordStrengthBar extends StatelessWidget {
  final String password;

  const PasswordStrengthBar({super.key, required this.password});

  @override
  Widget build(BuildContext context) {
    final checks = _getChecks();
    final score = checks.where((c) => c.met).length;
    final level = _getLevel(score);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final barW = password.isEmpty ? 0.0 : (score / 6) * maxW;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 4,
              width: barW,
              decoration: BoxDecoration(
                color: level.color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          },
        ),
        if (password.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                level.label,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: level.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: checks.map((c) => _buildChip(c)).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildChip(_Check check) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: check.met ? AppColors.accentLight : AppColors.inputFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: check.met ? AppColors.accent.withValues(alpha: 0.3) : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            check.met ? Icons.check_circle : Icons.circle_outlined,
            size: 12,
            color: check.met ? AppColors.accent : AppColors.disabled,
          ),
          const SizedBox(width: 4),
          Text(
            check.label,
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: check.met ? AppColors.accent : AppColors.textSecondary,
              fontWeight: check.met ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  List<_Check> _getChecks() {
    return [
      _Check('8+ chars', password.length >= 8),
      _Check('A-Z', password.contains(RegExp(r'[A-Z]'))),
      _Check('a-z', password.contains(RegExp(r'[a-z]'))),
      _Check('0-9', password.contains(RegExp(r'[0-9]'))),
      _Check('!@#', password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))),
      _Check('12+ chars', password.length >= 12),
    ];
  }

  _Level _getLevel(int score) {
    if (score <= 1) return _Level('Weak', AppColors.error);
    if (score <= 3) return _Level('Fair', AppColors.warning);
    if (score <= 5) return _Level('Good', AppColors.accent);
    return _Level('Strong', AppColors.success);
  }
}

class _Check {
  final String label;
  final bool met;
  const _Check(this.label, this.met);
}

class _Level {
  final String label;
  final Color color;
  const _Level(this.label, this.color);
}
