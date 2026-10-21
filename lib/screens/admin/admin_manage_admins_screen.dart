import 'package:flutter/material.dart';
import '../../widgets/stable_refresh_indicator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';
import '../../widgets/network_error_view.dart';
import 'admin_subadmin_edit_screen.dart';

/// FR10.* extension — the super admin's screen for managing the admin tier.
///
/// Reached only by the super admin (the tile is shown to no one else and the route is
/// `requireSuperAdmin`). Lists every admin, lets the super admin add a sub-admin, edit
/// a sub-admin's permissions, and remove or restore access. Every decision is the
/// server's: the permission catalog is fetched, not hard-coded, and each write shows
/// the server's own message on failure.
class AdminManageAdminsScreen extends StatefulWidget {
  const AdminManageAdminsScreen({super.key});

  @override
  State<AdminManageAdminsScreen> createState() => _AdminManageAdminsScreenState();
}

class _AdminManageAdminsScreenState extends State<AdminManageAdminsScreen> {
  final AdminService _service = AdminService();

  List<AdminAccount> _admins = const [];
  List<PermissionDef> _catalog = const [];
  bool _loading = true;
  bool _error = false;
  bool _busy = false; // a write is in flight; guards double taps

  String get _token =>
      Provider.of<AuthProvider>(context, listen: false).token ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = _admins.isEmpty; });
    final token = _token;
    final results = await Future.wait([
      _service.admins(token),
      _service.permissionCatalog(token),
    ]);
    if (!mounted) return;
    final page = results[0] as AdminPage<AdminAccount>;
    final catalog = results[1] as List<PermissionDef>;
    setState(() {
      _loading = false;
      // A failed read of either half is an error with a retry, never an empty list
      // presented as "no admins" — the super admin always exists.
      _error = !page.ok || catalog.isEmpty;
      if (page.ok) _admins = page.items;
      if (catalog.isNotEmpty) _catalog = catalog;
    });
  }

  /// key -> human label, from the server catalog. Falls back to the raw key so a
  /// permission the catalog does not describe still reads as something.
  String _label(String key) {
    for (final p in _catalog) {
      if (p.key == key) return p.label;
    }
    return key;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openCreate() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AdminSubAdminEditScreen(catalog: _catalog),
      ),
    );
    if (created == true) _load();
  }

  Future<void> _openEdit(AdminAccount a) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AdminSubAdminEditScreen(catalog: _catalog, existing: a),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmRemove(AdminAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove access?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Text(
          '${a.name} will be signed out and will no longer be able to log in. '
          'Their permissions are cleared. You can restore access later.',
          style: GoogleFonts.poppins(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true) _write(() => _service.removeAdmin(_token, a.id));
  }

  Future<void> _restore(AdminAccount a) async =>
      _write(() => _service.restoreAdmin(_token, a.id));

  /// Run one write, surface the server's message either way, and reload on success.
  Future<void> _write(Future<Map<String, dynamic>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await action();
      if (!mounted) return;
      _snack(r['message']?.toString() ?? (r['success'] == true ? 'Done' : 'Failed'));
      if (r['success'] == true) await _load();
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
        title: Text('Manage Admins',
            style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      floatingActionButton: (_loading || _error)
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              onPressed: _busy ? null : _openCreate,
              icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
              label: Text('Add sub-admin',
                  style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_error) {
      return NetworkErrorView(
        message: 'Could not load administrators. Check your connection and try again.',
        onRetry: _load,
      );
    }

    final subs = _admins.where((a) => !a.isSuperAdmin).toList();
    return StableRefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _sectionLabel('SUPER ADMIN'),
          const SizedBox(height: 8),
          ..._admins.where((a) => a.isSuperAdmin).map(_adminCard),
          const SizedBox(height: 20),
          _sectionLabel('SUB-ADMINS'),
          const SizedBox(height: 8),
          if (subs.isEmpty)
            _emptySubs()
          else
            ...subs.map(_adminCard),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: GoogleFonts.poppins(
            fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textSecondary, letterSpacing: 0.5),
      );

  Widget _emptySubs() => Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Icon(Icons.group_add_outlined, size: 44, color: AppColors.textSecondary.withValues(alpha: 0.4)),
          const SizedBox(height: 10),
          Text('No sub-admins yet',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text('Add one to delegate specific admin tasks.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      );

  Widget _adminCard(AdminAccount a) {
    final removed = !a.active;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: removed ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: a.isSuperAdmin ? AppColors.primary : AppColors.accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Icon(a.isSuperAdmin ? Icons.shield_moon_outlined : Icons.person_outline,
                  color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(a.name,
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (removed) ...[
                  const SizedBox(width: 8),
                  _tag('REMOVED', AppColors.error),
                ],
              ]),
              const SizedBox(height: 2),
              Text(a.email ?? a.phone ?? '—',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (!a.isSuperAdmin) _menu(a),
        ]),
        const SizedBox(height: 12),
        if (a.isSuperAdmin)
          _tag('ALL PERMISSIONS', AppColors.primary)
        else if (a.permissions.isEmpty)
          Text(removed ? 'Access removed' : 'No permissions granted',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, fontStyle: FontStyle.italic))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: a.permissions.map((k) => _permChip(_label(k))).toList(),
          ),
      ]),
    );
  }

  Widget _menu(AdminAccount a) => PopupMenuButton<String>(
        enabled: !_busy,
        icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
        onSelected: (v) {
          if (v == 'edit') _openEdit(a);
          if (v == 'remove') _confirmRemove(a);
          if (v == 'restore') _restore(a);
        },
        itemBuilder: (_) => [
          if (a.active)
            PopupMenuItem(value: 'edit', child: Text('Edit permissions', style: GoogleFonts.poppins())),
          if (a.active)
            PopupMenuItem(
              value: 'remove',
              child: Text('Remove access', style: GoogleFonts.poppins(color: AppColors.error)),
            )
          else
            PopupMenuItem(value: 'restore', child: Text('Restore access', style: GoogleFonts.poppins())),
        ],
      );

  Widget _permChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w600)),
      );

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: GoogleFonts.poppins(fontSize: 9, color: color, fontWeight: FontWeight.bold)),
      );
}
