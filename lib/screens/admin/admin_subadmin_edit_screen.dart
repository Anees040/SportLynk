import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';

/// Create a new sub-admin, or edit an existing one's permissions.
///
/// Create mode (`existing == null`): name, email, password and a permission set.
/// Edit mode: the name and the permission set only — the email is the login identity
/// and is shown read-only, and a password is not changed here. The permission
/// checkboxes are rendered from the server [catalog], never a hard-coded list, so this
/// screen can never offer a permission the backend does not recognise.
class AdminSubAdminEditScreen extends StatefulWidget {
  final List<PermissionDef> catalog;
  final AdminAccount? existing;

  const AdminSubAdminEditScreen({
    required this.catalog,
    this.existing,
    super.key,
  });

  @override
  State<AdminSubAdminEditScreen> createState() => _AdminSubAdminEditScreenState();
}

class _AdminSubAdminEditScreenState extends State<AdminSubAdminEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final AdminService _service = AdminService();

  late final TextEditingController _name;
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final Set<String> _selected = {};

  bool _obscure = true;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    if (_isEdit) _selected.addAll(widget.existing!.permissions);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _token =>
      Provider.of<AuthProvider>(context, listen: false).token ?? '';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final permissions = _selected.toList();
      final Map<String, dynamic> r;
      if (_isEdit) {
        r = await _service.updateAdmin(
          _token,
          widget.existing!.id,
          permissions: permissions,
          name: _name.text,
        );
      } else {
        r = await _service.createSubAdmin(
          _token,
          name: _name.text,
          email: _email.text,
          password: _password.text,
          permissions: permissions,
        );
      }
      if (!mounted) return;
      if (r['success'] == true) {
        Navigator.pop(context, true);
      } else {
        // Surface the server's own reason — a taken email, a short password, an
        // unknown permission key — rather than a generic failure.
        _snack(r['message']?.toString() ?? 'Could not save. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(_isEdit ? 'Edit sub-admin' : 'Add sub-admin',
            style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _field(
              controller: _name,
              label: 'Full name',
              icon: Icons.badge_outlined,
              validator: (v) =>
                  (v == null || v.trim().length < 3) ? 'At least 3 characters' : null,
            ),
            const SizedBox(height: 16),
            if (_isEdit)
              _readOnlyEmail()
            else ...[
              _field(
                controller: _email,
                label: 'Email (used to log in)',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  final s = (v ?? '').trim();
                  final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s);
                  return ok ? null : 'Enter a valid email';
                },
              ),
              const SizedBox(height: 16),
              _field(
                controller: _password,
                label: 'Temporary password',
                icon: Icons.lock_outline,
                obscure: _obscure,
                suffix: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: AppColors.textSecondary),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                validator: (v) =>
                    (v == null || v.length < 8) ? 'At least 8 characters' : null,
              ),
              const SizedBox(height: 6),
              Text('Share this with the sub-admin. They can change it later from Forgot Password.',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 24),
            Text('Permissions',
                style: GoogleFonts.poppins(
                    fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            Text('Choose exactly what this admin can do. You can change these any time.',
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ...widget.catalog.map(_permTile),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _busy ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : Text(_isEdit ? 'Save changes' : 'Create sub-admin',
                        style: GoogleFonts.poppins(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      obscureText: obscure,
      style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error),
        ),
      ),
    );
  }

  Widget _readOnlyEmail() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          const Icon(Icons.email_outlined, color: AppColors.textSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Email (login — cannot be changed)',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              Text(widget.existing?.email ?? '—',
                  style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );

  Widget _permTile(PermissionDef p) {
    final on = _selected.contains(p.key);
    return GestureDetector(
      onTap: () => setState(() => on ? _selected.remove(p.key) : _selected.add(p.key)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.accent : AppColors.border, width: on ? 1.5 : 1),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.label,
                  style: GoogleFonts.poppins(
                      fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              if (p.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(p.description,
                    style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary)),
              ],
            ]),
          ),
          const SizedBox(width: 12),
          Checkbox(
            value: on,
            activeColor: AppColors.accent,
            onChanged: (_) => setState(() => on ? _selected.remove(p.key) : _selected.add(p.key)),
          ),
        ]),
      ),
    );
  }
}
