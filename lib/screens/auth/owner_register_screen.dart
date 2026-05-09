import 'package:flutter/foundation.dart' show kIsWeb;
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
  final _formKey0 = GlobalKey<FormState>();
  final _formKey1 = GlobalKey<FormState>();

  // Step 0
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _cnicCtrl = TextEditingController();
  bool _phoneVerified = false;
  String? _firebaseUid;
  bool _obscurePass = true, _obscureConfirm = true;
  XFile? _avatar;
  String _pwText = '';

  // Step 1
  final _bizCtrl = TextEditingController();
  final _addrCtrl = TextEditingController();
  final _mapsCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _altPhoneCtrl = TextEditingController();
  final _openCtrl = TextEditingController();
  final _closeCtrl = TextEditingController();
  String? _groundType;
  final List<String> _sports = [];
  String? _city;
  final _cities = ['Islamabad','Rawalpindi','Lahore','Karachi','Peshawar','Quetta','Multan','Faisalabad'];
  final _sportOpts = ['Football','Cricket','Futsal','Badminton','Basketball'];

  // Step 2
  XFile? _cnicFront, _cnicBack, _selfie, _utilityBill, _ownershipProof;
  final List<XFile> _groundPhotos = [];

  @override
  void initState() {
    super.initState();
    _passCtrl.addListener(() => setState(() => _pwText = _passCtrl.text));
  }

  @override
  void dispose() {
    for (var c in [_nameCtrl,_phoneCtrl,_emailCtrl,_passCtrl,_confirmCtrl,_cnicCtrl,_bizCtrl,_addrCtrl,_mapsCtrl,_priceCtrl,_altPhoneCtrl,_openCtrl,_closeCtrl]) { c.dispose(); }
    super.dispose();
  }

  void _snack(String msg, {Color bg = AppColors.error}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg, style: GoogleFonts.poppins()), backgroundColor: bg, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
  }

  Future<XFile?> _pickImg() async => await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);

  Widget _img(XFile f, {double? w, double? h, BoxFit fit = BoxFit.cover}) {
    if (kIsWeb) return Image.network(f.path, width: w, height: h, fit: fit);
    return Image.file(File(f.path), width: w, height: h, fit: fit);
  }

  // ── STEP INDICATOR ──
  Widget _stepIndicator() {
    final labels = ['Personal','Ground','Docs'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: List.generate(5, (idx) {
        if (idx.isOdd) {
          final lineIdx = idx ~/ 2;
          return Expanded(child: Container(height: 2, color: lineIdx < _step ? AppColors.accent : AppColors.border));
        }
        final i = idx ~/ 2;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(radius: 18, backgroundColor: i < _step ? AppColors.accent : i == _step ? AppColors.primary : AppColors.disabled,
            child: i < _step ? const Icon(Icons.check, color: AppColors.white, size: 16) : Text('${i+1}', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.white))),
          const SizedBox(height: 4),
          Text(labels[i], style: GoogleFonts.poppins(fontSize: 11, color: i == _step ? AppColors.primary : AppColors.textSecondary, fontWeight: i == _step ? FontWeight.w600 : FontWeight.w400)),
        ]);
      })),
    );
  }

  // ── STEP 0 ──
  Widget _buildStep0() {
    return Form(key: _formKey0, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepIndicator(),
      const SizedBox(height: 20),
      Text('Personal Information', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      Text("Let's verify your identity", style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(height: 24),
      Center(child: GestureDetector(onTap: () async { final f = await _pickImg(); if (f != null) setState(() => _avatar = f); },
        child: Stack(children: [
          CircleAvatar(radius: 48, backgroundColor: AppColors.accentLight, child: _avatar != null ? ClipOval(child: _img(_avatar!, w: 96, h: 96)) : const Icon(Icons.person, size: 48, color: AppColors.accent)),
          Positioned(bottom: 0, right: 0, child: CircleAvatar(radius: 16, backgroundColor: AppColors.accent, child: const Icon(Icons.camera_alt, size: 16, color: AppColors.white))),
        ]))),
      const SizedBox(height: 20),
      SportTextField(label: 'Full Name *', hint: 'Enter your full name', prefixIcon: Icons.person_outline, controller: _nameCtrl,
        validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length < 3) return 'Min 3 characters'; if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(v.trim())) return 'Letters and spaces only'; return null; }),
      const SizedBox(height: 16),
      PhoneField(controller: _phoneCtrl, isVerified: _phoneVerified, onVerified: (uid) => setState(() { _phoneVerified = true; _firebaseUid = uid; })),
      const SizedBox(height: 16),
      SportTextField(label: 'Email (optional)', hint: 'email@example.com', prefixIcon: Icons.mail_outline, controller: _emailCtrl, keyboardType: TextInputType.emailAddress,
        validator: (v) { if (v == null || v.trim().isEmpty) return null; if (!RegExp(r'^[\w.]+@[\w]+\.\w+$').hasMatch(v.trim())) return 'Invalid email'; return null; }),
      const SizedBox(height: 16),
      SportTextField(label: 'Password *', hint: 'Min 8 characters', prefixIcon: Icons.lock_outline, controller: _passCtrl, obscure: _obscurePass,
        suffix: IconButton(icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscurePass = !_obscurePass)),
        validator: (v) { if (v == null || v.isEmpty) return 'Required'; if (v.length < 8) return 'Min 8 chars'; if (!v.contains(RegExp(r'[A-Z]'))) return 'Need uppercase'; if (!v.contains(RegExp(r'[0-9]'))) return 'Need digit'; return null; }),
      const SizedBox(height: 8),
      PasswordStrengthBar(password: _pwText),
      const SizedBox(height: 16),
      SportTextField(label: 'Confirm Password *', hint: 'Re-enter password', prefixIcon: Icons.lock_outline, controller: _confirmCtrl, obscure: _obscureConfirm,
        suffix: IconButton(icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm)),
        validator: (v) { if (v != _passCtrl.text) return 'Passwords do not match'; return null; }),
      const SizedBox(height: 16),
      SportTextField(label: 'CNIC Number *', hint: '3XXXXX-XXXXXXX-X', prefixIcon: Icons.credit_card, controller: _cnicCtrl, keyboardType: TextInputType.number, helperText: 'Used for identity verification only',
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d-]')), LengthLimitingTextInputFormatter(15)],
        validator: (v) { if (v == null || v.isEmpty) return 'CNIC required'; final d = v.replaceAll('-',''); if (d.length != 13 || !RegExp(r'^\d{13}$').hasMatch(d)) return 'Must be 13 digits'; return null; }),
      const SizedBox(height: 32),
      CustomButton(text: 'Continue →', onPressed: () {
        if (!_formKey0.currentState!.validate()) return;
        if (!_phoneVerified) { _snack('Please verify your phone first', bg: AppColors.warning); return; }
        setState(() => _step = 1);
      }),
    ]));
  }

  // ── STEP 1 ──
  Widget _buildStep1() {
    return Form(key: _formKey1, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepIndicator(),
      const SizedBox(height: 20),
      Text('Your Ground', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      Text('Tell us about the venue you manage', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(height: 24),
      SportTextField(label: 'Business / Ground Name *', hint: 'e.g. Green Turf Arena', prefixIcon: Icons.business, controller: _bizCtrl, validator: (v) => v != null && v.trim().length >= 3 ? null : 'Min 3 characters'),
      const SizedBox(height: 16),
      Text('Ground Type *', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      Row(children: ['Turf','Futsal'].map((t) => Expanded(child: Padding(
        padding: EdgeInsets.only(right: t == 'Turf' ? 6 : 0, left: t == 'Futsal' ? 6 : 0),
        child: GestureDetector(onTap: () => setState(() => _groundType = t.toLowerCase()),
          child: Container(height: 52, decoration: BoxDecoration(color: _groundType == t.toLowerCase() ? AppColors.accent : AppColors.inputFill, borderRadius: BorderRadius.circular(12), border: Border.all(color: _groundType == t.toLowerCase() ? AppColors.accent : AppColors.border)),
            child: Center(child: Text(t, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _groundType == t.toLowerCase() ? AppColors.white : AppColors.textSecondary))))),
      ))).toList()),
      const SizedBox(height: 16),
      Text('Sports Offered *', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: _sportOpts.map((s) {
        final sel = _sports.contains(s);
        return FilterChip(label: Text(s, style: GoogleFonts.poppins(fontSize: 13, color: sel ? AppColors.accent : AppColors.textSecondary)), selected: sel,
          onSelected: (v) => setState(() { v ? _sports.add(s) : _sports.remove(s); }),
          selectedColor: AppColors.accentLight, checkmarkColor: AppColors.accent, backgroundColor: AppColors.inputFill, side: BorderSide(color: sel ? AppColors.accent : AppColors.border));
      }).toList()),
      const SizedBox(height: 16),
      Text('City *', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(initialValue: _city, hint: Text('Select city', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.disabled)),
        decoration: InputDecoration(filled: true, fillColor: AppColors.inputFill, prefixIcon: const Icon(Icons.location_city, color: AppColors.textSecondary, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border, width: 0.8)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border, width: 0.8)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.accent, width: 1.5))),
        style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
        items: _cities.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
        onChanged: (v) => setState(() => _city = v), validator: (v) => v == null ? 'City required' : null),
      const SizedBox(height: 16),
      SportTextField(label: 'Full Address *', hint: 'Street, area, landmark', prefixIcon: Icons.location_on_outlined, controller: _addrCtrl, maxLines: 2,
        validator: (v) => v != null && v.trim().length >= 10 ? null : 'Min 10 characters'),
      const SizedBox(height: 16),
      SportTextField(label: 'Google Maps Link (optional)', hint: 'Paste Google Maps URL', prefixIcon: Icons.map_outlined, controller: _mapsCtrl, helperText: 'Open Google Maps → Share → Copy link',
        validator: (v) { if (v == null || v.trim().isEmpty) return null; if (!v.startsWith('https://maps.google') && !v.startsWith('https://goo.gl')) return 'Must be a Google Maps URL'; return null; }),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: SportTextField(label: 'Opens at *', hint: '06:00', prefixIcon: Icons.access_time, controller: _openCtrl, readOnly: true,
          onTap: () async { final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 6, minute: 0)); if (t != null) _openCtrl.text = '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}'; },
          validator: (v) => v == null || v.isEmpty ? 'Required' : null)),
        const SizedBox(width: 12),
        Expanded(child: SportTextField(label: 'Closes at *', hint: '23:00', prefixIcon: Icons.access_time, controller: _closeCtrl, readOnly: true,
          onTap: () async { final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 23, minute: 0)); if (t != null) _closeCtrl.text = '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}'; },
          validator: (v) => v == null || v.isEmpty ? 'Required' : null)),
      ]),
      const SizedBox(height: 16),
      SportTextField(label: 'Price per Hour (PKR) *', hint: 'e.g. 3000', prefixIcon: Icons.currency_exchange, controller: _priceCtrl, keyboardType: TextInputType.number,
        validator: (v) { if (v == null || v.isEmpty) return 'Required'; final n = double.tryParse(v); if (n == null || n < 500 || n > 50000) return 'Range: 500–50,000'; return null; }),
      const SizedBox(height: 16),
      SportTextField(label: 'Alternate Contact (optional)', hint: '03XXXXXXXXX', prefixIcon: Icons.phone, controller: _altPhoneCtrl, keyboardType: TextInputType.phone,
        validator: (v) { if (v == null || v.trim().isEmpty) return null; if (!RegExp(r'^03\d{9}$').hasMatch(v.trim())) return 'Invalid phone'; return null; }),
      const SizedBox(height: 32),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 0), style: OutlinedButton.styleFrom(foregroundColor: AppColors.accent, side: const BorderSide(color: AppColors.accent), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
          child: Text('← Back', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: CustomButton(text: 'Continue →', onPressed: () {
          if (!_formKey1.currentState!.validate()) return;
          if (_groundType == null) { _snack('Select ground type'); return; }
          if (_sports.isEmpty) { _snack('Select at least one sport'); return; }
          setState(() => _step = 2);
        })),
      ]),
    ]));
  }

  // ── STEP 2 ──
  Widget _buildStep2() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepIndicator(),
      const SizedBox(height: 20),
      Text('Verification Documents', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      Text('Required for trust & safety', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [const Icon(Icons.info_outline, color: AppColors.accent, size: 16), const SizedBox(width: 8), Expanded(child: Text('Documents are encrypted and only viewed by SportLynk admins.', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent)))])),
      const SizedBox(height: 20),
      Text('CNIC Photos *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _docPicker('CNIC Front', _cnicFront, (f) => setState(() => _cnicFront = f))),
        const SizedBox(width: 12),
        Expanded(child: _docPicker('CNIC Back', _cnicBack, (f) => setState(() => _cnicBack = f))),
      ]),
      const SizedBox(height: 16),
      _docPicker('Selfie with CNIC *', _selfie, (f) => setState(() => _selfie = f), full: true, hint: 'Hold CNIC next to your face'),
      const SizedBox(height: 20),
      Text('Ground Photos * (min 3)', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      Text('Field view, entrance, facilities', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
      const SizedBox(height: 8),
      Text('${_groundPhotos.length}/6 photos added', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
        itemCount: _groundPhotos.length + (_groundPhotos.length < 6 ? 1 : 0),
        itemBuilder: (_, i) {
          if (i == _groundPhotos.length) {
            return GestureDetector(onTap: () async { if (_groundPhotos.length >= 6) return; final f = await _pickImg(); if (f != null) setState(() => _groundPhotos.add(f)); },
              child: Container(decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12), color: AppColors.inputFill),
                child: const Center(child: Icon(Icons.add_photo_alternate, color: AppColors.accent, size: 28))));
          }
          return Stack(children: [
            ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: double.infinity, height: double.infinity, child: _img(_groundPhotos[i]))),
            Positioned(top: 4, right: 4, child: GestureDetector(onTap: () => setState(() => _groundPhotos.removeAt(i)),
              child: const CircleAvatar(radius: 12, backgroundColor: AppColors.error, child: Icon(Icons.close, size: 14, color: AppColors.white)))),
          ]);
        }),
      const SizedBox(height: 16),
      _docPicker('Utility Bill (optional)', _utilityBill, (f) => setState(() => _utilityBill = f), full: true, hint: 'Electricity or gas bill'),
      const SizedBox(height: 16),
      _docPicker('Ownership/Rent Proof (optional)', _ownershipProof, (f) => setState(() => _ownershipProof = f), full: true, hint: 'Ownership deed or rent agreement'),
      const SizedBox(height: 20),
      Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [const Icon(Icons.warning_amber, color: AppColors.warning, size: 18), const SizedBox(width: 8), Expanded(child: Text('Account reviewed within 24-48 hours. You cannot list venues until approved.', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textPrimary)))])),
      const SizedBox(height: 32),
      Consumer<AuthProvider>(builder: (context, auth, _) => Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 1), style: OutlinedButton.styleFrom(foregroundColor: AppColors.accent, side: const BorderSide(color: AppColors.accent), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
          child: Text('← Back', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: CustomButton(text: 'Submit Application', isLoading: auth.isLoading, onPressed: () => _submit(auth))),
      ])),
      const SizedBox(height: 24),
    ]);
  }

  Widget _docPicker(String label, XFile? file, Function(XFile) onPick, {bool full = false, String? hint}) {
    return GestureDetector(onTap: () async { final f = await _pickImg(); if (f != null) onPick(f); },
      child: Container(height: full ? 100 : 100, width: double.infinity,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: file != null ? AppColors.accent : AppColors.border, width: 1.5), color: file != null ? AppColors.accentLight : AppColors.inputFill),
        child: file != null
          ? Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(11), child: SizedBox(width: double.infinity, height: double.infinity, child: _img(file))),
              Positioned(top: 4, right: 4, child: CircleAvatar(radius: 10, backgroundColor: AppColors.accent, child: const Icon(Icons.check, size: 12, color: AppColors.white))),
            ])
          : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.upload_file, color: AppColors.accent, size: 28),
              const SizedBox(height: 4),
              Text(label, style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textPrimary), textAlign: TextAlign.center),
              if (hint != null) Text(hint, style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary), textAlign: TextAlign.center),
            ]),
      ));
  }

  Future<void> _submit(AuthProvider auth) async {
    if (_cnicFront == null || _cnicBack == null || _selfie == null) { _snack('CNIC photos and selfie are required'); return; }
    if (_groundPhotos.length < 3) { _snack('Add at least 3 ground photos'); return; }
    final data = {
      'name': _nameCtrl.text.trim(), 'phone': _phoneCtrl.text.trim(), 'password': _passCtrl.text,
      'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      'firebaseUid': _firebaseUid, 'cnicNumber': _cnicCtrl.text.trim(),
      'businessName': _bizCtrl.text.trim(), 'groundName': _bizCtrl.text.trim(), 'groundType': _groundType,
      'sportTypes': _sports, 'city': _city, 'fullAddress': _addrCtrl.text.trim(),
      'googleMapsLink': _mapsCtrl.text.trim().isEmpty ? null : _mapsCtrl.text.trim(),
      'operatingHoursFrom': _openCtrl.text, 'operatingHoursTo': _closeCtrl.text,
      'pricePerHour': _priceCtrl.text.trim(),
      'alternateContactPhone': _altPhoneCtrl.text.trim().isEmpty ? null : _altPhoneCtrl.text.trim(),
      'cnicFrontUrl': _cnicFront!.path, 'cnicBackUrl': _cnicBack!.path, 'selfieWithCnicUrl': _selfie!.path,
      'groundPhotos': _groundPhotos.map((x) => x.path).toList(),
      'utilityBillUrl': _utilityBill?.path, 'ownershipProofUrl': _ownershipProof?.path,
    };
    final ok = await auth.registerOwner(data);
    if (!mounted) return;
    if (ok) { Navigator.pushNamedAndRemoveUntil(context, '/owner-pending', (r) => false); }
    else { _snack(auth.errorMessage ?? 'Submission failed'); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Owner Registration', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary, foregroundColor: AppColors.white, elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_step + 1) / 3, color: AppColors.accent, backgroundColor: AppColors.accentLight)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: _step == 0 ? _buildStep0() : _step == 1 ? _buildStep1() : _buildStep2(),
      ),
    );
  }
}
