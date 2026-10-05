import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/colors.dart';
import '../models/play_request.dart';
import '../providers/auth_provider.dart';
import '../services/request_service.dart';
import '../utils/reconnect_refresh.dart';
import '../utils/snackbar_util.dart';
import '../screens/shared/public_profile_screen.dart';
import 'match_widgets.dart' show MatchEmptyState;

/// The "find players to ask" list behind the Players tab (module 8c).
///
/// Deliberately plainer than the opponent rail: [RequestService.discover] returns
/// real active accounts with no invented rating, so a row shows only what the tables
/// own — the player's name, their stated sports, their trust when it is set — and
/// never a fabricated score. Tapping Request sends a direct play request; the row
/// then reads "Requested" so a second tap cannot hit the server's duplicate guard.
class DiscoverPlayersList extends StatefulWidget {
  const DiscoverPlayersList({super.key});

  @override
  State<DiscoverPlayersList> createState() => _DiscoverPlayersListState();
}

class _DiscoverPlayersListState extends State<DiscoverPlayersList>
    with ReconnectRefresh<DiscoverPlayersList> {
  final _req = RequestService();

  String get _token => context.read<AuthProvider>().token ?? '';

  // Null both while the first load runs and after one that failed; the two are
  // told apart by [_loading] and [_failed] so the four states never collide.
  List<DiscoverPlayer>? _players;
  bool _loading = true;
  bool _failed = false;

  // Users a request is in flight to, and users already asked this session — so the
  // button reads "Requested" the instant the ask lands, before the next discover
  // refresh confirms it server-side.
  final Set<String> _sending = {};
  final Set<String> _requested = {};

  @override
  void initState() {
    super.initState();
    // A frame late so `context.read` is legal and the first paint is the spinner.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  // A dropped connection leaves the failed state on screen; the reconnect re-fetches
  // so the list heals itself without the user pulling down. A good load is left
  // alone — a silent refetch would flicker a list the user may be mid-scroll on.
  @override
  void onReconnect() {
    if (_failed) _load();
  }

  Future<void> _load() async {
    final players = await _req.discover(_token);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = players == null;
      _players = players;
    });
  }

  Future<void> _request(DiscoverPlayer p) async {
    if (_sending.contains(p.userId)) return;
    setState(() => _sending.add(p.userId));
    final r = await _req.create(_token, targetUserId: p.userId);
    if (!mounted) return;
    final ok = r['success'] == true;
    // A 409 means a pending ask to this player already stands; the button should
    // read "Requested" either way, so both outcomes mark the row asked. The server's
    // own message is surfaced verbatim rather than a guessed one.
    final duplicate = !ok && r['statusCode'] == 409;
    setState(() {
      _sending.remove(p.userId);
      if (ok || duplicate) _requested.add(p.userId);
    });
    if (ok) {
      SnackbarUtil.showSuccess(context, 'Request sent to ${p.name}.');
    } else {
      SnackbarUtil.showError(
        context,
        '${r['message'] ?? 'Could not send the request. Try again.'}',
      );
    }
  }

  // The player's public profile — so the viewer can see who they are about to ask.
  void _openProfile(DiscoverPlayer p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PublicProfileScreen(
          userId: p.userId,
          name: p.name,
          avatarUrl: p.avatarUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      // MatchEmptyState is itself the scrollable; handing it to RefreshIndicator
      // directly avoids nesting a viewport inside another unbounded one.
      return RefreshIndicator(
        onRefresh: _load,
        child: const MatchEmptyState(
          icon: Icons.cloud_off,
          text: 'Could not load players.\nPull down to try again.',
        ),
      );
    }
    final players = _players ?? const [];
    if (players.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: const MatchEmptyState(
          icon: Icons.person_search_outlined,
          text: 'No players to show yet.\nCheck back once more people join.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: players.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (_, i) => _row(players[i]),
      ),
    );
  }

  Widget _row(DiscoverPlayer p) {
    final asked = p.pendingRequest || _requested.contains(p.userId);
    final sending = _sending.contains(p.userId);
    final sports = p.sports.isEmpty ? 'Player' : p.sports.join(' · ');
    final url = p.avatarUrl?.trim() ?? '';
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _openProfile(p),
              borderRadius: BorderRadius.circular(10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
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
                          p.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                sports,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (p.trustScore != null) ...[
                              const SizedBox(width: 8),
                              _trustChip(p.trustScore!),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _requestButton(p, asked: asked, sending: sending),
        ],
      ),
    );
  }

  // Trust is shown only when the account carries a score; the number is the one
  // the tables hold, never a default stand-in. A whole number reads cleaner than a
  // trailing ".0" for the common integer case.
  Widget _trustChip(num score) {
    final n = score % 1 == 0 ? score.toInt().toString() : score.toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_user_outlined, size: 12, color: AppColors.primary),
          const SizedBox(width: 3),
          Text(
            n,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _requestButton(DiscoverPlayer p, {required bool asked, required bool sending}) {
    if (sending) {
      return const SizedBox(
        width: 92,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (asked) {
      return const SizedBox(
        width: 92,
        height: 36,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check, size: 16, color: AppColors.textSecondary),
            SizedBox(width: 4),
            Text(
              'Requested',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    // A private player cannot be asked (the server refuses it), so the button is a
    // lock that opens their gated profile rather than a dead Request that 403s.
    if (!p.isPublic) {
      return SizedBox(
        width: 92,
        height: 36,
        child: OutlinedButton(
          onPressed: () => _openProfile(p),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: AppColors.textSecondary,
            side: const BorderSide(color: AppColors.border),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 14),
              SizedBox(width: 4),
              Text('Private', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: 92,
      height: 36,
      child: FilledButton(
        onPressed: () => _request(p),
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: AppColors.primary,
        ),
        child: const Text('Request', style: TextStyle(fontSize: 13)),
      ),
    );
  }
}
