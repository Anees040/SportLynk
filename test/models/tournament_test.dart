// Tournament wire model tests: the tournament row, the entry, the venue block.
//
// Registration is money held before an organiser has decided anything, so the
// distinction this file defends is `registered` (fee frozen, awaiting approval)
// against `accepted` (in the field). Both hold a spot, which is why the capacity
// bar counts them together, and only one of them means the team is in.
//
// The second rule is that the countdown belongs to the server. `secondsToDeadline`
// is computed against the server clock and is preferred wherever it was sent; the
// deadline stamp is the fallback for the detail payload, which does not carry one.
// A phone an hour out of true must not be the reason a captain misses a deadline.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/team.dart';
import 'package:sportlynk/models/tournament.dart';

void main() {
  group('EntryStatus', () {
    test('awaiting approval and confirmed are worded apart', () {
      expect(EntryStatus.label(EntryStatus.registered), 'Awaiting approval');
      expect(EntryStatus.label(EntryStatus.accepted), 'Confirmed');
      expect(EntryStatus.label(EntryStatus.eliminated), 'Knocked out');
      expect(EntryStatus.label(EntryStatus.withdrawn), 'Withdrawn');
      expect(EntryStatus.label(EntryStatus.rejected), 'Rejected');
    });

    test('an unrecognised state degrades to itself rather than to nothing', () {
      expect(EntryStatus.label('refunded'), 'refunded');
      expect(EntryStatus.label(null), '');
    });
  });

  group('TournamentFormat', () {
    test('only round robin is named, and everything else reads as knockout', () {
      expect(TournamentFormat.label(TournamentFormat.roundRobin), 'Round robin');
      expect(TournamentFormat.label(TournamentFormat.knockout), 'Knockout');
      expect(TournamentFormat.label(null), 'Knockout');
      expect(TournamentFormat.label('swiss'), 'Knockout',
          reason: 'a newer format renders as something rather than as blank');
    });
  });

  group('TournamentVenue', () {
    test('the rating and price arrive as pg strings and stay absent when unset', () {
      final v = TournamentVenue.fromJson({
        'id': 'v1',
        'name': 'F-11 Arena',
        'city': 'Islamabad',
        'rating': '4.60',
        'pricePerHour': '2400.00',
      });
      expect(v.rating, 4.6);
      expect(v.pricePerHour, 2400.0);
      expect(v.where, 'F-11 Arena · Islamabad');
      expect(v.display, 'F-11 Arena');
    });

    test('an unnamed venue is still referred to, never left blank', () {
      expect(TournamentVenue.unknown.display, 'The venue');
      expect(TournamentVenue.unknown.where, '');
      expect(TournamentVenue.unknown.rating, isNull);
    });

    test('where joins only the halves that exist', () {
      expect(TournamentVenue.fromJson({'name': 'F-11 Arena'}).where, 'F-11 Arena');
      expect(TournamentVenue.fromJson({'city': 'Islamabad'}).where, 'Islamabad');
      expect(TournamentVenue.fromJson({'name': '   '}).where, '   ',
          reason: 'the _str helper in tournament.dart drops empty but does not trim, '
              'unlike the same-named helper in admin.dart and report.dart');
    });
  });

  group('TeamRecord', () {
    test('a squad that has never entered one prints no line at all', () {
      expect(TeamRecord.none.isEmpty, isTrue);
      expect(TeamRecord.none.line, '',
          reason: '"0 played · 0 W" on every card would be noise on most of them');
      expect(TeamRecord.fromJson({}).line, '');
    });

    test('played and wins are always shown once there is a record', () {
      final r = TeamRecord.fromJson({'played': '12', 'wins': '8'});
      expect(r.isEmpty, isFalse);
      expect(r.line, '12 played · 8 W');
    });

    test('finals and titles are added only when non-zero, and pluralised', () {
      expect(
        TeamRecord.fromJson({'played': 4, 'wins': 3, 'finals': 1}).line,
        '4 played · 3 W · 1 final',
      );
      expect(
        TeamRecord.fromJson({'played': 12, 'wins': 8, 'finals': 3, 'titles': 2}).line,
        '12 played · 8 W · 3 finals · 2 titles 🏆',
      );
      expect(
        TeamRecord.fromJson({'played': 6, 'wins': 5, 'finals': 1, 'titles': 1}).line,
        '6 played · 5 W · 1 final · 1 title 🏆',
      );
    });

    test('a title with no played count still counts as a record', () {
      expect(TeamRecord.fromJson({'titles': 1}).isEmpty, isFalse);
      expect(TeamRecord.fromJson({'finals': 1}).isEmpty, isFalse);
      expect(TeamRecord.fromJson({'wins': 3}).isEmpty, isTrue,
          reason: 'wins without a played count is a contradiction, not a record');
    });

    test('the extension reads the four counters off a teams row', () {
      final t = Team.fromJson({
        'id': 't1',
        'name': 'Islamabad United',
        'sport': 'football',
        'tournament_played': '12',
        'tournament_wins': '8',
        'finals_reached': '3',
        'titles': '2',
      });
      final r = t.tournamentRecord;
      expect(r.played, 12);
      expect(r.wins, 8);
      expect(r.finals, 3);
      expect(r.titles, 2);
      expect(r.line, '12 played · 8 W · 3 finals · 2 titles 🏆');
    });

    test('a team that never entered one reads as an empty record', () {
      final t = Team.fromJson({'id': 't1', 'name': 'A', 'sport': 'football'});
      expect(t.tournamentRecord.isEmpty, isTrue);
      expect(t.tournamentRecord.line, '');
    });
  });

  group('MyEntry', () {
    test('only a captain who still holds a spot may withdraw', () {
      MyEntry entry(String status, {bool captain = true}) => MyEntry.fromJson({
            'teamId': 't1',
            'status': status,
            'isCaptain': captain,
          });
      expect(entry(EntryStatus.registered).canWithdraw, isTrue);
      expect(entry(EntryStatus.accepted).canWithdraw, isTrue);
      expect(entry(EntryStatus.eliminated).canWithdraw, isFalse);
      expect(entry(EntryStatus.withdrawn).canWithdraw, isFalse);
      expect(entry(EntryStatus.accepted, captain: false).canWithdraw, isFalse,
          reason: 'a squad member sees the bracket but cannot spend the team fee');
    });

    test('isCaptain requires a literal true, since it gates a refund', () {
      expect(MyEntry.fromJson({'teamId': 't1', 'isCaptain': 'true'}).isCaptain, isFalse);
      expect(MyEntry.fromJson({'teamId': 't1', 'isCaptain': 1}).isCaptain, isFalse);
    });

    test('the paid amount arrives as a pg string and the seed stays absent', () {
      final e = MyEntry.fromJson({
        'teamId': 't1',
        'teamName': 'Islamabad United',
        'status': EntryStatus.accepted,
        'paidAmount': '4000.00',
      });
      expect(e.paidAmount, 4000.0);
      expect(e.seed, isNull);
      expect(e.eliminatedRound, isNull);
      expect(e.label, 'Confirmed');
    });

    test('an unnamed entry names the team rather than showing nothing', () {
      final e = MyEntry.fromJson({'teamId': 't1'});
      expect(e.teamName, 'My team');
      expect(e.label, '');
      expect(e.isHolding, isFalse);
      expect(e.paidAmount, 0);
    });

    test('a seeded, knocked-out entry keeps both numbers', () {
      final e = MyEntry.fromJson({
        'teamId': 't1',
        'status': EntryStatus.eliminated,
        'seed': '3',
        'eliminatedRound': '2',
      });
      expect(e.seed, 3);
      expect(e.eliminatedRound, 2);
      expect(e.label, 'Knocked out');
      expect(e.isHolding, isFalse);
    });
  });

  group('Tournament', () {
    Tournament t([Map<String, dynamic> extra = const {}]) => Tournament.fromJson({
          'id': 'tr1',
          'name': 'Ramadan Cup',
          'sport': 'football',
          ...extra,
        });

    test('the four states each have their own wording', () {
      expect(t({'status': 'open'}).statusLabel, 'Registration open');
      expect(t({'status': 'active'}).statusLabel, 'In progress');
      expect(t({'status': 'completed'}).statusLabel, 'Finished');
      expect(t({'status': 'cancelled'}).statusLabel, 'Cancelled');
    });

    test('an unrecognised state renders as itself instead of throwing', () {
      final x = t({'status': 'seeding'});
      expect(x.statusLabel, 'seeding');
      expect(x.isOpen, isFalse);
      expect(x.isActive, isFalse);
    });

    test('the defaults are the ones the create form starts from', () {
      final x = t();
      expect(x.status, 'open');
      expect(x.format, 'knockout');
      expect(x.maxTeams, 8);
      expect(x.minTeams, 4);
      expect(x.slotMinutes, 60);
      expect(x.prizePercent, 60);
      expect(x.winnerPercent, 70);
      expect(x.runnerupPercent, 30);
      expect(x.name, 'Ramadan Cup');
    });

    test('every money field arrives as a pg decimal string', () {
      final x = t({
        'entryFee': '4000.00',
        'pool': '32000.00',
        'venueCost': '9600.00',
        'prize': '19200.00',
        'ownerEarning': '3200.00',
      });
      expect(x.entryFee, 4000.0);
      expect(x.pool, 32000.0);
      expect(x.venueCost, 9600.0);
      expect(x.prize, 19200.0);
      expect(x.ownerEarning, 3200.0);
      expect(x.hasPrize, isTrue);
    });

    test('the capacity bar counts holding entries, not approved ones', () {
      final x = t({'teamsRegistered': 6, 'teamsAccepted': 2, 'maxTeams': 8});
      expect(x.capacityFraction, 0.75,
          reason: 'a frozen fee has already taken the spot');
      expect(x.capacityLabel, '6 / 8 teams');
    });

    test('the capacity fraction is clamped and survives a zero cap', () {
      expect(t({'teamsRegistered': 10, 'maxTeams': 8}).capacityFraction, 1.0);
      expect(t({'teamsRegistered': 0, 'maxTeams': 8}).capacityFraction, 0.0);
      expect(t({'maxTeams': 0}).capacityFraction, 0.0);
    });

    test('the server full flag wins over the computed one', () {
      expect(t({'isFull': true, 'spotsLeft': 3}).isFull, isTrue);
      expect(t({'isFull': false, 'spotsLeft': 0}).isFull, isFalse,
          reason: 'the browse list computes fullness against holding entries');
      expect(t({'spotsLeft': 0}).isFull, isTrue);
      expect(t({'spotsLeft': 3}).isFull, isFalse);
    });

    test('the last spot is worded as urgency, not as a count', () {
      expect(t({'spotsLeft': 3}).spotsLabel, '3 spots left');
      expect(t({'spotsLeft': 1}).spotsLabel, 'Last spot');
      expect(t({'spotsLeft': 0}).spotsLabel, 'Full');
      expect(t({'isFull': true, 'spotsLeft': 2}).spotsLabel, 'Full');
    });

    test('a fee split across a squad is the number a captain acts on', () {
      final x = t({'entryFee': '4000.00'});
      expect(x.perPlayer(7), closeTo(571.43, 0.01));
      expect(x.perPlayer(0), 4000.0, reason: 'a squad of nobody cannot be divided by');
      expect(x.perPlayer(-1), 4000.0);
    });

    test('a champion exists only once a winning team id was recorded', () {
      expect(t().hasChampion, isFalse);
      expect(t({'winnerName': 'Islamabad United'}).hasChampion, isFalse,
          reason: 'a name without an id cannot be linked to a team');
      expect(t({'winnerTeam': 't1', 'winnerName': 'Islamabad United'}).hasChampion, isTrue);
    });

    test('the bracket exists only once fixtures were generated', () {
      expect(t().hasBracket, isFalse);
      expect(t({'fixturesGeneratedAt': '2026-09-01T10:00:00Z'}).hasBracket, isTrue);
    });

    test('the organiser name falls back to the owner name', () {
      expect(t({'ownerName': 'Ali Raza'}).organiserName, 'Ali Raza');
      expect(t({'ownerName': 'Ali', 'organiserName': 'Ramadan Cup FC'}).organiserName,
          'Ramadan Cup FC');
      expect(t().organiserName, isNull);
    });

    test('the nested entry and economics blocks are read only when present', () {
      expect(t().myEntry, isNull);
      expect(t({'myEntry': 'none'}).myEntry, isNull);
      expect(t({'myEntry': {'teamId': 't1', 'isCaptain': true}}).myEntry!.isCaptain,
          isTrue);
      expect(t({'economics': 'none'}).economics, isNull);
    });
  });

  group('Tournament.registrationOpen', () {
    Tournament t([Map<String, dynamic> extra = const {}]) =>
        Tournament.fromJson({'id': 'tr1', ...extra});

    test('the server flag is taken verbatim when it was sent', () {
      expect(t({'registrationOpen': true, 'status': 'completed'}).registrationOpen,
          isTrue);
      expect(t({'registrationOpen': false, 'status': 'open'}).registrationOpen, isFalse);
    });

    test('without the flag it is derived from status, fullness and the deadline', () {
      expect(t({'status': 'open'}).registrationOpen, isTrue);
      expect(t({'status': 'active'}).registrationOpen, isFalse);
      expect(t({'status': 'open', 'isFull': true}).registrationOpen, isFalse);
      expect(t({'status': 'open', 'secondsToDeadline': 0}).registrationOpen, isFalse);
      expect(t({'status': 'open', 'secondsToDeadline': -60}).registrationOpen, isFalse);
      expect(t({'status': 'open', 'secondsToDeadline': 3600}).registrationOpen, isTrue);
    });

    test('a full-flag of false does not close registration', () {
      expect(t({'status': 'open', 'isFull': false}).registrationOpen, isTrue);
    });
  });

  group('Tournament.countdown', () {
    Tournament t([Map<String, dynamic> extra = const {}]) =>
        Tournament.fromJson({'id': 'tr1', ...extra});

    test('the server countdown is preferred over the local clock', () {
      expect(t({'secondsToDeadline': 3600 * 52}).timeLeft, const Duration(hours: 52));
      expect(t({'secondsToDeadline': 3600 * 52}).countdown, 'Closes in 2d 4h');
    });

    test('a whole number of days omits the hours', () {
      expect(t({'secondsToDeadline': 3600 * 48}).countdown, 'Closes in 2d');
    });

    test('under a day it counts in hours and minutes', () {
      expect(t({'secondsToDeadline': 3600 * 5 + 1800}).countdown, 'Closes in 5h 30m');
      expect(t({'secondsToDeadline': 3600 * 5}).countdown, 'Closes in 5h');
      expect(t({'secondsToDeadline': 45 * 60}).countdown, 'Closes in 45m');
    });

    test('the last minute is named rather than counted to zero', () {
      expect(t({'secondsToDeadline': 30}).countdown, 'Closing now');
      expect(t({'secondsToDeadline': 0}).countdown, 'Registration closed');
      expect(t({'secondsToDeadline': -3600}).countdown, 'Registration closed');
    });

    test('a past deadline stamp clamps to zero rather than counting backwards', () {
      final past = DateTime.now().subtract(const Duration(hours: 3)).toIso8601String();
      final x = t({'registrationDeadline': past});
      expect(x.timeLeft, Duration.zero);
      expect(x.countdown, 'Registration closed');
    });

    test('a future deadline stamp is used when no countdown was sent', () {
      final soon = DateTime.now().add(const Duration(hours: 5)).toIso8601String();
      final x = t({'registrationDeadline': soon});
      expect(x.timeLeft!.inHours, anyOf(4, 5));
      expect(x.countdown, startsWith('Closes in 4h'));
    });

    test('with no deadline at all an open tournament says so', () {
      expect(t({'status': 'open'}).timeLeft, isNull);
      expect(t({'status': 'open'}).countdown, 'Deadline not set');
      expect(t({'status': 'active'}).countdown, 'In progress',
          reason: 'a started tournament shows its state, not a missing deadline');
      expect(t({'status': 'completed'}).countdown, 'Finished');
    });
  });
}
