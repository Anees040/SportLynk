import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../services/notification_service.dart';
import '../../services/push_service.dart';

/// Per-category push / in-app toggles, quiet hours, and an honest answer to "why is
/// my phone quiet?".
///
/// WHERE THESE ARE ENFORCED
/// Not here. `jobs/pushJob.js` reads `users.notification_prefs` and the quiet window
/// before it calls FCM, so a muted category is muted for a user who never opens this
/// screen again and on a phone that is switched off. A preference the client honours
/// is a suggestion, not a preference. What this screen owns is the WORDING of that
/// contract -- in particular that in-app is not the same switch as push, and that the
/// feed keeps every row either way.
///
/// WHY THE CATEGORY LIST COMES FROM THE SERVER
/// `categories` and `unmutable` arrive with the preferences, derived from
/// `notificationTypes.js`. A category added in a later wave therefore appears here
/// with no client change, and `system` is named unmutable by the same file that
/// enforces it -- rather than by a const list in this screen that could drift out of
/// step with the job and quietly promise an opt-out that does not happen.
class NotificationPrefsScreen extends StatefulWidget {
  const NotificationPrefsScreen({super.key});

  @override
  State<NotificationPrefsScreen> createState() => _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState extends State<NotificationPrefsScreen> {
  final NotificationService _svc = NotificationService();

  NotificationPrefs? _p;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const Map<String, String> _labels = {
    'booking': 'Bookings',
    'match': 'Matches & challenges',
    'tournament': 'Tournaments',
    'wallet': 'Wallet & payments',
    'team': 'Teams',
    'chat': 'Chat messages',
    'venue': 'My venues',
    'review': 'Reviews',
    'system': 'Account & system',
  };

  static const Map<String, String> _hints = {
    'booking': 'Approvals, rejections, reminders, no-shows',
    'match': 'Challenges, results, verification, Elo',
    'tournament': 'Registration, brackets, fixtures, results',
    'wallet': 'Top-ups, withdrawals, refunds',
    'team': 'Join requests, roster changes',
    'chat': 'Only when you are not already in the chat',
    'venue': 'Approval and moderation of your venues',
    'review': 'New reviews and replies',
    'system': 'Suspensions and account changes — always on',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _tok => context.read<AuthProvider>().token;

  Future<void> _load() async {
    final t = _tok;
    if (t == null) {
      setState(() { _loading = false; _error = 'Sign in to change notification settings.'; });
      return;
    }
    final p = await _svc.prefs(t);
    if (p != null) PushService().applyPrefs(p);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _p = p;
      _error = p == null ? 'Could not load your settings. Pull to retry.' : null;
    });
  }

  /// Writes, then REPLACES local state with the server's echo.
  ///
  /// `PUT /preferences` normalises what it stores -- an unknown category is dropped
  /// and a malformed "25:99" falls back -- and returns what it actually kept. Showing
  /// the echo rather than the optimistic copy means the switch a user sees is the
  /// switch the job will read, so a silently-rejected value cannot look saved.
  Future<void> _save(NotificationPrefs next) async {
    final t = _tok;
    if (t == null) return;
    setState(() { _p = next; _saving = true; }); // optimistic, for the switch animation
    final echoed = await _svc.savePrefs(t, next);
    // The foreground banner gate lives in PushService, so it is handed the ECHO the
    // moment it lands: an in-app toggle takes effect on the next message, not on the
    // next app start.
    if (echoed != null) PushService().applyPrefs(echoed);
    if (!mounted) return;
    setState(() { _saving = false; if (echoed != null) _p = echoed; });
    if (echoed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save — check your connection')),
      );
      _load(); // fall back to the truth rather than leaving a lie on screen
    }
  }

  Future<void> _pick(bool start) async {
    final p = _p;
    if (p == null) return;
    final cur = _hm(start ? p.quietStart : p.quietEnd, start ? 22 : 7);
    final picked = await showTimePicker(context: context, initialTime: cur);
    if (picked == null || !mounted) return;
    final s = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    await _save(start ? p.copyWith(quietStart: s) : p.copyWith(quietEnd: s));
  }

  /// "22:00" -> TimeOfDay. The server validates this shape, so a fallback here is
  /// only for a row written before the validator existed.
  static TimeOfDay _hm(String s, int fallbackHour) {
    final m = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(s.trim());
    if (m == null) return TimeOfDay(hour: fallbackHour, minute: 0);
    final h = int.tryParse(m.group(1)!) ?? fallbackHour;
    final mi = int.tryParse(m.group(2)!) ?? 0;
    if (h > 23 || mi > 59) return TimeOfDay(hour: fallbackHour, minute: 0);
    return TimeOfDay(hour: h, minute: mi);
  }

  static String _pretty(String hm) {
    final t = _hm(hm, 0);
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h12:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.cardBg,
        surfaceTintColor: AppColors.cardBg,
        elevation: 0,
        title: Text(
          'Notification settings',
          style: GoogleFonts.inter(
            fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        ),
        bottom: _saving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2, color: AppColors.accent),
              )
            : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: _p == null ? _errorState() : _form(_p!),
            ),
    );
  }

  Widget _errorState() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
        children: [
          const Icon(Icons.cloud_off, size: 44, color: AppColors.textSecondary),
          const SizedBox(height: 14),
          Text(
            _error ?? 'Could not load your settings.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      );

  Widget _form(NotificationPrefs p) {
    // Server-owned order, with anything the server did not name filtered out. An
    // empty list (an old server) falls back to the labels this build knows.
    final cats = p.categories.isNotEmpty ? p.categories : _labels.keys.toList();
    final pushOn = context.watch<NotificationProvider>().pushConfigured;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        _deliveryNote(pushOn),
        const SizedBox(height: 14),
        _card([
          _switchRow(
            title: 'Mute everything',
            subtitle: p.muteAll
                ? 'Your phone stays silent. Notifications still arrive in the app.'
                : 'Turn this on to silence every push at once.',
            value: p.muteAll,
            onChanged: (v) => _save(p.copyWith(muteAll: v)),
            icon: p.muteAll ? Icons.notifications_off : Icons.notifications_active,
          ),
        ]),
        const SizedBox(height: 18),
        _sectionTitle('What you get notified about'),
        _sectionHint(
          'PUSH is the banner on your phone. IN-APP is the bell and the badge inside '
          'SportLynk. Turning push off never deletes a notification — you will still '
          'find it in your list.',
        ),
        const SizedBox(height: 8),
        _card([
          for (var i = 0; i < cats.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.divider),
            _categoryRow(p, cats[i]),
          ],
        ]),
        const SizedBox(height: 18),
        _sectionTitle('Quiet hours'),
        _sectionHint(
          'No push between these times (Pakistan time). Account and security alerts '
          'still come through.',
        ),
        const SizedBox(height: 8),
        _card([
          _switchRow(
            title: 'Enable quiet hours',
            subtitle: p.quietEnabled
                ? 'Silent from ${_pretty(p.quietStart)} to ${_pretty(p.quietEnd)}'
                : 'Off — push can arrive at any time',
            value: p.quietEnabled,
            onChanged: (v) => _save(p.copyWith(quietEnabled: v)),
            icon: Icons.bedtime_outlined,
          ),
          if (p.quietEnabled) ...[
            const Divider(height: 1, color: AppColors.divider),
            _timeRow('Start', p.quietStart, () => _pick(true)),
            const Divider(height: 1, color: AppColors.divider),
            _timeRow('End', p.quietEnd, () => _pick(false)),
          ],
        ]),
      ],
    );
  }

  /// The honest line about why the phone may be quiet.
  ///
  /// Three different problems have three different fixes, and the server is the only
  /// one that knows which it is: no Firebase key on the backend (`push.configured`
  /// false), no OS permission on this phone, or a preference below. Saying "push is
  /// on" when the server has no key would be the one wrong answer here.
  Widget _deliveryNote(bool configured) {
    final ready = PushService().isReady;
    final ok = configured && ready;
    final Color tint = ok ? AppColors.accentLight : const Color(0xFFFEF3C7);
    final Color fg = ok ? AppColors.success : const Color(0xFF92400E);
    final String msg = !configured
        ? 'Phone banners are not switched on for this server yet, so notifications '
            'arrive in the app only. Everything below still applies the moment they are.'
        : !ready
            ? 'This phone has not registered for banners. Allow notifications in your '
                'device settings, then reopen SportLynk.'
            : 'This phone is registered for banners.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.info_outline, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg,
                style: GoogleFonts.inter(fontSize: 12, height: 1.45, color: fg)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text(s,
            style: GoogleFonts.inter(
                fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      );

  Widget _sectionHint(String s) => Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: Text(s,
            style: GoogleFonts.inter(
                fontSize: 11.5, height: 1.45, color: AppColors.textSecondary)),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: children),
      );

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required IconData icon,
  }) =>
      SwitchListTile.adaptive(
        value: value,
        onChanged: _saving ? null : onChanged,
        activeThumbColor: AppColors.accent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        secondary: Icon(icon, size: 20, color: AppColors.textSecondary),
        title: Text(title,
            style: GoogleFonts.inter(
                fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        subtitle: Text(subtitle,
            style: GoogleFonts.inter(
                fontSize: 11.5, height: 1.35, color: AppColors.textSecondary)),
      );

  Widget _timeRow(String label, String hm, VoidCallback onTap) => ListTile(
        onTap: _saving ? null : onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: const Icon(Icons.schedule, size: 20, color: AppColors.textSecondary),
        title: Text(label,
            style: GoogleFonts.inter(
                fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_pretty(hm),
                style: GoogleFonts.inter(
                    fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.accent)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
          ],
        ),
      );

  /// One category, two toggles.
  ///
  /// An unmutable category (`system`) renders as a locked row rather than being
  /// hidden: a user is entitled to know that suspensions will always reach them, and
  /// a missing row reads as an oversight while a locked one reads as a decision.
  Widget _categoryRow(NotificationPrefs p, String cat) {
    final locked = p.unmutable.contains(cat);
    final label = _labels[cat] ?? _titleCase(cat);
    final hint = _hints[cat];
    // muteAll does not rewrite the per-category flags on the server, so the switches
    // keep their own values and are shown DISABLED instead of forced off. Turning the
    // master switch back off must restore exactly what the user had before.
    final dim = p.muteAll && !locked;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(label,
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: dim ? AppColors.textSecondary : AppColors.textPrimary,
                        )),
                    if (locked) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.lock_outline, size: 13, color: AppColors.textSecondary),
                    ],
                  ],
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(hint,
                        style: GoogleFonts.inter(
                            fontSize: 11, height: 1.3, color: AppColors.textSecondary)),
                  ),
              ],
            ),
          ),
          _mini(
            'Push',
            locked ? true : (p.push[cat] != false),
            locked || dim ? null : (v) => _save(p.copyWith(push: {...p.push, cat: v})),
          ),
          const SizedBox(width: 2),
          _mini(
            'In-app',
            locked ? true : (p.inApp[cat] != false),
            locked ? null : (v) => _save(p.copyWith(inApp: {...p.inApp, cat: v})),
          ),
        ],
      ),
    );
  }

  /// A labelled switch narrow enough for two of them on a phone.
  Widget _mini(String label, bool value, ValueChanged<bool>? onChanged) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 8.5,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: onChanged == null ? AppColors.disabled : AppColors.textSecondary,
              )),
          SizedBox(
            height: 28,
            child: Transform.scale(
              scale: 0.78,
              child: Switch(
                value: value,
                onChanged: _saving ? null : onChanged,
                activeThumbColor: AppColors.accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      );

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
