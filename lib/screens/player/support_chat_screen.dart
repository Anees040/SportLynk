import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/assistant.dart';
import '../../providers/assistant_controller.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/assistant/scout_bits.dart';
import '../../widgets/assistant/scout_bubble.dart';
import '../../widgets/assistant/scout_chips.dart';
import '../../widgets/assistant/scout_theme.dart';
import '../../widgets/assistant/scout_typing.dart';

/// The "Live Chat" tile on Help & Support, made real.
///
/// It is deliberately not the Scout tab reached through the home FAB. A player who
/// taps "Live Chat" from a support screen wants help with a problem, not their last
/// half-finished booking conversation — so this opens on a clean slate framed as
/// support, while the assistant that answers is the same Scout underneath. That reuse
/// is the whole point: the transcript, the idempotent turns, the retry-on-failure and
/// the graceful degradation when the language model is down are the parts that are
/// hard to get right, and duplicating them for a second chat surface would be two
/// implementations to keep honest instead of one.
///
/// Two things are stated plainly rather than implied. Scout is an assistant, not a
/// person — the header and the empty state say so, and "Email Us" on the screen behind
/// this one is the route to a human. And a support conversation is a Scout
/// conversation: it is saved as one, so it can resurface in the Scout tab later. That
/// is honest about what happened rather than a second, hidden history.
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key});

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  /// The support address, shown on the screen behind this one and offered again here
  /// whenever Scout cannot help — never a dead end.
  static const String _supportEmail = 'support@sportlynk.com';

  AssistantController? _c;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  String? _tailId;
  bool _wasBusy = false;

  /// Scout's palette for this build, derived from the platform brightness rather than
  /// read through [ScoutTheme.of] — this State's context sits above the [Theme] that
  /// [build] installs, so `of` here would resolve the app's light-only theme.
  ScoutTheme get _palette =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark
      ? ScoutTheme.dark
      : ScoutTheme.light;

  /// The four openers, framed as support topics. Each is a real, server-executed
  /// action, not typed text, so it bypasses the intent model and therefore works
  /// unchanged when that model is offline — which is exactly when a support surface
  /// most needs to still answer.
  static const List<ScoutChip> _supportChips = [
    ScoutChip(label: 'Cancellations & refunds', action: 'refund_policy'),
    ScoutChip(label: 'Topping up my wallet', action: 'topup_help'),
    ScoutChip(label: 'Check my bookings', action: 'my_bookings'),
    ScoutChip(label: 'What can Scout help with?', action: 'capability_menu'),
  ];

  @override
  void initState() {
    super.initState();
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token != null && token.isNotEmpty) {
      final c = AssistantController(token: token);
      c.addListener(_onControllerChanged);
      _c = c;
      // A support chat opens clean, not on the user's last general conversation.
      c.start(loadHistory: false);
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_onControllerChanged);
    _c?.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(_syncScroll);
  }

  /// Follow the newest message, and only the newest — a change to the tail is what a
  /// reply is, and nothing else here moves the transcript.
  void _syncScroll() {
    final c = _c;
    if (c == null) return;
    final tail = c.messages.isEmpty ? null : c.messages.last.id;
    if (tail == _tailId && c.busy == _wasBusy) return;
    final first = _tailId == null && tail != null;
    _tailId = tail;
    _wasBusy = c.busy;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(animate: !first));
  }

  void _toBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  // Conversation moves

  void _send() {
    final text = _input.text.trim();
    final c = _c;
    if (text.isEmpty || c == null || c.busy) return;
    _input.clear();
    c.sendText(text);
    _focus.requestFocus();
  }

  void _chip(ScoutChip chip) {
    final c = _c;
    if (c == null || c.busy) return;
    c.sendChip(chip);
  }

  // Client moves

  /// Leave the chat for a screen Scout named in `meta.screen`.
  ///
  /// This surface is pushed on top of the player shell, so the five tabs are not
  /// ours to switch — a jump to one would misname where the user would land. The
  /// two screens that are their own route are pushed; a tab is named in words
  /// instead, which is honest and still points the way. Nothing here is a dead end.
  void _goScreen(String screen) {
    final key = screen.trim().toLowerCase();
    const routes = {'venues': '/find-venues', 'tournaments': '/tournaments'};
    final route = routes[key];
    if (route != null) {
      Navigator.of(context).pushNamed(route);
      return;
    }
    const tabs = {
      'home': 'Home',
      'bookings': 'My Bookings',
      'teams': 'Teams',
      'wallet': 'Wallet',
      'profile': 'Profile',
    };
    final label = tabs[key];
    _toast(label != null
        ? 'That lives on the $label tab, back in the app.'
        : 'That screen is not in this build yet.');
  }

  /// Hand a `map` card to the phone's maps app: the geo pin first, then the https
  /// URL every phone can open. `canLaunchUrl` is not consulted for `geo:` — on
  /// Android 11+ it answers for declared intent queries, not for what is installed.
  Future<void> _directions(CardData d) async {
    final geo = d.strOrNull('geoUri');
    final web = d.strOrNull('mapsUrl');
    for (final raw in [if (d.flag('hasPin')) geo, web]) {
      if (raw == null) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (_) {
        // Next candidate.
      }
    }
    if (mounted) _toast('No maps app could open this location.');
  }

  /// The route to a human, offered wherever Scout might not be enough. Opens the
  /// mail app on a pre-addressed message; if no client answers — common on the web
  /// build and on phones with no mail app configured — the address is copied and
  /// named, so the door is never merely shut.
  Future<void> _emailSupport() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      queryParameters: {'subject': 'SportLynk support'},
    );
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Fall through to the clipboard.
    }
    if (!mounted) return;
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    if (mounted) _toast('No mail app opened. Address copied: $_supportEmail');
  }

  /// A one-off message. Both colours are stated because the snackbar is built above
  /// the [Theme] this screen installs and would otherwise take the app's light
  /// defaults — pale text on a pale surface.
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message,
            style: const TextStyle(color: ScoutTheme.onToastSurface)),
        backgroundColor: ScoutTheme.toastSurface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Theme(
      data: ScoutTheme.data(MediaQuery.platformBrightnessOf(context)),
      child: Scaffold(
        backgroundColor: _palette.canvas,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: c == null
              ? _signedOut()
              : Column(
                  children: [
                    _header(c),
                    if (c.notice != null) _noticeBar(c),
                    Expanded(child: _body(c)),
                    if (c.busy) const ScoutTyping(),
                    if (c.nluOffline) _offlineBar(c),
                    _composer(c),
                  ],
                ),
        ),
      ),
    );
  }

  /// Only reachable if the route is opened without a session — Help & Support sits
  /// behind auth, so this is a guard rather than a path, and it still offers the
  /// human route because that one needs no sign-in.
  Widget _signedOut() {
    final t = _palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ScoutAvatar(size: 54),
            const SizedBox(height: 16),
            Text(
              'Sign in to use support chat',
              style: TextStyle(
                color: t.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Scout answers from your own bookings and wallet, so it needs to know '
              'who you are. You can still email us in the meantime.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.inkSoft, fontSize: 12.5, height: 1.45),
            ),
            const SizedBox(height: 18),
            TextButton(
              onPressed: _emailSupport,
              child: const Text('Email support'),
            ),
          ],
        ),
      ),
    );
  }

  // Header

  /// A hand-built bar, not an [AppBar]: the status line under the title says plainly
  /// that Scout is an assistant rather than a person, which an AppBar title cannot
  /// hold as a second line without fighting its own centring. The mail action keeps
  /// the human route one tap away from anywhere in the conversation.
  Widget _header(AssistantController c) {
    final t = _palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded, size: 21),
            color: t.inkSoft,
            tooltip: 'Back',
          ),
          const ScoutAvatar(size: 32),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Support',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: 1),
                _statusLine(c, t),
              ],
            ),
          ),
          _barAction(
            icon: Icons.mail_outline_rounded,
            tooltip: 'Email support',
            onTap: _emailSupport,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  /// The dot-and-caption line under the title: green when idle, amber while a turn
  /// is in flight, and honest about what Scout is when there is nothing to report.
  Widget _statusLine(AssistantController c, ScoutTheme t) {
    return Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.busy ? t.money : t.good,
          ),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            c.booting
                ? 'Opening…'
                : c.busy
                    ? 'Working on it'
                    : 'Scout, an assistant — not a person',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.inkFaint, fontSize: 10.5),
          ),
        ),
      ],
    );
  }

  Widget _barAction({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final t = _palette;
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      color: onTap == null ? t.inkFaint : t.inkSoft,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      padding: EdgeInsets.zero,
    );
  }

  // Notices

  /// App-level errors — a chat that would not load, a rating that would not save.
  /// Conversation problems arrive as bubbles; these do not deserve a fake turn.
  Widget _noticeBar(AssistantController c) {
    final t = _palette;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.fromLTRB(11, 9, 5, 9),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: t.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.notice!,
              style: TextStyle(color: t.ink, fontSize: 11.5, height: 1.35),
            ),
          ),
          IconButton(
            onPressed: c.dismissNotice,
            icon: const Icon(Icons.close_rounded, size: 15),
            color: t.inkSoft,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }

  /// The classifier is down. On a support surface that matters twice over: the
  /// topics below still work, because a chip runs its action without the model, and
  /// the mail icon above is the human alternative. Both are named, so the outage
  /// describes a detour rather than a dead end.
  Widget _offlineBar(AssistantController c) {
    final t = _palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 8, 4, 8),
        decoration: BoxDecoration(
          color: t.money.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: t.money.withValues(alpha: 0.32)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 15, color: t.money),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Scout cannot read typed messages right now — its language model is '
                'offline. The topics below still work, or email us for a person.',
                style: TextStyle(color: t.ink, fontSize: 11.5, height: 1.35),
              ),
            ),
            IconButton(
              onPressed: c.dismissNluNotice,
              icon: const Icon(Icons.close_rounded, size: 15),
              color: t.inkSoft,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              tooltip: 'Dismiss',
            ),
          ],
        ),
      ),
    );
  }

  // Transcript

  /// The support conversation. It opens blank and never pages older history — this
  /// surface is started with `loadHistory: false` — so there is no top "load
  /// earlier" slot and no date separators to draw, unlike the full Scout tab.
  Widget _body(AssistantController c) {
    if (c.booting) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: _palette.accent),
        ),
      );
    }
    if (c.isEmpty) return _empty(c);

    final actions = ScoutCardActions(
      onChip: _chip,
      onScreen: _goScreen,
      onDirections: _directions,
      enabled: !c.busy,
    );
    final msgs = c.messages;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final msg = msgs[i];
        return ScoutMessageGroup(
          key: ValueKey(msg.id),
          msg: msg,
          actions: actions,
          onRetry: c.retry,
          onVote: c.vote,
          onExplain: (m) => showScoutExplainSheet(context, m),
        );
      },
    );
  }

  // Empty state

  /// A first screen has one job: make the first message easy. It says what Scout is
  /// — an assistant, not a person — names the topics it can actually settle, and
  /// puts the four support chips right there. Each chip is a server-executed action,
  /// so the topics answer even when the classifier is offline. A quieter line offers
  /// the human route for anyone who would rather not deal with software at all.
  Widget _empty(AssistantController c) {
    final t = _palette;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      children: [
        const Center(child: ScoutAvatar(size: 60)),
        const SizedBox(height: 18),
        Text(
          'How can we help?',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: t.ink,
            fontSize: 21,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          "Scout is SportLynk's assistant, not a person. It can sort out most "
          'account, booking and wallet questions right here — pick a topic, or type '
          'your own.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.inkSoft, fontSize: 12.5, height: 1.5),
        ),
        const SizedBox(height: 22),
        Center(
          child: ScoutChipsWrap(
            chips: _supportChips,
            onTap: _chip,
            enabled: !c.busy,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: TextButton.icon(
            onPressed: _emailSupport,
            icon: Icon(Icons.mail_outline_rounded, size: 15, color: t.inkSoft),
            label: Text(
              'Prefer a person? Email support',
              style: TextStyle(color: t.inkSoft, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  // Composer

  /// The hint tracks the server's own dialog state, so it never promises something
  /// the next message will not do. A support turn can still reach a confirm — a
  /// cancellation asked for through "Check my bookings" ends in one — so those
  /// states are honoured here exactly as they are on the full Scout tab.
  String _hint(AssistantController c) {
    switch (c.fsm) {
      case ScoutFsm.awaitingConfirm:
        return 'Reply “yes” to go ahead, or “no”';
      case ScoutFsm.awaitingChoice:
        return 'Pick one above, or type it';
      case ScoutFsm.slotFilling:
        return 'Answer, or add a detail';
      case ScoutFsm.idle:
        return 'Describe your problem…';
    }
  }

  Widget _composer(AssistantController c) {
    final t = _palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: t.canvas,
        border: Border(top: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: BoxDecoration(
                color: t.bubble,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: t.line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: t.ink, fontSize: 15.5, height: 1.35),
                cursorColor: t.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  counterText: '',
                  hintText: _hint(c),
                  hintStyle: TextStyle(color: t.inkFaint, fontSize: 15),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (_, value, _) {
              final ready = value.text.trim().isNotEmpty && !c.busy;
              return _SupportSendButton(enabled: ready, onTap: _send);
            },
          ),
        ],
      ),
    );
  }

}

/// The send control, mirrored from the Scout tab rather than shared: the tab's own
/// button is private to that file, and a support surface reaching across for it would
/// couple two screens for forty lines. Disabled means dimmed and inert, not hidden,
/// so the row does not jump each time the box empties. The fill uses
/// [ScoutTheme.accentGradient] because it is the one control here carrying a white
/// glyph, and the palette's flat `accent` fails white text.
class _SupportSendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _SupportSendButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Send',
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.4,
        duration: const Duration(milliseconds: 160),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: ScoutTheme.accentGradient,
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: ScoutTheme.accentFill.withValues(alpha: 0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 20,
                  color: ScoutTheme.onAccentFill,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
