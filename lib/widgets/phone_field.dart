import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';
import '../services/auth_service.dart';
import 'sport_text_field.dart';

class PhoneField extends StatefulWidget {
  final TextEditingController controller;
  final Function(String firebaseUid) onVerified;
  final bool isVerified;

  const PhoneField({
    super.key,
    required this.controller,
    required this.onVerified,
    this.isVerified = false,
  });

  @override
  State<PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<PhoneField> {
  bool _verified = false;
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    _verified = widget.isVerified;
  }

  @override
  void didUpdateWidget(PhoneField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVerified != oldWidget.isVerified) {
      _verified = widget.isVerified;
    }
  }

  String? _validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Phone number is required';
    }
    final cleaned = value.replaceAll(RegExp(r'\s'), '');
    if (cleaned.length != 11) {
      return 'Must be exactly 11 digits';
    }
    if (!cleaned.startsWith('03')) {
      return 'Must start with 03';
    }
    final validPrefixes = ['030', '031', '032', '033', '034', '035', '036'];
    if (!validPrefixes.any((p) => cleaned.startsWith(p))) {
      return 'Enter valid Pakistani mobile number (03XX-XXXXXXX)';
    }
    return null;
  }

  Future<void> _sendOtp() async {
    final error = _validatePhone(widget.controller.text);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error, style: GoogleFonts.poppins()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    final result = await Navigator.pushNamed(
      context,
      '/otp',
      arguments: widget.controller.text.trim(),
    );

    if (!mounted) return;

    if (result != null && result is String && result.isNotEmpty) {
      final response = await _authService.verifyPhone(
        phone: widget.controller.text.trim(),
        firebaseUid: result,
        purpose: 'registration',
      );
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() => _verified = true);
        widget.onVerified(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              response['message'] as String? ?? 'Unable to verify phone with server',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SportTextField(
                hint: 'Phone Number *',
                prefixIcon: Icons.phone_android,
                controller: widget.controller,
                keyboardType: TextInputType.phone,
                enabled: !_verified,
                validator: _validatePhone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!_verified)
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: _sendOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(
                    'Verify',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (_verified)
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: AppColors.white, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      'Verified',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.white,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
