import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../widgets/trust_widgets.dart';

/// M25 — Trust Profile. The human-readable face of Trust Score 2.0.
///
/// The number on its own means nothing to a player; what earns confidence is
/// seeing *why* it is what it is. So the gauge is backed by the four weighted
/// components that produced it (⭐ rating 35 · 📅 attendance 30 · ⚖️ dispute-free 20 ·
/// 🤖 sentiment 15) and a ledger of the actual reviews behind the rating. A
/// component with no signal yet reads "No data yet" — never a zero — because an
/// unmeasured record is not a bad one.
///
/// Reached two ways: the owner viewing their own profile (`isSelf`), or anyone
/// viewing another player (a captain, an opponent). Give it a [userId] and it reads
/// the live breakdown from `GET /users/:id/reviews`; the legacy [profile] map is a
/// fallback for callers that only hold the old profile blob.
class TrustScoreScreen extends StatefulWidget {
  final String? userId;
  final Map<String, dynamic>? profile;
  final String? displayName;
  final String? avatarUrl;
  final bool isCaptain;
  final bool isSelf;

  const TrustScoreScreen({
    super.key,
    this.userId,
    this.profile,
    this.displayName,
    this.avatarUrl,
    this.isCaptain = false,
    this.isSelf = true,
  });

  @override
  State<TrustScoreScreen> createState() => _TrustScoreScreenState();
}

class _TrustScoreScreenState extends State<TrustScoreScreen> {
  final ReviewService _service = ReviewService();

  UserReviews _data = UserReviews.empty;
  bool _loading = true;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _userId = widget.userId ?? _idFromProfile();
    _load();
  }

  String? _idFromProfile() {
    final p = widget.profile;
    if (p == null) return null;
    final raw = p['user_id'] ?? p['userId'] ?? p['id'];
    final s = raw?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Legacy fallback for the gauge when there is no live breakdown to read.
  int? _profileScore() {
    final raw = widget.profile?['trust_score'];
    if (raw == null) return null;
    if (raw is num) return raw.round();
    return num.tryParse(raw.toString())?.round();
  }

  Future<void> _load() async {
    final id = _userId;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final res = await _service.userReviews(token, id);
    if (!mounted) return;
    setState(() {
      _data = res;
      _loading = false;
    });
  }

  String get _name => widget.displayName ?? widget.profile?['name']?.toString() ?? 'Player';

  @override
  Widget build(BuildContext context) {
    final trust = _data.trust;
    final score = trust.score ?? _profileScore();
    final tone = TrustTone.of(score);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Trust Score',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _identity(tone),
                    const SizedBox(height: 20),
                    Center(child: TrustGauge(score: score)),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        widget.isSelf
                            ? 'This is how other players and venues see you.'
                            : 'How SportLynk rates ${_name.split(' ').first}.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _sectionTitle('Score Breakdown'),
                    const SizedBox(height: 12),
                    _tiles(trust),
                    const SizedBox(height: 12),
                    _formulaNote(),
                    const SizedBox(height: 24),
                    _sectionTitle(widget.isSelf ? 'Reviews About You' : 'Recent Reviews'),
                    const SizedBox(height: 12),
                    _ledger(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  // Identity header
  Widget _identity(TrustTone tone) {
    final avatarUrl = widget.avatarUrl ?? widget.profile?['avatar_url']?.toString();
    final initial = _name.trim().isNotEmpty ? _name.trim()[0].toUpperCase() : 'P';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppColors.accentLight,
            backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty) ? NetworkImage(avatarUrl) : null,
            child: (avatarUrl == null || avatarUrl.isEmpty)
                ? Text(initial,
                    style: GoogleFonts.poppins(
                        fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.accent))
                : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.isCaptain)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'TEAM CAPTAIN',
                          style: GoogleFonts.poppins(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: tone.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified_outlined, size: 13, color: tone.color),
                          const SizedBox(width: 4),
                          Text(
                            tone.label,
                            style: GoogleFonts.poppins(
                                fontSize: 11, fontWeight: FontWeight.w700, color: tone.color),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The four weighted components
  Widget _tiles(TrustBreakdown t) {
    final avg = _data.avgStars;
    final tiles = <Widget>[
      TrustMetricTile(
        emoji: '⭐',
        label: 'Avg Rating',
        fraction: t.rating,
        valueText: avg != null
            ? '${avg.toStringAsFixed(1)} / 5'
            : (t.rating != null ? '${(t.rating! * 100).round()}%' : null),
        weight: TrustBreakdown.wRating,
      ),
      TrustMetricTile(
        emoji: '📅',
        label: 'Attendance',
        fraction: t.attendance,
        valueText: t.attendance != null ? '${(t.attendance! * 100).round()}%' : null,
        weight: TrustBreakdown.wAttendance,
      ),
      TrustMetricTile(
        emoji: '⚖️',
        label: 'Dispute-free',
        fraction: t.disputes,
        valueText: t.disputes != null ? '${(t.disputes! * 100).round()}%' : null,
        weight: TrustBreakdown.wDisputes,
      ),
      TrustMetricTile(
        emoji: '🤖',
        label: 'AI Sentiment',
        fraction: t.sentiment,
        valueText: t.sentiment != null ? '${(t.sentiment! * 100).round()}%' : null,
        weight: TrustBreakdown.wSentiment,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: tiles.map((t) => SizedBox(width: w, child: t)).toList(),
        );
      },
    );
  }

  Widget _formulaNote() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.calculate_outlined, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Trust = 35% rating + 30% attendance + 20% dispute-free + 15% sentiment. '
              'Components with no data yet don\'t count against you.',
              style: GoogleFonts.poppins(fontSize: 11.5, height: 1.45, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ledger() {
    if (_userId == null) {
      return _ledgerEmpty('Sign in to see the reviews behind this score.');
    }
    if (_data.reviews.isEmpty) {
      return _ledgerEmpty(widget.isSelf
          ? 'No reviews about you yet. Play a match or use a venue to start building your record.'
          : 'No reviews yet.');
    }
    return Column(
      children: _data.reviews.map((r) => ReviewCard(review: r, showType: true)).toList(),
    );
  }

  Widget _ledgerEmpty(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.reviews_outlined, size: 30, color: AppColors.textSecondary),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 12.5, height: 1.45, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
      );
}
