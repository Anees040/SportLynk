import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';
import '../constants/app_config.dart';
import 'sport_text_field.dart';

class PhoneField extends StatefulWidget {
  final TextEditingController controller;
  final Function(String firebaseUid) onVerified;
  final VoidCallback? onEdit;
  final bool isVerified;

  const PhoneField({
    super.key,
    required this.controller,
    required this.onVerified,
    this.onEdit,
    this.isVerified = false,
  });

  @override
  State<PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<PhoneField> {
  bool _verified = false;

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
    if (AppConfig.devMode) {
      setState(() => _verified = true);
      widget.onVerified(AppConfig.devFirebaseUid);
      return;
    }
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

    if (result != null && result is String && result.isNotEmpty) {
      setState(() => _verified = true);
      widget.onVerified(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SportTextField(
            label: 'Phone Number *',
            hint: '03XXXXXXXXX',
            prefixIcon: Icons.phone_android,
            controller: widget.controller,
            keyboardType: TextInputType.phone,
            readOnly: _verified,
            validator: _validatePhone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            suffix: _verified
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.accentLight,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle, color: AppColors.accent, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'Verified',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.edit_outlined, size: 20, color: AppColors.textSecondary),
                        onPressed: () {
                          setState(() => _verified = false);
                          if (widget.onEdit != null) widget.onEdit!();
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  )
                : null,
          ),
        ),
        if (!_verified) ...[
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 28.0),
            child: SizedBox(
              height: 54,
              child: ElevatedButton(
                onPressed: _sendOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
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
          ),
        ]
      ],
    );
  }
}
