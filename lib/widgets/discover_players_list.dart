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
/// A 2-column card grid: each card shows the one thing a card can honestly show —
/// the player's name, the sports they list (as icon badges), their trust when it is
/// set, how active they have been, and the area they play in — then a Request / Message
/// action. Nothing is invented when a value is missing: there is deliberately no
/// rating here, because SportLynk rates TEAMS, not players, and showing a per-player
/// ELO would mean making one up.
///
/// The filters narrow the loaded list client-side: by Sport, by Area (the player's
/// home city, derived server-side from where they book), and by a Sort that stands in
/// for a rating with the real individual signals — most active, or highest trust.
class DiscoverPlayersList extends StatefulWidget {
  const DiscoverPlayersList({super.key});

  @override
  State<DiscoverPlayersList> createState() => _DiscoverPlayersListState();
}

enum _Sort { active, trust, rating }

class _DiscoverPlayersListState extends State<DiscoverPlayersList>
    with ReconnectRefresh<DiscoverPlayersList> {
  final _req = RequestService();
  final _searchCtrl = TextEditingController();
  String _query = '';

  // The active filters. Null means "all"; sport is held lower-cased.
  String? _sport;
  String? _city;
  _Sort _sort = _Sort.active;

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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
      // Drop a filter that nothing in the fresh list can satisfy, so a stale chip
      // cannot leave the grid mysteriously empty.
      if (_sport != null && !_sportsPresent.contains(_sport)) _sport = null;
      if (_city != null && !_citiesPresent.contains(_city)) _city = null;
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

  // The distinct sports and areas actually present in the loaded list — the filter
  // only ever offers a value some player can be found under.
  List<String> get _sportsPresent {
    final s = <String>{};
    for (final p in (_players ?? const <DiscoverPlayer>[])) {
      for (final x in p.sports) {
        if (x.trim().isNotEmpty) s.add(x.toLowerCase());
      }
    }
    return s.toList()..sort();
  }

  List<String> get _citiesPresent {
    final s = <String>{};
    for (final p in (_players ?? const <DiscoverPlayer>[])) {
      final c = p.homeCity;
      if (c != null && c.trim().isNotEmpty) s.add(c);
    }
    return s.toList()..sort();
  }

  // The loaded list after the name search, the sport and area filters, and the sort.
  List<DiscoverPlayer> get _visible {
    final q = _query.trim().toLowerCase();
    final out = (_players ?? const <DiscoverPlayer>[]).where((p) {
      // A player the viewer already matched with (an accepted request opened a DM)
      // has no place in the scout list — they live in the chat inbox now. Hiding
      // them keeps this list to people the viewer can still send a request to.
      if (p.connected) return false;
      if (q.isNotEmpty && !p.name.toLowerCase().contains(q)) return false;
      if (_sport != null && !p.sports.map((s) => s.toLowerCase()).contains(_sport)) {
        return false;
      }
      if (_city != null && p.homeCity != _city) return false;
      return true;
    }).toList();
    int byTrust(DiscoverPlayer a, DiscoverPlayer b) =>
        (b.trustScore ?? -1).compareTo(a.trustScore ?? -1);
    int byActivity(DiscoverPlayer a, DiscoverPlayer b) =>
        b.bookings30d.compareTo(a.bookings30d);
    int byRating(DiscoverPlayer a, DiscoverPlayer b) =>
        (b.topElo ?? -1).compareTo(a.topElo ?? -1);
    out.sort((a, b) {
      final primary = switch (_sort) {
        _Sort.rating => byRating(a, b),
        _Sort.trust => byTrust(a, b),
        _Sort.active => byActivity(a, b),
      };
      if (primary != 0) return primary;
      // A sensible, stable tiebreak so equal-primary rows do not jump around.
      final t = byTrust(a, b);
      return t != 0 ? t : byActivity(a, b);
    });
    return out;
  }

  IconData _sportIcon(String sport) => switch (sport.toLowerCase()) {
        'football' || 'futsal' => Icons.sports_soccer,
        'cricket' => Icons.sports_cricket,
        _ => Icons.sports,
      };

  String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

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
    final visible = _visible;
    return Column(
      children: [
        _searchField(),
        _filterBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: visible.isEmpty
                ? MatchEmptyState(
                    icon: Icons.search_off,
                    text: _query.trim().isEmpty
                        ? 'No players match these filters.'
                        : 'No players match "${_query.trim()}".',
                  )
                : GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 240,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (_, i) => _card(visible[i]),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search players by name…',
            prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
            filled: true,
            fillColor: AppColors.inputFill,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );

  // Sport chips on top (always, when any player lists a sport), and a Sort / Area
  // row below. Area appears only when at least one player has a derivable home city.
  Widget _filterBar() {
    final sports = _sportsPresent;
    final cities = _citiesPresent;
    return Column(
      children: [
        if (sports.isNotEmpty)
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _chip('All sports', _sport == null, () => setState(() => _sport = null)),
                for (final s in sports)
                  _chip(_cap(s), _sport == s,
                      () => setState(() => _sport = _sport == s ? null : s),
                      icon: _sportIcon(s)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: _dropdown<_Sort>(
                  icon: Icons.sort,
                  value: _sort,
                  items: const {
                    _Sort.active: 'Most active',
                    _Sort.trust: 'Highest trust',
                    _Sort.rating: 'Top rating',
                  },
                  onChanged: (v) => setState(() => _sort = v),
                ),
              ),
              if (cities.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _dropdown<String?>(
                    icon: Icons.place_outlined,
                    value: _city,
                    items: {
                      null: 'All areas',
                      for (final c in cities) c: c,
                    },
                    onChanged: (v) => setState(() => _city = v),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: on ? AppColors.accent : AppColors.inputFill,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: on ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: on ? Colors.white : AppColors.textSecondary),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: on ? Colors.white : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropdown<T>({
    required IconData icon,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                items: [
                  for (final e in items.entries)
                    DropdownMenuItem<T>(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v is T) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(DiscoverPlayer p) {
    final asked = p.pendingRequest || _requested.contains(p.userId);
    final sending = _sending.contains(p.userId);
    final url = p.avatarUrl?.trim() ?? '';
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    // At most two sport badges — enough to say "plays both", without crowding a
    // narrow card.
    final sports = p.sports.where((s) => s.trim().isNotEmpty).take(2).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _openProfile(p),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: AppColors.inputFill,
                      foregroundImage: avatar,
                      child: avatar == null
                          ? const Icon(Icons.person,
                              color: AppColors.textSecondary, size: 26)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      p.name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (sports.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final s in sports) ...[
                            Icon(_sportIcon(s), size: 15, color: AppColors.primary),
                            const SizedBox(width: 4),
                          ],
                        ],
                      ),
                    const Spacer(),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (p.trustScore != null) _trustChip(p.trustScore!),
                        // The skill signal: the player's best ranked TEAM's standing
                        // (players have no ELO of their own). Falls back to recent
                        // activity when they are on no ranked team, so the row is
                        // never more than two chips.
                        if (p.topElo != null)
                          _metaChip(Icons.emoji_events_outlined, '${p.topElo}')
                        else if (p.bookings30d > 0)
                          _metaChip(Icons.bolt, '${p.bookings30d}'),
                      ],
                    ),
                    if (p.homeCity != null && p.homeCity!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.place_outlined,
                              size: 12, color: AppColors.textSecondary),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              p.homeCity!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: _actionButton(p, asked: asked, sending: sending),
          ),
        ],
      ),
    );
  }

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

  // Activity: games booked in the last 30 days. Shown only when non-zero, so it is a
  // signal, never a "0" that reads as a mark against a new player.
  Widget _metaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textSecondary),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(DiscoverPlayer p, {required bool asked, required bool sending}) {
    if (sending) {
      return const SizedBox(
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
    // Already connected players are filtered out of the list entirely (see
    // _visible), so a card here is always someone the viewer can still ask.
    if (asked) {
      return const SizedBox(
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
    // Private players are excluded from discovery server-side (a private account is
    // not asked to play), so the list only ever holds public, askable players here.
    return SizedBox(
      width: double.infinity,
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
