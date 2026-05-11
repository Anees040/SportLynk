import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class AdminRegistrationDetailScreen extends StatefulWidget {
  final Map<String, dynamic> registration;
  final VoidCallback? onReviewed;
  const AdminRegistrationDetailScreen({
    super.key,
    required this.registration,
    this.onReviewed,
  });

  @override
  State<AdminRegistrationDetailScreen> createState() =>
      _AdminRegistrationDetailScreenState();
}

class _AdminRegistrationDetailScreenState
    extends State<AdminRegistrationDetailScreen> {
  bool _processing = false;
  final _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  String get _base => ApiConstants.baseUrl;
  String get _token =>
      Provider.of<AuthProvider>(context, listen: false).token ?? '';

  Future<void> _approve() async {
    setState(() => _processing = true);
    try {
      final id = widget.registration['id'];
      final r = await http.patch(
        Uri.parse('$_base/admin/registrations/$id/approve'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
      );
      final d = jsonDecode(r.body);
      if (!mounted) return;
      if (d['success'] == true) {
        _showResult(true, 'Owner approved! Venue created successfully.');
        widget.onReviewed?.call();
        Navigator.pop(context);
      } else {
        _showResult(false, d['message'] ?? 'Approval failed');
      }
    } catch (e) {
      if (mounted) _showResult(false, 'Network error: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _showRejectDialog() async {
    _reasonCtrl.clear();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Reject Registration',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Provide a clear reason for rejection. The owner will see this.',
              style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _reasonCtrl,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'e.g. CNIC photos are blurry. Please resubmit with clear images.',
              hintStyle: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border)),
            ),
            style: GoogleFonts.poppins(fontSize: 13),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              if (_reasonCtrl.text.trim().length < 5) return;
              Navigator.pop(ctx);
              _reject(_reasonCtrl.text.trim());
            },
            child: Text('Reject', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _reject(String reason) async {
    setState(() => _processing = true);
    try {
      final id = widget.registration['id'];
      final r = await http.patch(
        Uri.parse('$_base/admin/registrations/$id/reject'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'reason': reason}),
      );
      final d = jsonDecode(r.body);
      if (!mounted) return;
      if (d['success'] == true) {
        _showResult(false, 'Registration rejected.');
        widget.onReviewed?.call();
        Navigator.pop(context);
      } else {
        _showResult(false, d['message'] ?? 'Rejection failed');
      }
    } catch (e) {
      if (mounted) _showResult(false, 'Network error: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showResult(bool success, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: success ? AppColors.accent : AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.registration;
    final vstatus = reg['verification_status'] as String? ?? 'pending';
    final isPending = vstatus == 'pending';
    final groundPhotos = (reg['ground_photos'] as List?) ?? [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Registration Review',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      bottomNavigationBar: isPending ? _buildActionBar() : null,
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Status Banner
          _statusBanner(vstatus, reg['rejection_reason']),
          const SizedBox(height: 16),

          // Owner Info
          _sectionHeader(Icons.person_outline, 'Owner Information'),
          _infoCard([
            _row('Name', reg['owner_name'] ?? '—'),
            _row('Phone', reg['owner_phone'] ?? '—'),
            _row('Email', reg['owner_email'] ?? '—'),
            _row('CNIC', reg['cnic_number'] ?? '—'),
          ]),
          const SizedBox(height: 16),

          // Venue Info
          _sectionHeader(Icons.stadium_outlined, 'Venue Details'),
          _infoCard([
            _row('Ground Name', reg['ground_name'] ?? reg['business_name'] ?? '—'),
            _row('City', reg['city'] ?? '—'),
            _row('Address', reg['full_address'] ?? '—'),
            _row('Sport Types', (reg['sport_types'] as List?)?.join(', ') ?? '—'),
            _row('Ground Type', reg['ground_type'] ?? '—'),
            _row('Price/Hour', 'PKR ${reg['price_per_hour'] ?? '—'}'),
            _row('Hours', '${reg['operating_hours_from'] ?? '—'} – ${reg['operating_hours_to'] ?? '—'}'),
          ]),
          const SizedBox(height: 16),

          // Ground Photos
          if (groundPhotos.isNotEmpty) ...[
            _sectionHeader(Icons.photo_library_outlined, 'Ground Photos (${groundPhotos.length})'),
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: groundPhotos.length,
                itemBuilder: (_, i) => Container(
                  width: 200,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: AppColors.primary),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      groundPhotos[i].toString(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, e, st) => const Center(
                          child: Icon(Icons.broken_image_outlined,
                              color: Colors.white38, size: 40)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // CNIC Documents
          _sectionHeader(Icons.credit_card, 'Identity Documents'),
          Row(children: [
            Expanded(child: _docThumbnail('CNIC Front', reg['cnic_front_url'])),
            const SizedBox(width: 10),
            Expanded(child: _docThumbnail('CNIC Back', reg['cnic_back_url'])),
          ]),
          const SizedBox(height: 10),
          _docThumbnail('Selfie with CNIC', reg['selfie_with_cnic_url'], fullWidth: true),
          const SizedBox(height: 16),

          // Additional Docs
          if (reg['utility_bill_url'] != null || reg['ownership_proof_url'] != null) ...[
            _sectionHeader(Icons.folder_outlined, 'Additional Documents'),
            if (reg['utility_bill_url'] != null)
              _docThumbnail('Utility Bill', reg['utility_bill_url'], fullWidth: true),
            const SizedBox(height: 10),
            if (reg['ownership_proof_url'] != null)
              _docThumbnail('Ownership Proof', reg['ownership_proof_url'], fullWidth: true),
            const SizedBox(height: 16),
          ],

          // Submission Date
          _infoCard([
            _row('Submitted', _formatDate(reg['created_at'])),
            if (reg['reviewed_at'] != null)
              _row('Reviewed', _formatDate(reg['reviewed_at'])),
          ]),
          const SizedBox(height: 80),
        ]),
      ),
    );
  }

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, -4))
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _processing ? null : _showRejectDialog,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: const BorderSide(color: AppColors.error),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: Text('Reject',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _processing ? null : _approve,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 4,
                shadowColor: AppColors.accent.withValues(alpha: 0.4),
              ),
              icon: _processing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.check_circle_outline, size: 18),
              label: Text(_processing ? 'Processing...' : 'Approve & Create Venue',
                  style: GoogleFonts.poppins(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statusBanner(String status, dynamic reason) {
    final Color color;
    final IconData icon;
    final String title;
    if (status == 'approved') {
      color = AppColors.accent;
      icon = Icons.check_circle;
      title = 'Approved — Venue is live';
    } else if (status == 'rejected') {
      color = AppColors.error;
      icon = Icons.cancel;
      title = 'Rejected';
    } else {
      color = AppColors.warning;
      icon = Icons.pending_actions;
      title = 'Pending Review';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(title,
              style: GoogleFonts.poppins(
                  color: color, fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
        if (status == 'rejected' && reason != null) ...[
          const SizedBox(height: 6),
          Text('Reason: $reason',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ]),
    );
  }

  Widget _sectionHeader(IconData icon, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(icon, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(title,
              style: GoogleFonts.poppins(
                  fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        ]),
      );

  Widget _infoCard(List<Widget> rows) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: rows),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.textSecondary)),
          ),
          Expanded(
              child: Text(value,
                  style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary))),
        ]),
      );

  Widget _docThumbnail(String label, dynamic url, {bool fullWidth = false}) {
    final hasUrl = url != null && url.toString().startsWith('http');
    return Container(
      height: 120,
      width: fullWidth ? double.infinity : null,
      decoration: BoxDecoration(
        color: hasUrl ? AppColors.primary : AppColors.inputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: hasUrl
          ? Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.network(
                  url.toString(),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, st) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white38, size: 32)),
                ),
              ),
              Positioned(
                bottom: 6,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(label,
                      style: GoogleFonts.poppins(
                          color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                ),
              ),
            ])
          : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.upload_file_outlined,
                  color: AppColors.textSecondary, size: 28),
              const SizedBox(height: 6),
              Text(label,
                  style: GoogleFonts.poppins(
                      fontSize: 11, color: AppColors.textSecondary),
                  textAlign: TextAlign.center),
              Text('Not uploaded',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: AppColors.disabled)),
            ]),
    );
  }

  String _formatDate(dynamic d) {
    if (d == null) return '—';
    final dt = DateTime.tryParse(d.toString());
    if (dt == null) return d.toString();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}
