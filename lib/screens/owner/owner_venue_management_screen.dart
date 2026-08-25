import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/pricing_service.dart';
import '../../widgets/pricing_widgets.dart';

class OwnerVenueManagementScreen extends StatefulWidget {
  final Map<String, dynamic> venue;

  const OwnerVenueManagementScreen({super.key, required this.venue});

  @override
  State<OwnerVenueManagementScreen> createState() => _OwnerVenueManagementScreenState();
}

class _OwnerVenueManagementScreenState extends State<OwnerVenueManagementScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _descCtrl;
  late TextEditingController _priceCtrl;
  bool _isSaving = false;

  // ── 72-hour demand forecast (FR4.18) ──────────────────────
  // Read-only and independent of the form: the owner is looking at it precisely to
  // decide what to type into the price field, so a failure here must leave the form
  // fully usable.
  final _pricing = PricingService();
  DemandForecast? _forecast;
  bool _forecastLoading = true;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.venue['description']?.toString() ?? '');
    _priceCtrl = TextEditingController(text: _parseNum(widget.venue['price_per_hour']).toStringAsFixed(0));
    _loadForecast();
  }

  Future<void> _loadForecast() async {
    final id = widget.venue['id']?.toString();
    if (id == null || id.isEmpty) {
      setState(() => _forecastLoading = false);
      return;
    }
    setState(() => _forecastLoading = true);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final f = await _pricing.forecast(token ?? '', id, hours: 72);
    if (!mounted) return;
    setState(() {
      _forecast = f;
      _forecastLoading = false;
    });
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  double _parseNum(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final req = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues/${widget.venue['id']}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'description': _descCtrl.text.trim(),
          'price_per_hour': double.parse(_priceCtrl.text.trim()),
        }),
      );

      final data = jsonDecode(req.body);
      if (mounted) {
        if (data['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Venue updated successfully!'), backgroundColor: AppColors.accent),
          );
          Navigator.pop(context, true); // true indicates a refresh is needed
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['message'] ?? 'Failed to update'), backgroundColor: AppColors.error),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Network error occurred'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildField(String label, TextEditingController ctrl, {bool isNumber = false, int maxLines = 1, String? suffixText}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        TextFormField(
          controller: ctrl,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          maxLines: maxLines,
          style: GoogleFonts.poppins(fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.inputFill,
            suffixText: suffixText,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          validator: (v) => v == null || v.isEmpty ? 'Required' : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Manage ${widget.venue['name']}', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildField('Venue Description & Amenities', _descCtrl, maxLines: 4),
              _buildField('Price Per Hour', _priceCtrl, isNumber: true, suffixText: 'PKR'),

              // Sits directly under the price field on purpose: this is the evidence
              // for the number the owner is about to type. Above the escrow note,
              // which is policy they cannot change.
              DemandForecastSection(
                forecast: _forecast,
                loading: _forecastLoading,
                onRetry: _loadForecast,
              ),
              const SizedBox(height: 16),

              // Deposit policy is platform-wide and computed server-side — read only.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lock_outline, color: AppColors.accent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Escrow policy (set by SportLynk): the full slot price is held when a '
                      'player books and released to you at QR check-in. On a late '
                      'cancellation or no-show you keep the 20% deposit.',
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.primary),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveChanges,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _isSaving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text('Save Changes', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
