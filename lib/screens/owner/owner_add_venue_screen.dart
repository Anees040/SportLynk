import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../services/cloudinary_service.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/custom_button.dart';
import '../../utils/snackbar_util.dart';

import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../constants/api_constants.dart';

class OwnerAddVenueScreen extends StatefulWidget {
  const OwnerAddVenueScreen({super.key});
  @override
  State<OwnerAddVenueScreen> createState() => _OwnerAddVenueScreenState();
}

class _OwnerAddVenueScreenState extends State<OwnerAddVenueScreen> {
  int _step = 0;
  final _formKey1 = GlobalKey<FormState>();

  bool _isSubmitting = false;

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
  final _sportOpts = ['Football','Cricket'];

  // Step 2
  XFile? _utilityBill, _ownershipProof;
  final List<XFile> _groundPhotos = [];

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (var c in [_bizCtrl,_addrCtrl,_mapsCtrl,_priceCtrl,_altPhoneCtrl,_openCtrl,_closeCtrl]) { c.dispose(); }
    super.dispose();
  }

  void _snack(String msg, {Color bg = AppColors.error}) {
    if (bg == AppColors.error || bg == AppColors.warning) {
      SnackbarUtil.showError(context, msg);
    } else {
      SnackbarUtil.showSuccess(context, msg);
    }
  }

  Future<XFile?> _pickImg() async => await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);

  Widget _img(XFile f, {double? w, double? h, BoxFit fit = BoxFit.cover}) {
    if (kIsWeb) return Image.network(f.path, width: w, height: h, fit: fit);
    return Image.file(File(f.path), width: w, height: h, fit: fit);
  }

  // Step indicator
  Widget _stepIndicator() {
    final labels = ['Ground Info','Documents'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: List.generate(3, (idx) {
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

  // Step 1
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
      Wrap(spacing: 8, runSpacing: 8, children: ['Turf', 'Futsal', 'Concrete', 'Grass', 'Indoor'].map((t) {
        final val = t.toLowerCase();
        final sel = _groundType == val;
        return FilterChip(
          label: Text(t, style: GoogleFonts.poppins(fontSize: 13, color: sel ? AppColors.accent : AppColors.textSecondary)),
          selected: sel,
          onSelected: (v) => setState(() => _groundType = val),
          selectedColor: AppColors.accentLight, checkmarkColor: AppColors.accent, backgroundColor: AppColors.inputFill, side: BorderSide(color: sel ? AppColors.accent : AppColors.border),
        );
      }).toList()),
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
        validator: (v) {
          if (v == null || v.trim().isEmpty) return null;
          final url = v.trim().toLowerCase();
          final isValid = url.startsWith('https://maps.google') || url.startsWith('https://goo.gl') || url.startsWith('https://maps.app.goo.gl') || url.startsWith('http://maps.google') || url.startsWith('https://www.google.com/maps');
          if (!isValid) return 'Must be a Google Maps link (maps.google.com or maps.app.goo.gl)';
          return null;
        }),
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
        Expanded(child: CustomButton(text: 'Continue →', onPressed: () {
          if (!_formKey1.currentState!.validate()) return;
          if (_groundType == null) { _snack('Select ground type'); return; }
          if (_sports.isEmpty) { _snack('Select at least one sport'); return; }
          setState(() => _step = 1);
        })),
      ]),
    ]));
  }

  // Step 2
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
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 0), style: OutlinedButton.styleFrom(foregroundColor: AppColors.accent, side: const BorderSide(color: AppColors.accent), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
          child: Text('← Back', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: CustomButton(text: 'Submit Venue', isLoading: _isSubmitting, onPressed: () => _submit())),
      ]),
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

  Future<void> _submit() async {
    if (_groundPhotos.length < 3) {
      _snack('Add at least 3 ground photos');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final cloudinary = CloudinaryService();
      
      final futures = await Future.wait([
        cloudinary.uploadMultipleImages(_groundPhotos.map((e) => e.path).toList(), folder: 'venues'),
        _utilityBill != null ? cloudinary.uploadImage(_utilityBill!.path, folder: 'documents') : Future.value(null),
        _ownershipProof != null ? cloudinary.uploadImage(_ownershipProof!.path, folder: 'documents') : Future.value(null),
      ]);

      final groundUrls = futures[0] as List<String>;

      final data = {
        'businessName': _bizCtrl.text.trim(),
        'groundName': _bizCtrl.text.trim(),
        'groundType': _groundType,
        'sportTypes': _sports,
        'city': _city,
        'fullAddress': _addrCtrl.text.trim(),
        'googleMapsLink': _mapsCtrl.text.trim().isEmpty ? null : _mapsCtrl.text.trim(),
        'operatingHoursFrom': _openCtrl.text,
        'operatingHoursTo': _closeCtrl.text,
        'pricePerHour': _priceCtrl.text.trim(),
        'alternateContactPhone': _altPhoneCtrl.text.trim().isEmpty ? null : _altPhoneCtrl.text.trim(),
        'groundPhotos': groundUrls.isNotEmpty ? groundUrls : [
          'https://images.unsplash.com/photo-1553778263-73a83bab9b0c?auto=format&fit=crop&w=800',
          'https://images.unsplash.com/photo-1574629810360-7efbb1924043?auto=format&fit=crop&w=800',
          'https://images.unsplash.com/photo-1459865264687-595d652de67e?auto=format&fit=crop&w=800'
        ],
      };

      if (!mounted) return;
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) return;

      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(data),
      );

      final respData = jsonDecode(resp.body);

      if (!mounted) return;
      if (respData['success'] == true) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 8),
              const CircleAvatar(
                radius: 36,
                backgroundColor: AppColors.accentLight,
                child: Icon(Icons.check_circle, color: AppColors.accent, size: 40),
              ),
              const SizedBox(height: 16),
              Text('Venue Submitted!',
                style: GoogleFonts.poppins(
                  fontSize: 20, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              Text('Your new venue is under review by admins.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pop(true); // Pop back to venues screen
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28)),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text('Done',
                    style: GoogleFonts.poppins(
                      color: Colors.white, fontWeight: FontWeight.w600)),
                )),
            ]),
          ),
        );
      } else {
        _snack(respData['message'] ?? 'Submission failed');
      }
    } catch (e) {
      if (mounted) {
        _snack('An error occurred: $e');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Discard Application?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
            content: Text('Any information you entered will be lost. Are you sure you want to go back?', style: GoogleFonts.poppins()),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Keep Editing', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.error, foregroundColor: Colors.white, elevation: 0),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Discard', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
        if (shouldPop == true && context.mounted) {
          Navigator.pop(context, result);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text('Add New Venue', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          backgroundColor: AppColors.primary, foregroundColor: AppColors.white, elevation: 0,
          bottom: PreferredSize(preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(value: (_step + 1) / 2, valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent), backgroundColor: AppColors.accentLight)),
        ),
        body: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: _step == 0 ? _buildStep1() : _buildStep2(),
          ),
        ),
      ),
    );
  }
}
