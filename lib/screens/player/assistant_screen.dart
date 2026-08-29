import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/assistant.dart';
import '../../providers/assistant_controller.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/assistant/scout_bits.dart';
import '../../widgets/assistant/scout_bubble.dart';
import '../../widgets/assistant/scout_chips.dart';
import '../../widgets/assistant/scout_sheets.dart';
import '../../widgets/assistant/scout_theme.dart';
import '../../widgets/assistant/scout_typing.dart';

/// What the chat hands back to whoever opened it.
///
/// Two facts, both about the world outside the conversation: whether the user's
/// bookings changed while they were in here, and whether the last thing Scout said was
/// "that lives on the Teams screen". The caller acts on them — refresh the list, switch
/// the tab — which is how a chat that can book a ground stays consistent with the rest
/// of the app without either side importing the other's state.
class ScoutExit {
  final bool bookingsChanged;
  final String? screen;

  const ScoutExit({this.bookingsChanged = false, this.screen});
}

/// Scout: the whole assistant, one screen.
///
/// THE SURFACE IS DARK ON PURPOSE. Every other player screen is white cards on grey,
/// and that is right for browsing — but a conversation is a different kind of place,
/// and twelve card types stacked in one scroll view need a background that recedes
/// instead of competing. The dark green keeps the brand and gives the cards, the money
/// figures and the accents somewhere to sit. Contrast ratios were checked, not
/// eyeballed; see `scout_theme.dart`.
///
/// THERE IS NO MIC BUTTON. Voice was a stretch goal, and a microphone icon that does
/// nothing is worse than no microphone at all — it is the single most tapped affordance
/// in any chat UI and a dead one reads as a broken app. Text-first, as specified.
class AssistantScreen extends StatefulWidget {
  /// Open straight into a specific conversation. Null means "wherever I left off".
  final String? threadId;

  const AssistantScreen({this.threadId, super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  /// The five tabs of the player shell. Reaching one means popping with a request,
  /// not pushing a second copy of a screen that is already in the IndexedStack.
  static const Map<String, int> _tabScreens = {
    'home': 0,
    'bookings': 1,
    'teams': 2,
    'wallet': 3,
    'profile': 4,
  };

  /// Screens that are their own route and can simply be pushed.
  static const Map<String, String> _routeScreens = {
    'venues': '/find-venues',
    'tournaments': '/tournaments',
  };

  static const Map<String, String> _screenLabels = {
    'home': 'Home',
    'bookings': 'My Bookings',
    'teams': 'Teams',
    'wallet': 'Wallet',
    'profile': 'Profile',
    'venues': 'Find Venues',
    'tournaments': 'Tournaments',
  };

  AssistantController? _c;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  String? _dismissedJump;

  /// Newest message id and busy flag at the last paint — the change detector for
  /// "should the viewport follow this".
  String? _tailId;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token != null && token.isNotEmpty) {
      final c = AssistantController(token: token, initialThreadId: widget.threadId);
      c.addListener(_onControllerChanged);
      _c = c;
      c.start();
    }
    _scroll.addListener(_onScroll);
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

  /// Decide whether this change should move the viewport.
  ///
  /// Only a change at the END of the transcript may scroll. Loading OLDER messages
  /// inserts at index 0 and must leave the viewport exactly where it was — a chat that
  /// throws you back to the bottom the moment you reach for history is unusable. The
  /// tail id is the whole test: it changes when a bubble is appended and does not when
  /// a page is prepended.
  void _syncScroll() {
    final c = _c;
    if (c == null) return;
    final tail = c.messages.isEmpty ? null : c.messages.last.id;
    final busy = c.busy;
    final first = _tailId == null && tail != null;
    if (tail == _tailId && busy == _wasBusy) return;
    _tailId = tail;
    _wasBusy = busy;
    // The first paint should already be at the newest message, not animate to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(animate: !first));
  }

  /// Load older history when the user reaches the top of the transcript.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= 120) _c?.loadOlder();
  }

  void _toBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  // ── conversation moves ────────────────────────────────────────────────────

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _c == null || _c!.busy) return;
    _input.clear();
    _c!.sendText(text);
    // Keeping focus is deliberate: the usual next thing after "book it" is another
    // short message, and re-opening the keyboard for every turn is a tax.
    _focus.requestFocus();
  }

  void _chip(ScoutChip chip) {
    if (_c == null || _c!.busy) return;
    _c!.sendChip(chip);
  }

  // ── client moves ──────────────────────────────────────────────────────────

  /// Leave the chat for a screen named by the backend's `meta.screen`.
  void _goScreen(String screen) {
    final key = screen.trim().toLowerCase();
    final route = _routeScreens[key];
    if (route != null) {
      Navigator.of(context).pushNamed(route);
      return;
    }
    if (_tabScreens.containsKey(key)) {
      // The tabs live in the shell below us, so the shell has to do the switching.
      _leave(screen: key);
      return;
    }
    _toast('That screen is not in this build yet.');
  }

  /// Hand a `map` card to whatever the phone uses for maps.
  ///
  /// `canLaunchUrl` is not consulted for the `geo:` attempt. On Android 11+ it answers
  /// for the calling app's declared intent queries, not for what is really installed,
  /// so gating on it would refuse a perfectly good handler. Try the geo pin, and fall
  /// back to the https URL — which every phone can open — if that throws.
  Future<void> _directions(CardData d) async {
    final geo = d.strOrNull('geoUri');
    final web = d.strOrNull('mapsUrl');
    for (final raw in [if (d.flag('hasPin')) geo, web]) {
      if (raw == null) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return;
      } catch (_) {
        // Next candidate.
      }
    }
    if (mounted) _toast('No maps app could open this location.');
  }

  // ── leaving ───────────────────────────────────────────────────────────────

  /// Pop with the two facts the shell needs. Called by the back button, the system
  /// gesture and `_goScreen` alike, so there is exactly one exit path.
  void _leave({String? screen}) {
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.pop(ScoutExit(bookingsChanged: _c?.bookingsChanged ?? false, screen: screen));
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ScoutTheme.card,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Theme(
      data: ScoutTheme.data(),
      child: PopScope(
        // The gesture back has to carry the same result as the button, or a user who
        // swipes out after booking would return to a stale bookings list.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          backgroundColor: ScoutTheme.canvas,
          resizeToAvoidBottomInset: true,
          body: DecoratedBox(
            decoration: ScoutTheme.pageDecoration,
            child: SafeArea(
              child: c == null
                  ? _signedOut()
                  : Column(
                      children: [
                        _appBar(c),
                        if (c.notice != null) _noticeBar(c),
                        Expanded(child: _body(c)),
                        if (c.busy) const ScoutTyping(),
                        _jumpBar(c),
                        _composer(c),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Only reachable if the route is opened without a session — the guard normally
  /// catches this first, so it stays deliberately plain.
  Widget _signedOut() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ScoutAvatar(size: 54),
              const SizedBox(height: 16),
              const Text(
                'Sign in to talk to Scout',
                style: TextStyle(color: ScoutTheme.ink, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                'Scout answers from your own bookings, teams and wallet, so it needs '
                'to know who you are.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 18),
              TextButton(onPressed: () => _leave(), child: const Text('Go back')),
            ],
          ),
        ),
      );

  // ── app bar ───────────────────────────────────────────────────────────────

  /// A hand-built bar rather than an [AppBar], for one reason: the status line under
  /// the name. Knowing whether Scout is idle or working belongs next to the name, not
  /// only in the transcript, and an AppBar title cannot hold two lines of different
  /// weight without fighting its own centring.
  Widget _appBar(AssistantController c) {
    final title = c.title;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ScoutTheme.lineSoft)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _leave(),
            icon: const Icon(Icons.arrow_back_rounded, size: 21),
            color: ScoutTheme.inkSoft,
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
                  title == null || title.isEmpty ? 'Scout' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ScoutTheme.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.busy ? ScoutTheme.money : ScoutTheme.good,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      c.booting
                          ? 'Opening…'
                          : c.busy
                              ? 'Working on it'
                              : 'Your bookings, teams & wallet',
                      style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 10.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _barAction(
            icon: Icons.history_rounded,
            tooltip: 'Chats',
            onTap: () => showScoutThreadsSheet(context, c),
          ),
          _barAction(
            icon: Icons.add_comment_outlined,
            tooltip: 'New chat',
            onTap: c.isEmpty && c.threadId == null ? null : c.newChat,
          ),
          _barAction(
            icon: Icons.help_outline_rounded,
            tooltip: 'What Scout can do',
            onTap: () => showScoutHelpSheet(
              context,
              capabilities: c.capabilities,
              onPick: _chip,
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _barAction({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      color: onTap == null ? ScoutTheme.inkFaint : ScoutTheme.inkSoft,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      padding: EdgeInsets.zero,
    );
  }

  // ── notice ────────────────────────────────────────────────────────────────

  /// Errors that are about the app rather than about the conversation — a failed
  /// rename, a thread that would not delete. Conversation problems arrive as bubbles;
  /// these do not deserve a fake turn in the transcript.
  Widget _noticeBar(AssistantController c) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.fromLTRB(11, 9, 5, 9),
      decoration: BoxDecoration(
        color: ScoutTheme.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: ScoutTheme.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 15, color: ScoutTheme.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.notice!,
              style: const TextStyle(color: ScoutTheme.ink, fontSize: 11.5, height: 1.35),
            ),
          ),
          IconButton(
            onPressed: c.dismissNotice,
            icon: const Icon(Icons.close_rounded, size: 15),
            color: ScoutTheme.inkSoft,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }

  // ── transcript ────────────────────────────────────────────────────────────

  Widget _body(AssistantController c) {
    if (c.booting) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: ScoutTheme.accent),
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
    // One leading slot for the "older messages" affordance, then a date separator
    // wherever the day changes — cheap to compute and it keeps the list flat.
    final count = msgs.length + 1;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i == 0) return _topSlot(c);
        final msg = msgs[i - 1];
        final prev = i - 2 >= 0 ? msgs[i - 2] : null;
        final newDay =
            prev == null || !ScoutDateSeparator.sameDay(prev.createdAt, msg.createdAt);
        final group = ScoutMessageGroup(
          key: ValueKey(msg.id),
          msg: msg,
          actions: actions,
          onRetry: c.retry,
          onVote: c.vote,
          onExplain: (m) => showScoutExplainSheet(context, m),
        );
        if (!newDay) return group;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [ScoutDateSeparator(day: msg.createdAt), group],
        );
      },
    );
  }

  /// Top of the transcript: a spinner while an older page loads, a hint that more
  /// exists, or nothing at all once the beginning has been reached.
  Widget _topSlot(AssistantController c) {
    if (c.loadingOlder) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: ScoutTheme.inkFaint),
          ),
        ),
      );
    }
    if (!c.hasMore) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: TextButton(
          onPressed: c.loadOlder,
          style: TextButton.styleFrom(
            foregroundColor: ScoutTheme.inkSoft,
            textStyle: const TextStyle(fontSize: 11.5),
          ),
          child: const Text('Load earlier messages'),
        ),
      ),
    );
  }

  // ── empty state ───────────────────────────────────────────────────────────

  /// The four seed chips.
  ///
  /// "My ELO" posts `team_stats`, not `elo_help`: in this app a rating belongs to a
  /// team, and with no team named the handler resolves the user's own — so the chip
  /// answers "what is MY rating" rather than explaining the formula. The explanation
  /// is one chip further in, offered by the answer itself.
  static const List<ScoutChip> _seedChips = [
    ScoutChip(label: 'Find a ground', action: 'find_venue'),
    ScoutChip(label: 'My bookings', action: 'my_bookings'),
    ScoutChip(label: 'My ELO', action: 'team_stats'),
    ScoutChip(label: 'Wallet', action: 'wallet_balance'),
  ];

  /// A first screen has one job: make the first message easy. So it names three real
  /// things Scout does — in the user's own words, not feature names — and puts the
  /// four chips right there. No illustration, no "Hi! I'm Scout 👋"; the greeting is
  /// Scout's to send once there is something to greet.
  Widget _empty(AssistantController c) {
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      children: [
        const Center(child: ScoutAvatar(size: 60)),
        const SizedBox(height: 18),
        const Text(
          'Ask Scout',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ScoutTheme.ink,
            fontSize: 21,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Book a ground, check what you owe, find a team to play — in English, '
          'Urdu or both.',
          textAlign: TextAlign.center,
          style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 12.5, height: 1.5),
        ),
        const SizedBox(height: 22),
        _example('“football ground chahiye kal shaam 2000 se kam”'),
        _example('“meri booking cancel karni hai”'),
        _example('“wallet mein kitna hai?”'),
        const SizedBox(height: 24),
        Center(
          child: ScoutChipsWrap(
            chips: _seedChips,
            onTap: _chip,
            enabled: !c.busy,
            primaryActions: const {'find_venue'},
          ),
        ),
      ],
    );
  }

  Widget _example(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline_rounded, size: 12, color: ScoutTheme.inkFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: ScoutTheme.inkFaint,
                  fontSize: 11.5,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );

  // ── jump bar ──────────────────────────────────────────────────────────────

  /// When Scout's last answer was "that lives on the Wallet screen", the app should
  /// offer the trip rather than leave the user to find it. Slim, dismissible, and
  /// gone the moment the conversation moves on — a persistent banner would be a
  /// second navigation bar nobody asked for.
  Widget _jumpBar(AssistantController c) {
    final screen = c.suggestedScreen?.trim().toLowerCase();
    if (screen == null || screen.isEmpty) return const SizedBox.shrink();
    if (screen == _dismissedJump) return const SizedBox.shrink();
    final label = _screenLabels[screen];
    if (label == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
      child: Material(
        color: ScoutTheme.canvasGlow,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: () => _goScreen(screen),
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 4, 8),
            child: Row(
              children: [
                const Icon(Icons.open_in_new_rounded, size: 14, color: ScoutTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Open $label',
                    style: const TextStyle(
                      color: ScoutTheme.ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _dismissedJump = screen),
                  icon: const Icon(Icons.close_rounded, size: 14),
                  color: ScoutTheme.inkFaint,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  padding: EdgeInsets.zero,
                  tooltip: 'Not now',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── composer ──────────────────────────────────────────────────────────────

  /// The hint changes with the dialog state. When Scout has asked a question, an
  /// empty box that still says "Ask Scout anything" is a small lie about what is
  /// expected next — and this app's FSM is mirrored from the server, so the hint is
  /// always the truth rather than a guess.
  String _hint(AssistantController c) {
    switch (c.fsm) {
      case ScoutFsm.awaitingConfirm:
        return 'Reply “yes” to go ahead, or “no”';
      case ScoutFsm.awaitingChoice:
        return 'Pick one above, or type it';
      case ScoutFsm.slotFilling:
        return 'Answer, or add a detail';
      case ScoutFsm.idle:
        return 'Ask Scout anything…';
    }
  }

  Widget _composer(AssistantController c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(
        color: ScoutTheme.canvas,
        border: Border(top: BorderSide(color: ScoutTheme.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: BoxDecoration(
                color: ScoutTheme.bubble,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: ScoutTheme.line),
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
                style: const TextStyle(color: ScoutTheme.ink, fontSize: 13.5, height: 1.35),
                cursorColor: ScoutTheme.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  // The 500-char cap is the server's, not a style choice, so the
                  // counter only appears when the user is actually near it.
                  counterText: '',
                  hintText: _hint(c),
                  hintStyle: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 13),
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
              return _SendButton(enabled: ready, onTap: _send);
            },
          ),
        ],
      ),
    );
  }
}

/// The send button.
///
/// Disabled means dimmed and inert, not hidden: a control that vanishes when the box
/// is empty makes the row jump every time the last character is deleted.
class _SendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _SendButton({required this.enabled, required this.onTap});

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
              gradient: const LinearGradient(
                colors: [ScoutTheme.accent, ScoutTheme.accentDim],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: ScoutTheme.accent.withValues(alpha: 0.28),
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
                child: Icon(Icons.arrow_upward_rounded, size: 20, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
