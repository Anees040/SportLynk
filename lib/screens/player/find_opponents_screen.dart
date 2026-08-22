import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/team.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';

/// Discover public teams to play against. The list is live from the backend;
/// issuing a match challenge is part of the matchmaking wave and is flagged as
/// such rather than faked, so nothing here claims a capability that isn't wired.
class FindOpponentsScreen extends StatefulWidget {
  const FindOpponentsScreen({super.key});
  @override
  State<FindOpponentsScreen> createState() => _FindOpponentsScreenState();
}

class _FindOpponentsScreenState extends State<FindOpponentsScreen> {
  final _service = TeamService();
  final _searchCtrl = TextEditingController();
  String _sport = 'football';
  String _query = '';
  late Future<List<Team>> _future;

  static const _sports = [('Football', 'football'), ('Cricket', 'cricket')];

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<Team>> _load() =>
      _service.discover(_token, sport: _sport, q: _query.isEmpty ? null : _query);

  void _refresh() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Find Opponents',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: _sports
            .map((s) => GestureDetector(
                  onTap: () {
                    setState(() => _sport = s.$2);
                    _refresh();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: _sport == s.$2
                            ? AppColors.accent
                            : Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(s.$1,
                        style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight:
                                _sport == s.$2 ? FontWeight.bold : FontWeight.normal)),
                  ),
                ))
            .toList(),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                _query = v.trim();
                _refresh();
              },
              decoration: InputDecoration(
                hintText: 'Search teams…',
                prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _query = '';
                          _refresh();
                        },
                      ),
                filled: true,
                fillColor: AppColors.inputFill,
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: FutureBuilder<List<Team>>(
                future: _future,
                builder: (context, s) {
                  if (s.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (s.hasError) return _message('Could not load teams.', Icons.cloud_off);
                  final teams = s.data ?? [];
                  if (teams.isEmpty) {
                    return _message(
                        _query.isEmpty
                            ? 'No public ${_sport == 'football' ? 'football' : 'cricket'} teams yet.'
                            : 'No teams match "$_query".',
                        Icons.search_off);
                  }
                  return ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                    itemCount: teams.length,
                    itemBuilder: (_, i) => _opponentCard(teams[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(String text, IconData icon) => ListView(
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * .2),
          Icon(icon, size: 64, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(text,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
          ),
        ],
      );

  Widget _opponentCard(Team t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.inputFill,
                backgroundImage: (t.logoUrl != null && t.logoUrl!.isNotEmpty)
                    ? CachedNetworkImageProvider(t.logoUrl!)
                    : null,
                child: (t.logoUrl == null || t.logoUrl!.isEmpty)
                    ? const Icon(Icons.shield_outlined, color: AppColors.primary)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                        'W ${t.wins}  L ${t.losses}  D ${t.draws}${t.city != null && t.city!.isNotEmpty ? '  ·  ${t.city}' : ''}',
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: AppColors.primary, borderRadius: BorderRadius.circular(20)),
                child: Text('ELO ${t.elo}',
                    style: GoogleFonts.poppins(
                        color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.sports_kabaddi, size: 16),
              label: const Text('Challenge'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => SnackbarUtil.showInfo(
                  context, 'Match challenges arrive with the matchmaking update.'),
            ),
          ),
        ],
      ),
    );
  }
}
