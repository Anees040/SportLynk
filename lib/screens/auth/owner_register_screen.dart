import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';

class OwnerRegisterScreen extends StatefulWidget {
  const OwnerRegisterScreen({super.key});
  @override
  State<OwnerRegisterScreen> createState() => _OwnerRegisterScreenState();
}

class _OwnerRegisterScreenState extends State<OwnerRegisterScreen> {
  int _step = 0;
  final _step1Key = GlobalKey<FormState>();
  final _step2Key = GlobalKey<FormState>();

  // Step 1
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  final _cnicCtrl = TextEditingController();
  bool _obscurePass = true, _obscureConfirm = true;
  bool _phoneVerified = false;
  String? _firebaseUid;
  XFile? _avatar;
  String _pwText = '';

  // Step 2
  final _businessCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _mapsCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _altPhoneCtrl = TextEditingController();
  String? _groundType;
  final List<String> _sports = [];
  String? _city;
  TimeOfDay? _opensAt;
  TimeOfDay? _closesAt;

  // Step 3
  XFile? _cnicFront, _cnicBack, _selfie, _utilityBill, _ownershipProof;
  final List<XFile> _groundPhotos = [];

  @override
  void initState() {
    super.initState();
    _passwordCtrl.addListener(() => setState(() => _pwText = _passwordCtrl.text));
  }

  @override
  void dispose() {
    for (var c in [_nameCtrl, _phoneCtrl, _emailCtrl, _passwordCtrl, _confirmPassCtrl, _cnicCtrl, _businessCtrl, _addressCtrl, _mapsCtrl, _priceCtrl, _altPhoneCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _valName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    if (v.trim().length < 3) return 'Min 3 characters';
    if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(v.trim())) return 'Letters and spaces only';
    return null;
  }

  String? _valEmail(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) return 'Invalid email';
    return null;
  }

  String? _valPass(String? v) {
    if (v == null || v.isEmpty) return 'Required';
    if (v.length < 8) return 'Min 8 characters';
    if (!v.contains(RegExp(r'[A-Z]'))) return 'Need uppercase';
    if (!v.contains(RegExp(r'[a-z]'))) return 'Need lowercase';
    if (!v.contains(RegExp(r'[0-9]'))) return 'Need digit';
    if (!v.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) return 'Need special char';
    return null;
  }

  String? _valCnic(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final clean = v.replaceAll('-', '');
    if (clean.length != 13 || !RegExp(r'^\d{13}$').hasMatch(clean)) return 'Must be 13 digits';
    if (clean.substring(0, 5) == '00000') return 'Invalid district code';
    return null;
  }

  Future<XFile?> _pickImage({ImageSource source = ImageSource.gallery}) async {
    return await ImagePicker().pickImage(source: source, maxWidth: 1024, imageQuality: 80);
  }

  Future<void> _pickGroundPhoto() async {
    if (_groundPhotos.length >= 6) return;
    final img = await _pickImage();
    if (img != null) setState(() => _groundPhotos.add(img));
  }

  String _fmtTime(TimeOfDay? t) => t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _goStep2() {
    if (!_step1Key.currentState!.validate()) return;
    if (!_phoneVerified) {
      _snack('Please verify your phone number first');
      return;
    }
    setState(() => _step = 1);
  }

  void _goStep3() {
    if (!_step2Key.currentState!.validate()) return;
    if (_groundType == null) { _snack('Select ground type'); return; }
    if (_sports.isEmpty) { _snack('Select at least one sport'); return; }
    if (_city == null) { _snack('Select city'); return; }
    if (_opensAt == null || _closesAt == null) { _snack('Set operating hours'); return; }
    setState(() => _step = 2);
  }

  Future<void> _submit() async {
    if (_cnicFront == null || _cnicBack == null || _selfie == null) {
      _snack('CNIC photos and selfie are required');
      return;
    }
    if (_groundPhotos.length < 3) {
      _snack('At least 3 ground photos required');
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final data = {
      'name': _nameCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'password': _passwordCtrl.text,
      'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      'firebaseUid': _firebaseUid,
      'cnicNumber': _cnicCtrl.text.trim(),
      'businessName': _businessCtrl.text.trim(),
      'groundName': _businessCtrl.text.trim(),
      'groundType': _groundType,
      'sportTypes': _sports,
      'city': _city,
      'fullAddress': _addressCtrl.text.trim(),
      'googleMapsLink': _mapsCtrl.text.trim().isEmpty ? null : _mapsCtrl.text.trim(),
      'operatingHoursFrom': _fmtTime(_opensAt),
      'operatingHoursTo': _fmtTime(_closesAt),
      'pricePerHour': _priceCtrl.text.trim(),
      'alternateContactPhone': _altPhoneCtrl.text.trim().isEmpty ? null : _altPhoneCtrl.text.trim(),
      'cnicFrontUrl': _cnicFront?.path,
      'cnicBackUrl': _cnicBack?.path,
      'selfieWithCnicUrl': _selfie?.path,
      'groundPhotos': _groundPhotos.map((x) => x.path).toList(),
      'utilityBillUrl': _utilityBill?.path,
      'ownershipProofUrl': _ownershipProof?.path,
    };

    final ok = await auth.registerOwner(data);
    if (!mounted) return;
    if (ok) {
      Navigator.pushNamedAndRemoveUntil(context, '/owner-pending', (r) => false);
    } else {
      _snack(auth.errorMessage ?? 'Registration failed');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins()),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Owner Registration', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Text('Step ${_step + 1}/3', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.white.withValues(alpha: 0.7))),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildProgress(),
            const SizedBox(height: 24),
            if (_step == 0) _buildStep1(),
            if (_step == 1) _buildStep2(),
            if (_step == 2) _buildStep3(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Row(
      children: List.generate(3, (i) {
        final active = i <= _step;
        final icons = [Icons.person, Icons.location_on, Icons.folder];
        final labels = ['Personal', 'Ground', 'Documents'];
        return Expanded(
          child: Column(
            children: [
              Row(
                children: [
                  if (i > 0) Expanded(child: Container(height: 2, color: i <= _step ? AppColors.accent : AppColors.border)),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: active ? AppColors.accent : AppColors.inputFill,
                    child: Icon(icons[i], size: 18, color: active ? AppColors.white : AppColors.textSecondary),
                  ),
                  if (i < 2) Expanded(child: Container(height: 2, color: i < _step ? AppColors.accent : AppColors.border)),
                ],
              ),
              const SizedBox(height: 4),
              Text(labels[i], style: GoogleFonts.poppins(fontSize: 10, color: active ? AppColors.accent : AppColors.textSecondary, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _step1Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Personal Information', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          Text("Let's verify your identity", style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
          const SizedBox(height: 24),
          Center(child: GestureDetector(
            onTap: () async { final f = await _pickImage(); if (f != null) setState(() => _avatar = f); },
            child: Stack(children: [
              CircleAvatar(radius: 44, backgroundColor: AppColors.accentLight, backgroundImage: _avatar != null ? FileImage(File(_avatar!.path)) : null, child: _avatar == null ? const Icon(Icons.person, size: 44, color: AppColors.accent) : null),
              Positioned(bottom: 0, right: 0, child: CircleAvatar(radius: 14, backgroundColor: AppColors.accent, child: const Icon(Icons.camera_alt, size: 14, color: AppColors.white))),
            ]),
          )),
          const SizedBox(height: 20),
          SportTextField(hint: 'Full Name *', prefixIcon: Icons.person_outline, controller: _nameCtrl, validator: _valName),
          const SizedBox(height: 16),
          PhoneField(controller: _phoneCtrl, isVerified: _phoneVerified, onVerified: (uid) => setState(() { _phoneVerified = true; _firebaseUid = uid; })),
          const SizedBox(height: 16),
          SportTextField(hint: 'Email (optional)', prefixIcon: Icons.mail_outline, controller: _emailCtrl, keyboardType: TextInputType.emailAddress, validator: _valEmail),
          const SizedBox(height: 16),
          SportTextField(hint: 'Password *', prefixIcon: Icons.lock_outline, controller: _passwordCtrl, obscure: _obscurePass, validator: _valPass,
            suffix: IconButton(icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscurePass = !_obscurePass))),
          PasswordStrengthBar(password: _pwText),
          const SizedBox(height: 16),
          SportTextField(hint: 'Confirm Password *', prefixIcon: Icons.lock_outline, controller: _confirmPassCtrl, obscure: _obscureConfirm,
            validator: (v) { if (v != _passwordCtrl.text) return 'Passwords do not match'; return null; },
            suffix: IconButton(icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm))),
          const SizedBox(height: 16),
          SportTextField(hint: 'CNIC Number *', prefixIcon: Icons.credit_card, controller: _cnicCtrl, keyboardType: TextInputType.number, validator: _valCnic, helperText: 'Your CNIC is used for identity verification only',
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d-]')), LengthLimitingTextInputFormatter(15)]),
          const SizedBox(height: 32),
          CustomButton(text: 'Continue →', onPressed: _goStep2),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    final cities = ['Islamabad', 'Rawalpindi', 'Lahore', 'Karachi', 'Peshawar', 'Quetta', 'Multan', 'Faisalabad'];
    final sportOpts = ['Football', 'Cricket', 'Badminton', 'Basketball', 'Futsal'];
    return Form(
      key: _step2Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your Ground', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          Text('Tell us about the venue you manage', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
          const SizedBox(height: 24),
          SportTextField(hint: 'Business / Ground Name *', prefixIcon: Icons.business, controller: _businessCtrl, validator: (v) => v != null && v.trim().length >= 3 ? null : 'Min 3 characters'),
          const SizedBox(height: 16),
          Text('Ground Type *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Row(children: ['turf', 'futsal'].map((t) => Expanded(child: Padding(
            padding: EdgeInsets.only(right: t == 'turf' ? 8 : 0, left: t == 'futsal' ? 8 : 0),
            child: GestureDetector(
              onTap: () => setState(() => _groundType = t),
              child: Container(height: 48, decoration: BoxDecoration(color: _groundType == t ? AppColors.accent : AppColors.inputFill, borderRadius: BorderRadius.circular(12)),
                child: Center(child: Text(t[0].toUpperCase() + t.substring(1), style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _groundType == t ? AppColors.white : AppColors.textSecondary)))),
            ),
          ))).toList()),
          const SizedBox(height: 16),
          Text('Sports Offered *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: sportOpts.map((s) {
            final sel = _sports.contains(s.toLowerCase());
            return GestureDetector(
              onTap: () => setState(() { sel ? _sports.remove(s.toLowerCase()) : _sports.add(s.toLowerCase()); }),
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: sel ? AppColors.accent : AppColors.inputFill, borderRadius: BorderRadius.circular(20)),
                child: Text(s, style: GoogleFonts.poppins(fontSize: 13, color: sel ? AppColors.white : AppColors.textSecondary, fontWeight: FontWeight.w500))),
            );
          }).toList()),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _city, decoration: InputDecoration(hintText: 'City *', filled: true, fillColor: AppColors.inputFill, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.location_city, color: AppColors.textSecondary)),
            style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
            items: cities.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => _city = v),
            validator: (v) => v == null ? 'Required' : null,
          ),
          const SizedBox(height: 16),
          SportTextField(hint: 'Full Address *', prefixIcon: Icons.map, controller: _addressCtrl, maxLines: 2, validator: (v) => v != null && v.trim().length >= 10 ? null : 'Min 10 characters'),
          const SizedBox(height: 16),
          SportTextField(hint: 'Google Maps Link (optional)', prefixIcon: Icons.link, controller: _mapsCtrl, helperText: 'Open Google Maps → Share → Copy link',
            validator: (v) { if (v == null || v.trim().isEmpty) return null; if (!v.startsWith('https://maps.google') && !v.startsWith('https://goo.gl')) return 'Invalid Maps link'; return null; }),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: GestureDetector(
              onTap: () async { final t = await showTimePicker(context: context, initialTime: _opensAt ?? const TimeOfDay(hour: 6, minute: 0)); if (t != null) setState(() => _opensAt = t); },
              child: AbsorbPointer(child: SportTextField(hint: 'Opens at *', prefixIcon: Icons.access_time, controller: TextEditingController(text: _fmtTime(_opensAt)), validator: (_) => _opensAt == null ? 'Required' : null)),
            )),
            const SizedBox(width: 12),
            Expanded(child: GestureDetector(
              onTap: () async { final t = await showTimePicker(context: context, initialTime: _closesAt ?? const TimeOfDay(hour: 23, minute: 0)); if (t != null) setState(() => _closesAt = t); },
              child: AbsorbPointer(child: SportTextField(hint: 'Closes at *', prefixIcon: Icons.access_time, controller: TextEditingController(text: _fmtTime(_closesAt)), validator: (_) => _closesAt == null ? 'Required' : null)),
            )),
          ]),
          const SizedBox(height: 16),
          SportTextField(hint: 'Price per Hour (PKR) *', prefixIcon: Icons.attach_money, controller: _priceCtrl, keyboardType: TextInputType.number,
            validator: (v) { if (v == null || v.isEmpty) return 'Required'; final n = double.tryParse(v); if (n == null || n < 500 || n > 50000) return 'Range: 500-50,000 PKR'; return null; }),
          const SizedBox(height: 16),
          SportTextField(hint: 'Alternate Contact (optional)', prefixIcon: Icons.phone, controller: _altPhoneCtrl, keyboardType: TextInputType.phone,
            validator: (v) { if (v == null || v.trim().isEmpty) return null; if (!RegExp(r'^03\d{9}$').hasMatch(v.trim())) return 'Invalid phone'; return null; }),
          const SizedBox(height: 32),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 0), style: OutlinedButton.styleFrom(foregroundColor: AppColors.accent, side: const BorderSide(color: AppColors.accent), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))), child: Text('← Back', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)))),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: CustomButton(text: 'Continue →', onPressed: _goStep3)),
          ]),
        ],
      ),
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Verification Documents', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        Text('Required for trust & safety', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [const Icon(Icons.info_outline, color: AppColors.accent, size: 18), const SizedBox(width: 8), Expanded(child: Text('All documents are encrypted and only viewed by SportLynk admins.', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent)))])),
        const SizedBox(height: 24),
        Text('CNIC Photos *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
        Text('Take clear photos in good lighting', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _docPicker('CNIC Front', Icons.credit_card, _cnicFront, (f) => setState(() => _cnicFront = f))),
          const SizedBox(width: 12),
          Expanded(child: _docPicker('CNIC Back', Icons.credit_card, _cnicBack, (f) => setState(() => _cnicBack = f))),
        ]),
        const SizedBox(height: 16),
        _docPicker('Selfie with CNIC *', Icons.face, _selfie, (f) => setState(() => _selfie = f), full: true),
        Text('Hold your CNIC next to your face', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 20),
        Text('Ground Photos *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
        Text('Minimum 3 photos (field, entrance, facilities)', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Text('${_groundPhotos.length}/6 photos added', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemCount: _groundPhotos.length + (_groundPhotos.length < 6 ? 1 : 0),
          itemBuilder: (_, i) {
            if (i == _groundPhotos.length) {
              return GestureDetector(onTap: _pickGroundPhoto, child: Container(decoration: BoxDecoration(border: Border.all(color: AppColors.border, style: BorderStyle.solid), borderRadius: BorderRadius.circular(12), color: AppColors.inputFill), child: const Icon(Icons.add, color: AppColors.textSecondary)));
            }
            return Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(_groundPhotos[i].path), fit: BoxFit.cover, width: double.infinity, height: double.infinity)),
              Positioned(top: 4, right: 4, child: GestureDetector(onTap: () => setState(() => _groundPhotos.removeAt(i)), child: const CircleAvatar(radius: 12, backgroundColor: AppColors.error, child: Icon(Icons.close, size: 14, color: AppColors.white)))),
            ]);
          },
        ),
        const SizedBox(height: 16),
        _docPicker('Utility Bill (optional)', Icons.receipt_long, _utilityBill, (f) => setState(() => _utilityBill = f), full: true),
        const SizedBox(height: 16),
        _docPicker('Ownership/Rent Proof (optional)', Icons.description, _ownershipProof, (f) => setState(() => _ownershipProof = f), full: true),
        const SizedBox(height: 24),
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [const Icon(Icons.warning_amber_outlined, color: AppColors.warning, size: 18), const SizedBox(width: 8), Expanded(child: Text('Your account will be reviewed. You cannot list venues until approved.', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textPrimary)))])),
        const SizedBox(height: 32),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 1), style: OutlinedButton.styleFrom(foregroundColor: AppColors.accent, side: const BorderSide(color: AppColors.accent), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))), child: Text('← Back', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)))),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: Consumer<AuthProvider>(builder: (context, auth, _) => CustomButton(text: 'Submit Application', isLoading: auth.isLoading, onPressed: _submit))),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _docPicker(String label, IconData icon, XFile? file, Function(XFile) onPick, {bool full = false}) {
    return GestureDetector(
      onTap: () async { final f = await _pickImage(); if (f != null) onPick(f); },
      child: Container(
        height: full ? 80 : 90, width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: file != null ? AppColors.accent : AppColors.border),
          color: file != null ? AppColors.accentLight : AppColors.inputFill,
        ),
        child: file != null
          ? Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(11), child: Image.file(File(file.path), fit: BoxFit.cover, width: double.infinity, height: double.infinity)),
              Positioned(top: 4, right: 4, child: CircleAvatar(radius: 10, backgroundColor: AppColors.accent, child: const Icon(Icons.check, size: 12, color: AppColors.white))),
            ])
          : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: AppColors.textSecondary, size: 24),
              const SizedBox(height: 4),
              Text(label, style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary), textAlign: TextAlign.center),
            ]),
      ),
    );
  }
}
