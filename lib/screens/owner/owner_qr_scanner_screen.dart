import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class OwnerQrScannerScreen extends StatefulWidget {
  const OwnerQrScannerScreen({super.key});
  @override
  State<OwnerQrScannerScreen> createState() => _OwnerQrScannerScreenState();
}

class _OwnerQrScannerScreenState extends State<OwnerQrScannerScreen> {
  final MobileScannerController _ctrl = MobileScannerController();
  bool _processing = false;
  bool _manualEntry = false;
  final _manualCtrl = TextEditingController();
  static String get _base => ApiConstants.baseUrl;

  // Countdown timer — 30 minutes window
  final int _seconds = 30 * 60;
  late final StreamSubscription<int> _timerSub;
  int _displaySeconds = 30 * 60;

  @override
  void initState() {
    super.initState();
    _timerSub = Stream.periodic(const Duration(seconds: 1), (i) => _seconds - i).listen((s) {
      if (mounted) setState(() => _displaySeconds = s.clamp(0, _seconds));
    });
  }

  @override
  void dispose() {
    _timerSub.cancel();
    _ctrl.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _processQr(String qrCode) async {
    if (_processing) return;
    setState(() => _processing = true);
    _ctrl.stop();
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('$_base/owner/scan-qr'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'qrCode': qrCode}),
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _showSuccess(data['data'] as Map<String, dynamic>);
        } else {
          _showError(data['message'] ?? 'Invalid QR code');
        }
      }
    } catch (_) {
      if (mounted) _showError('Network error. Please try again.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showSuccess(Map<String, dynamic> d) {
    _ctrl.stop();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle, color: AppColors.accent, size: 40),
          ),
          const SizedBox(height: 16),
          Text(
            'Check-in Successful!',
            style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              _detailRow('Player', d['playerName']?.toString() ?? ''),
              _detailRow('Venue', d['venueName']?.toString() ?? ''),
              _detailRow('Date', d['slotDate']?.toString().split('T').first ?? ''),
              _detailRow(
                'Time',
                '${(d['startTime']?.toString() ?? '').length >= 5 ? d['startTime'].toString().substring(0, 5) : ''} – ${(d['endTime']?.toString() ?? '').length >= 5 ? d['endTime'].toString().substring(0, 5) : ''}',
              ),
              const Divider(color: AppColors.border),
              _detailRow(
                'Payment Received',
                'PKR ${(d['amount'] as num?)?.toStringAsFixed(0) ?? '0'}',
                valueColor: AppColors.success,
              ),
              _detailRow(
                'Your New Balance',
                'PKR ${(d['newOwnerBalance'] as num?)?.toStringAsFixed(0) ?? '0'}',
                valueColor: AppColors.accent,
              ),
            ]),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text('Done', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_manualEntry) _ctrl.start();
    });
  }

  Future<void> _noShow() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) {
        final ctrl = TextEditingController();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Mark No-Show', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Enter the Booking ID to mark as no-show and forfeit their deposit.',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: GoogleFonts.poppins(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Booking ID (UUID)',
                hintStyle: GoogleFonts.poppins(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text('Confirm', style: GoogleFonts.poppins(color: Colors.white)),
            ),
          ],
        );
      },
    );
    if (id == null || id.isEmpty) return;
    if (!mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('$_base/owner/no-show/$id'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data['message'] ?? 'Done', style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: data['success'] == true ? AppColors.accent : AppColors.error,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final mins = (_displaySeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_displaySeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text('SportLynk', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.accent,
            child: const Icon(Icons.person, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: Stack(children: [
        // Camera feed
        if (!_manualEntry)
          MobileScanner(
            controller: _ctrl,
            onDetect: (capture) {
              final barcode = capture.barcodes.firstOrNull;
              if (barcode?.rawValue != null) _processQr(barcode!.rawValue!);
            },
          ),

        // Manual entry mode
        if (_manualEntry)
          Container(
            color: Colors.black87,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    'Enter Booking ID',
                    style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _manualCtrl,
                    style: GoogleFonts.poppins(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Paste or type the booking QR code',
                      hintStyle: GoogleFonts.poppins(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.white12,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.accent, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _manualEntry = false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white30),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: Text('Scan Instead', style: GoogleFonts.poppins()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          if (_manualCtrl.text.isNotEmpty) _processQr(_manualCtrl.text.trim());
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: Text('Verify', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),

        // Overlay UI on camera
        if (!_manualEntry)
          Column(children: [
            // Booking window timer
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.accent, width: 1.5),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    'BOOKING WINDOW',
                    style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 10, letterSpacing: 1),
                  ),
                  Text(
                    '$mins:$secs',
                    style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                ]),
              ),
            ),

            // Scanner frame
            Expanded(
              child: Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.accent, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Stack(children: [
                    // Corner marks
                    ...[Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight]
                        .map((a) => Align(
                              alignment: a,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.only(
                                    topLeft: a == Alignment.topLeft ? const Radius.circular(4) : Radius.zero,
                                    topRight: a == Alignment.topRight ? const Radius.circular(4) : Radius.zero,
                                    bottomLeft: a == Alignment.bottomLeft ? const Radius.circular(4) : Radius.zero,
                                    bottomRight: a == Alignment.bottomRight ? const Radius.circular(4) : Radius.zero,
                                  ),
                                ),
                              ),
                            )),
                    if (_processing)
                      const Center(
                        child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 3),
                      ),
                  ]),
                ),
              ),
            ),

            // Bottom controls
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: Column(children: [
                Text(
                  "Scan the player's booking QR code",
                  style: GoogleFonts.poppins(color: Colors.white, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() => _manualEntry = true),
                  child: Text(
                    'Or enter Booking ID manually',
                    style: GoogleFonts.poppins(
                      color: AppColors.accent,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _noShow,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: const BorderSide(color: AppColors.error, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      'Mark as No-Show (Forfeit Deposit)',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
      ]),
    );
  }

  Widget _detailRow(String l, String v, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.end,
              style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: valueColor ?? AppColors.textPrimary),
            ),
          ),
        ]),
      );
}
