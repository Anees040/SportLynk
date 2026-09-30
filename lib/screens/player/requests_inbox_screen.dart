import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart' show ChatChannelType;
import '../../models/play_request.dart';
import '../../providers/auth_provider.dart';
import '../../services/request_service.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart' show MatchEmptyState;

/// The matchmaking request inbox (module 8c).
///
/// Two tabs over the same card. **Incoming** is the asks addressed to me: a pending
/// one carries Accept and Decline, and accepting opens the 1:1 room the server just
/// created. **Outgoing** is the asks I sent — the one place a decline is visible,
/// since a declined request is otherwise silent to spare the requester the sting of
/// a push saying "no". Both tabs honour the four states: a failed load is an error
/// with a retry, never an empty list dressed up as "nothing here".
class RequestsInboxScreen extends StatefulWidget {
  const RequestsInboxScreen({super.key});

  @override
  State<RequestsInboxScreen> createState() => _RequestsInboxScreenState();
}

class _RequestsInboxScreenState extends State<RequestsInboxScreen>
    with ReconnectRefresh<RequestsInboxScreen>, SingleTickerProviderStateMixin {
  final _req = RequestService();
  late final TabController _tabs;

  String get _token => context.read<AuthProvider>().token ?? '';

  // Null while the first load runs and after one that fails; [_loadingIn]/[_failedIn]
  // (and the outgoing pair) keep the four states from colliding.
  List<PlayRequest>? _incoming;
  bool _loadingIn = true;
  bool _failedIn = false;

  List<PlayRequest>? _outgoing;
  bool _loadingOut = true;
  bool _failedOut = false;

  // Requests with an accept/decline/cancel in flight, so a row's buttons disable and
  // a double-tap cannot fire the same transition twice.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    // A frame late so `context.read` is legal and the first paint is the spinner.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadIncoming();
      _loadOutgoing();
    });
  }

  // Heal whichever side failed once the socket returns; a good load is left alone so
  // a reconnect does not flicker a list the user is reading.
  @override
  void onReconnect() {
    if (_failedIn) _loadIncoming();
    if (_failedOut) _loadOutgoing();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadIncoming() async {
    final rows = await _req.incoming(_token);
    if (!mounted) return;
    setState(() {
      _loadingIn = false;
      _failedIn = rows == null;
      _incoming = rows;
    });
  }

  Future<void> _loadOutgoing() async {
    final rows = await _req.outgoing(_token);
    if (!mounted) return;
    setState(() {
      _loadingOut = false;
      _failedOut = rows == null;
      _outgoing = rows;
    });
  }

  Future<void> _respond(PlayRequest r, {required bool accept}) async {
    if (_busy.contains(r.id)) return;
    setState(() => _busy.add(r.id));
    final res = await _req.respond(_token, r.id, accept: accept);
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    if (res['success'] != true) {
      SnackbarUtil.showError(
        context,
        '${res['message'] ?? 'Could not update the request. Try again.'}',
      );
      return;
    }
    // The row's state has changed server-side; re-read so it stops offering the
    // buttons it just consumed.
    await _loadIncoming();
    if (!mounted) return;
    if (accept) {
      final channelId =
          (res['data'] as Map?)?['channelId']?.toString() ?? r.channelId;
      SnackbarUtil.showSuccess(context, 'You are connected with ${r.displayName}.');
      if (channelId != null && channelId.isNotEmpty) {
        _openRoom(channelId, r.displayName, r.otherAvatar);
      }
    } else {
      SnackbarUtil.showInfo(context, 'Request declined.');
    }
  }

  Future<void> _cancel(PlayRequest r) async {
    if (_busy.contains(r.id)) return;
    setState(() => _busy.add(r.id));
    final res = await _req.cancel(_token, r.id);
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    if (res['success'] != true) {
      SnackbarUtil.showError(
        context,
        '${res['message'] ?? 'Could not withdraw the request. Try again.'}',
      );
      return;
    }
    await _loadOutgoing();
    if (mounted) SnackbarUtil.showInfo(context, 'Request withdrawn.');
  }

  // The 1:1 room an accepted request opened. Named-route navigation keeps the
  // direct room reachable exactly the way the acceptance notification reaches it.
  void _openRoom(String channelId, String title, String? avatar) {
    Navigator.pushNamed(context, '/chat-thread', arguments: {
      'channelId': channelId,
      'type': ChatChannelType.direct.wire,
      'title': title,
      'imageUrl': avatar,
    }).then((_) {
      if (mounted) {
        _loadIncoming();
        _loadOutgoing();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Play Requests',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.accent,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [
            Tab(text: 'Incoming'),
            Tab(text: 'Sent'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _tabBody(incoming: true),
          _tabBody(incoming: false),
        ],
      ),
    );
  }

  Widget _tabBody({required bool incoming}) {
    final loading = incoming ? _loadingIn : _loadingOut;
    final failed = incoming ? _failedIn : _failedOut;
    final rows = (incoming ? _incoming : _outgoing) ?? const [];
    final reload = incoming ? _loadIncoming : _loadOutgoing;

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (failed) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            MatchEmptyState(
              icon: Icons.cloud_off,
              text: 'Could not load requests.\nPull down to try again.',
            ),
          ],
        ),
      );
    }
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            MatchEmptyState(
              icon: incoming ? Icons.inbox_outlined : Icons.send_outlined,
              text: incoming
                  ? 'No requests yet.\nWhen someone asks you to play, it shows here.'
                  : 'You have not asked anyone yet.\nFind players from the Matchmaking screen.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (_, i) => _card(rows[i], incoming: incoming),
      ),
    );
  }

  Widget _card(PlayRequest r, {required bool incoming}) {
    final url = r.otherAvatar?.trim() ?? '';
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.inputFill,
                foregroundImage: avatar,
                child: avatar == null
                    ? const Icon(Icons.person, color: AppColors.textSecondary)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.displayName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (r.sport != null && r.sport!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Wants to play ${r.sport}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (r.message != null && r.message!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              r.message!.trim(),
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
            ),
          ],
          const SizedBox(height: 12),
          _actions(r, incoming: incoming),
        ],
      ),
    );
  }

  Widget _actions(PlayRequest r, {required bool incoming}) {
    // Any transition in flight collapses the action area to a single spinner, which
    // reads more clearly than two greyed buttons and blocks a second tap.
    if (_busy.contains(r.id)) {
      return const SizedBox(
        height: 36,
        child: Center(
          child: SizedBox(
            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    // Accepted on either side → the 1:1 room is the destination.
    if (r.status == PlayRequestStatus.accepted) {
      final channelId = r.channelId;
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.chat_bubble_outline, size: 16),
          label: const Text('Open chat'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.primary),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
          onPressed: (channelId == null || channelId.isEmpty)
              ? null
              : () => _openRoom(channelId, r.displayName, r.otherAvatar),
        ),
      );
    }
    // Incoming and still open → the only row that can be acted on.
    if (incoming && r.isPending) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              onPressed: () => _respond(r, accept: false),
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              onPressed: () => _respond(r, accept: true),
              child: const Text('Accept'),
            ),
          ),
        ],
      );
    }
    // Outgoing and still open → withdraw, with the pending marker beside it.
    if (!incoming && r.isPending) {
      return Row(
        children: [
          _statusPill(r.status),
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => _cancel(r),
            child: const Text('Cancel'),
          ),
        ],
      );
    }
    // Everything else is terminal (declined, cancelled, expired) — show the outcome.
    return Align(alignment: Alignment.centerLeft, child: _statusPill(r.status));
  }

  // The outcome badge for a decided or pending request. Unknown carries no label
  // (the server sent a status this build predates), so it renders nothing rather
  // than an empty pill.
  Widget _statusPill(PlayRequestStatus s) {
    if (s.label.isEmpty) return const SizedBox.shrink();
    final (Color fg, Color bg) = switch (s) {
      PlayRequestStatus.pending =>
        (AppColors.warningText, AppColors.warning.withValues(alpha: 0.14)),
      PlayRequestStatus.accepted => (AppColors.success, AppColors.accentLight),
      PlayRequestStatus.declined =>
        (AppColors.error, AppColors.error.withValues(alpha: 0.10)),
      PlayRequestStatus.cancelled ||
      PlayRequestStatus.expired ||
      PlayRequestStatus.unknown =>
        (AppColors.textSecondary, AppColors.inputFill),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        s.label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}
