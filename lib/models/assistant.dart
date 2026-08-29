/// The Flutter half of Scout's wire contract.
///
/// `backend/src/utils/assistantReply.js` is the authority: every reply is
/// `{text, chips[], cards[{type, data}], source}` and the client renders by
/// `card.type`. This file is the mirror of that file and nothing else — when a
/// card type or a `source` value is added there, it is added here, and the two
/// lists are meant to be diffable by eye.
///
/// WHY THE CARD PAYLOADS ARE NOT TWELVE `fromJson` CLASSES
/// ------------------------------------------------------
/// Four of the twelve cards drive money or state — `venue`, `slot_picker`,
/// `confirm`, `booking` — and those get real typed models, because a mis-read
/// `deposit` or a dropped `slotId` is a wrong charge, not a cosmetic bug. The
/// other eight are read-only display (`player`, `team`, `tournament`, `map`,
/// `wallet`, `stats`, `policy`, `capabilities`); they go through [CardData], a
/// thin typed accessor over the raw map. That keeps a backend that adds a field
/// to a player card from needing a Dart release, while the money path stays
/// nailed down. `stats` is declared in the contract but produced by no action
/// yet, which is exactly the case [CardData] handles without a crash.
///
/// Everything numeric comes through `num_util.dart`: pg hands back `DECIMAL` as
/// a **String**, so `data['pricePerHour'] as double` throws on a real response.
library;

import '../utils/num_util.dart';

/// The six honest provenances of an answer, plus [unknown] for forward
/// compatibility — an unrecognised source must render as a grey pill, never
/// throw away the message that carried it.
///
/// Mirrors `SOURCES` in assistantReply.js and the `chk_assistant_turns_src`
/// database constraint. Surfaced in the UI on purpose: "did the model do this or
/// did you hard-code it?" is answerable per message, not per feature.
enum ScoutSource {
  live('live', 'Live data', 'Read from the database just now'),
  policy('policy', 'Policy', 'Quoted from the platform rules'),
  model('model', 'Model', 'Ranked by a trained model'),
  kb('kb', 'Owner answer', 'A venue owner already answered this'),
  menu('menu', 'Menu', 'A capability list, not an answer'),
  escalated('escalated', 'Sent to owner', 'Forwarded to the venue owner'),
  unknown('unknown', 'Unknown', 'Source not recognised by this app version');

  const ScoutSource(this.wire, this.label, this.gloss);

  /// The exact string on the wire and in `assistant_turns.answer_source`.
  final String wire;

  /// Two words for the pill on the bubble.
  final String label;

  /// One sentence for the "how I answered this" sheet.
  final String gloss;

  static ScoutSource from(Object? value) => values.firstWhere(
        (s) => s.wire == value,
        orElse: () => ScoutSource.unknown,
      );
}

/// A tappable suggestion.
///
/// [action] is the whole point. A chip press posts `{action, args}`, so it never
/// goes through the intent classifier — which is how capabilities the trained
/// label set does not cover stay fully reachable, and why a chip is not merely a
/// phrase to type. [label] is only what a human reads; changing the wording can
/// never change the behaviour.
class ScoutChip {
  final String label;
  final String action;
  final Map<String, dynamic>? args;

  const ScoutChip({required this.label, required this.action, this.args});

  factory ScoutChip.fromJson(Map<String, dynamic> j) => ScoutChip(
        label: (j['label'] ?? '').toString(),
        action: (j['action'] ?? '').toString(),
        args: j['args'] is Map ? Map<String, dynamic>.from(j['args'] as Map) : null,
      );

  static List<ScoutChip> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => ScoutChip.fromJson(Map<String, dynamic>.from(m)))
        .where((c) => c.action.isNotEmpty && c.label.isNotEmpty)
        .toList();
  }
}

/// A typed reader over one card's `data` map.
///
/// Every getter is total: a missing key gives a fallback, never an exception, so
/// a card the backend grew a field on still renders. The one place that is
/// deliberately *not* total is [pctOrNull] — see below.
class CardData {
  const CardData(this.raw);

  final Map<String, dynamic> raw;

  static CardData from(Object? raw) => CardData(
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{},
      );

  bool has(String key) => raw[key] != null;

  String str(String key, {String or = ''}) {
    final v = raw[key];
    return v == null ? or : v.toString().trim();
  }

  String? strOrNull(String key) {
    final v = raw[key];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  double money(String key) => asNum(raw[key]);

  double? moneyOrNull(String key) => asNumOrNull(raw[key]);

  int count(String key, {int or = 0}) => asInt(raw[key], fallback: or);

  int? intOrNull(String key) => asNumOrNull(raw[key])?.round();

  bool flag(String key) => raw[key] == true;

  /// A match percentage, **null-preserving**. `matchPct == null` means no ranker
  /// scored this row; the widget must then draw no badge at all. Coercing it to
  /// `0` would render "0% match" — a confident lie about a venue nobody scored.
  int? get pctOrNull => intOrNull('matchPct');

  List<String> strings(String key) {
    final v = raw[key];
    if (v is! List) return const [];
    return v
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  List<ScoutChip> buttons([String key = 'buttons']) => ScoutChip.listFrom(raw[key]);

  List<CardData> rows(String key) {
    final v = raw[key];
    if (v is! List) return const [];
    return v.whereType<Map>().map(CardData.from).toList();
  }

  /// Prefer the label the backend already formatted, and only format locally if
  /// it is absent. Currency belongs to one side of the wire; two formatters is
  /// how "PKR 2400" and "Rs 2,400.00" end up on the same screen.
  String label(String labelKey, String valueKey) =>
      strOrNull(labelKey) ?? formatPkr(moneyOrNull(valueKey));
}

/// `PKR 2,400` — the fallback for when the backend sent a raw amount only.
String formatPkr(double? amount) {
  if (amount == null) return '—';
  final whole = amount.abs().round();
  final digits = whole.toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return 'PKR ${amount < 0 ? '-' : ''}$grouped';
}

/// The twelve card types, mirroring `CARDS` in assistantReply.js. A type absent
/// from [all] is one this app build has no widget for; it is rendered as its text
/// only, which is why an unknown card never blanks a reply.
abstract final class ScoutCardType {
  static const String venue = 'venue';
  static const String booking = 'booking';
  static const String slotPicker = 'slot_picker';
  static const String confirm = 'confirm';
  static const String player = 'player';
  static const String team = 'team';
  static const String tournament = 'tournament';
  static const String map = 'map';
  static const String wallet = 'wallet';
  static const String stats = 'stats';
  static const String policy = 'policy';
  static const String capabilities = 'capabilities';

  static const List<String> all = <String>[
    venue, booking, slotPicker, confirm, player, team,
    tournament, map, wallet, stats, policy, capabilities,
  ];
}

/// One card: a type the client switches on, and the payload that type reads.
class ScoutCard {
  final String type;
  final CardData data;

  const ScoutCard({required this.type, required this.data});

  factory ScoutCard.fromJson(Map<String, dynamic> j) => ScoutCard(
        type: (j['type'] ?? '').toString(),
        data: CardData.from(j['data']),
      );

  bool get isKnown => ScoutCardType.all.contains(type);

  static List<ScoutCard> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => ScoutCard.fromJson(Map<String, dynamic>.from(m)))
        .where((c) => c.type.isNotEmpty)
        .toList();
  }
}

/// A ground, as Scout offers it. `matchPct`/`reasons` are present only when the
/// venue recommender ranked this list; both stay null/empty otherwise.
class VenueCardData {
  final String id;
  final String name;
  final String city;
  final String address;
  final String sport;
  final double? pricePerHour;
  final double? rating;
  final int totalReviews;
  final String? photo;
  final double? lat;
  final double? lng;
  final int? matchPct;
  final List<String> reasons;
  final List<ScoutChip> buttons;

  const VenueCardData({
    required this.id,
    required this.name,
    required this.city,
    required this.address,
    required this.sport,
    required this.pricePerHour,
    required this.rating,
    required this.totalReviews,
    required this.photo,
    required this.lat,
    required this.lng,
    required this.matchPct,
    required this.reasons,
    required this.buttons,
  });

  factory VenueCardData.of(CardData d) => VenueCardData(
        id: d.str('id'),
        name: d.str('name', or: 'Ground'),
        city: d.str('city'),
        address: d.str('address'),
        sport: d.str('sport'),
        pricePerHour: d.moneyOrNull('pricePerHour'),
        rating: d.moneyOrNull('rating'),
        totalReviews: d.count('totalReviews'),
        photo: d.strOrNull('photo'),
        lat: d.moneyOrNull('lat'),
        lng: d.moneyOrNull('lng'),
        matchPct: d.pctOrNull,
        reasons: d.strings('reasons'),
        buttons: d.buttons(),
      );

  bool get hasPin => lat != null && lng != null;
}

/// One selectable slot inside a [SlotPickerData].
///
/// [n] is the number the user can *say* — "slot 2", "the second one" — which is
/// how the dialog manager resolves an ordinal without another round trip. The
/// chip that comes back carries `{slotId, n}` so a tap and a sentence land on the
/// same code path.
class SlotOption {
  final int n;
  final String slotId;
  final String startTime;
  final String endTime;
  final String label;
  final double? price;
  final String priceLabel;

  const SlotOption({
    required this.n,
    required this.slotId,
    required this.startTime,
    required this.endTime,
    required this.label,
    required this.price,
    required this.priceLabel,
  });

  factory SlotOption.of(CardData d) => SlotOption(
        n: d.count('n'),
        slotId: d.str('slotId'),
        startTime: d.str('startTime'),
        endTime: d.str('endTime'),
        label: d.str('label', or: '${d.str('startTime')}–${d.str('endTime')}'),
        price: d.moneyOrNull('price'),
        priceLabel: d.label('priceLabel', 'price'),
      );
}

/// The slot grid: one ground, one date, the free hours on it.
class SlotPickerData {
  final String venueId;
  final String venueName;
  final String date;
  final String dateLabel;
  final List<SlotOption> slots;
  final List<ScoutChip> buttons;

  const SlotPickerData({
    required this.venueId,
    required this.venueName,
    required this.date,
    required this.dateLabel,
    required this.slots,
    required this.buttons,
  });

  factory SlotPickerData.of(CardData d) => SlotPickerData(
        venueId: d.str('venueId'),
        venueName: d.str('venueName', or: 'Ground'),
        date: d.str('date'),
        dateLabel: d.str('dateLabel', or: d.str('date')),
        slots: d.rows('slots').map(SlotOption.of).toList(),
        buttons: d.buttons(),
      );

  /// The chip the backend minted for a given slot, so the tap posts the
  /// backend's own `{slotId, n}` rather than arguments this client invented.
  ScoutChip? chipFor(SlotOption slot) {
    for (final b in buttons) {
      if (b.args?['slotId']?.toString() == slot.slotId) return b;
    }
    for (final b in buttons) {
      if (asNumOrNull(b.args?['n'])?.round() == slot.n) return b;
    }
    return null;
  }
}

/// One labelled row of a confirm card's detail table.
///
/// The backend sends `{label, value}` objects, not sentences — "Day: Sat 30 Aug",
/// "Refund to wallet: PKR 2,500 (100%)" — so the client can right-align the values
/// into a table a reader can scan down. A bare string is still accepted and lands
/// in [value] with no label, because a card that half-renders is worse than a card
/// with one unlabelled row.
class ConfirmLine {
  final String label;
  final String value;

  const ConfirmLine({required this.label, required this.value});

  static List<ConfirmLine> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <ConfirmLine>[];
    for (final e in raw) {
      if (e is Map) {
        final label = (e['label'] ?? '').toString().trim();
        final value = (e['value'] ?? '').toString().trim();
        if (value.isNotEmpty || label.isNotEmpty) {
          out.add(ConfirmLine(label: label, value: value));
        }
      } else if (e != null) {
        final v = e.toString().trim();
        if (v.isNotEmpty) out.add(ConfirmLine(label: '', value: v));
      }
    }
    return out;
  }
}

/// The last screen before money moves.
///
/// Rendered deliberately unlike every other card: this is the one place where a
/// mis-tap costs a deposit, so the amount, the deposit share and the note all
/// come straight from the server's own arithmetic — the client re-computes
/// nothing here.
class ConfirmData {
  final String what;
  final String title;
  final List<ConfirmLine> lines;
  final double? total;
  final String totalLabel;
  final double? deposit;
  final String depositLabel;
  final int? depositPct;
  final String? note;
  final List<ScoutChip> buttons;

  const ConfirmData({
    required this.what,
    required this.title,
    required this.lines,
    required this.total,
    required this.totalLabel,
    required this.deposit,
    required this.depositLabel,
    required this.depositPct,
    required this.note,
    required this.buttons,
  });

  factory ConfirmData.of(CardData d) => ConfirmData(
        what: d.str('what'),
        title: d.str('title', or: 'Confirm'),
        lines: ConfirmLine.listFrom(d.raw['lines']),
        total: d.moneyOrNull('total'),
        totalLabel: d.label('totalLabel', 'total'),
        deposit: d.moneyOrNull('deposit'),
        depositLabel: d.label('depositLabel', 'deposit'),
        depositPct: d.intOrNull('depositPct'),
        note: d.strOrNull('note'),
        buttons: d.buttons(),
      );

  /// True for the flow that spends money, as opposed to a cancellation confirm.
  bool get isPayment => what.contains('book');
}

/// A booking, before or after it exists. The same shape backs "here is what you
/// just booked" and every row of "my bookings", which is what makes the assistant
/// and the Bookings tab visibly one source of truth.
class BookingCardData {
  final String id;
  final String venueId;
  final String venueName;
  final String city;
  final String date;
  final String dateLabel;
  final String startTime;
  final String endTime;
  final String timeLabel;
  final String status;
  final double? total;
  final String totalLabel;
  final double? deposit;
  final String? qr;
  final List<ScoutChip> buttons;

  const BookingCardData({
    required this.id,
    required this.venueId,
    required this.venueName,
    required this.city,
    required this.date,
    required this.dateLabel,
    required this.startTime,
    required this.endTime,
    required this.timeLabel,
    required this.status,
    required this.total,
    required this.totalLabel,
    required this.deposit,
    required this.qr,
    required this.buttons,
  });

  factory BookingCardData.of(CardData d) => BookingCardData(
        id: d.str('id'),
        venueId: d.str('venueId'),
        venueName: d.str('venueName', or: 'Ground'),
        city: d.str('city'),
        date: d.str('date'),
        dateLabel: d.str('dateLabel', or: d.str('date')),
        startTime: d.str('startTime'),
        endTime: d.str('endTime'),
        timeLabel: d.str('timeLabel', or: '${d.str('startTime')}–${d.str('endTime')}'),
        status: d.str('status', or: 'pending').toLowerCase(),
        total: d.moneyOrNull('total'),
        totalLabel: d.label('totalLabel', 'total'),
        deposit: d.moneyOrNull('deposit'),
        qr: d.strOrNull('qr'),
        buttons: d.buttons(),
      );
}

/// Where the conversation stands, mirroring `FSM` in dialogManager.js.
///
/// The client uses this for one job only: shaping the composer. `awaitingConfirm`
/// means a confirm card is on screen and money is next, so the input hint changes
/// and typing something unrelated is the user's way out — it must not be blocked.
enum ScoutFsm {
  idle('idle'),
  slotFilling('slot_filling'),
  awaitingChoice('awaiting_choice'),
  awaitingConfirm('awaiting_confirm');

  const ScoutFsm(this.wire);
  final String wire;

  static ScoutFsm from(Object? value) =>
      values.firstWhere((f) => f.wire == value, orElse: () => ScoutFsm.idle);

  /// True while Scout is waiting on a specific answer rather than open chat.
  bool get isWaiting => this != ScoutFsm.idle;
}

/// What the classifier made of the message — the "how I answered this" evidence.
///
/// [abstained] is the honest case: the model was under threshold and refused to
/// guess, and the reply the user sees is the capability menu. `via` says whether
/// the label came from the model, a rule, or a chip that bypassed both.
class ScoutNlu {
  final String? intent;
  final double? confidence;
  final String? via;
  final bool abstained;
  final String? reason;
  final String? modelVersion;
  final int? ms;

  const ScoutNlu({
    this.intent,
    this.confidence,
    this.via,
    this.abstained = false,
    this.reason,
    this.modelVersion,
    this.ms,
  });

  factory ScoutNlu.fromJson(Map<String, dynamic> j) => ScoutNlu(
        intent: j['intent']?.toString(),
        confidence: asNumOrNull(j['confidence']),
        via: j['via']?.toString(),
        abstained: j['abstained'] == true,
        reason: j['reason']?.toString(),
        modelVersion: j['modelVersion']?.toString(),
        ms: asNumOrNull(j['ms'])?.round(),
      );

  /// Confidence as whole percent, or null when no model scored this turn (a chip
  /// press, for instance) — never 0, which would read as "the model was certain
  /// it was wrong".
  int? get confidencePct {
    final c = confidence;
    if (c == null) return null;
    return (c <= 1 ? c * 100 : c).round();
  }
}

/// One reply from Scout: the text, what to tap next, what to draw, and where the
/// answer came from.
class ScoutReply {
  final String text;
  final List<ScoutChip> chips;
  final List<ScoutCard> cards;
  final ScoutSource source;
  final String? action;
  final bool? actionOk;
  final Map<String, dynamic> meta;

  const ScoutReply({
    required this.text,
    required this.chips,
    required this.cards,
    required this.source,
    this.action,
    this.actionOk,
    this.meta = const {},
  });

  factory ScoutReply.fromJson(Map<String, dynamic> j) => ScoutReply(
        text: (j['text'] ?? '').toString(),
        chips: ScoutChip.listFrom(j['chips']),
        cards: ScoutCard.listFrom(j['cards']),
        source: ScoutSource.from(j['source']),
        action: j['action']?.toString(),
        actionOk: j['actionOk'] is bool ? j['actionOk'] as bool : null,
        meta: j['meta'] is Map ? Map<String, dynamic>.from(j['meta'] as Map) : const {},
      );

  /// The last-resort reply. Used when the network failed outright, so the bubble
  /// still arrives with a way forward instead of an empty grey box.
  static ScoutReply offline(String text) => ScoutReply(
        text: text,
        chips: const [ScoutChip(label: 'Try again', action: 'retry_last')],
        cards: const [],
        source: ScoutSource.unknown,
      );

  ScoutCard? cardOfType(String type) {
    for (final c in cards) {
      if (c.type == type) return c;
    }
    return null;
  }

  /// The screen an `app_help` answer points at, e.g. `bookings` — the hook that
  /// lets a "Take me there" button exist at all.
  String? get targetScreen => meta['screen']?.toString();

  Map<String, dynamic> toJson() => {
        'text': text,
        'source': source.wire,
        'chips': chips
            .map((c) => {'label': c.label, 'action': c.action, if (c.args != null) 'args': c.args})
            .toList(),
        'cards': cards.map((c) => {'type': c.type, 'data': c.data.raw}).toList(),
        if (action != null) 'action': action,
        if (actionOk != null) 'actionOk': actionOk,
        if (meta.isNotEmpty) 'meta': meta,
      };
}

/// The result of one `POST /message`.
///
/// [ok] is false when the turn failed, and a failed turn STILL carries a
/// renderable [reply] — the backend rolls the transaction back and hands over a
/// menu. The UI therefore draws a real bubble on failure rather than a toast that
/// leaves the conversation looking like nothing happened.
class ScoutTurn {
  final bool ok;
  final String? message;
  final String threadId;
  final bool threadCreated;
  final String? messageId;
  final ScoutReply reply;
  final ScoutFsm fsm;
  final String? pending;
  final String? intent;
  final Map<String, dynamic> slots;
  final ScoutNlu? nlu;
  final int? totalMs;

  const ScoutTurn({
    required this.ok,
    required this.threadId,
    required this.reply,
    this.message,
    this.threadCreated = false,
    this.messageId,
    this.fsm = ScoutFsm.idle,
    this.pending,
    this.intent,
    this.slots = const {},
    this.nlu,
    this.totalMs,
  });

  factory ScoutTurn.fromEnvelope(Map<String, dynamic> body) {
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : <String, dynamic>{};
    final state = data['state'] is Map
        ? Map<String, dynamic>.from(data['state'] as Map)
        : const <String, dynamic>{};
    final replyJson = data['reply'] is Map
        ? Map<String, dynamic>.from(data['reply'] as Map)
        : null;
    final msg = body['message']?.toString();
    return ScoutTurn(
      ok: body['success'] == true,
      message: msg,
      threadId: (data['threadId'] ?? '').toString(),
      threadCreated: data['threadCreated'] == true,
      messageId: data['messageId']?.toString(),
      reply: replyJson != null
          ? ScoutReply.fromJson(replyJson)
          : ScoutReply.offline(msg ?? 'Scout could not finish that message.'),
      fsm: ScoutFsm.from(state['fsm']),
      pending: state['pending']?.toString(),
      intent: state['intent']?.toString(),
      slots: state['slots'] is Map
          ? Map<String, dynamic>.from(state['slots'] as Map)
          : const {},
      nlu: data['nlu'] is Map
          ? ScoutNlu.fromJson(Map<String, dynamic>.from(data['nlu'] as Map))
          : null,
      totalMs: asNumOrNull(data['totalMs'])?.round(),
    );
  }
}

/// Whether a message the user typed has reached the server yet.
enum ScoutDelivery { sending, sent, failed }

/// One bubble.
///
/// User messages are drawn optimistically the instant they are typed, so [id] may
/// be a local placeholder until the server answers. Scout messages keep the whole
/// [reply] because that is what makes an hour-old turn re-draw its venue cards
/// instead of degrading into plain text.
class ScoutMessage {
  final String id;
  final bool isScout;
  final String text;
  final ScoutReply? reply;
  final DateTime createdAt;
  final ScoutDelivery delivery;
  final String? clientId;
  final ScoutNlu? nlu;
  final int vote;

  const ScoutMessage({
    required this.id,
    required this.isScout,
    required this.text,
    required this.createdAt,
    this.reply,
    this.delivery = ScoutDelivery.sent,
    this.clientId,
    this.nlu,
    this.vote = 0,
  });

  factory ScoutMessage.user(String text, {required String clientId}) => ScoutMessage(
        id: 'local:$clientId',
        isScout: false,
        text: text,
        createdAt: DateTime.now(),
        delivery: ScoutDelivery.sending,
        clientId: clientId,
      );

  factory ScoutMessage.scout(ScoutReply reply, {String? id, ScoutNlu? nlu}) => ScoutMessage(
        id: id ?? 'local:scout:${DateTime.now().microsecondsSinceEpoch}',
        isScout: true,
        text: reply.text,
        createdAt: DateTime.now(),
        reply: reply,
        nlu: nlu,
      );

  factory ScoutMessage.fromHistory(Map<String, dynamic> j) {
    final isScout = j['role']?.toString() == 'scout';
    final payload = j['payload'] is Map
        ? Map<String, dynamic>.from(j['payload'] as Map)
        : null;
    return ScoutMessage(
      id: (j['id'] ?? '').toString(),
      isScout: isScout,
      text: (j['text'] ?? '').toString(),
      createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      reply: isScout && payload != null ? ScoutReply.fromJson(payload) : null,
    );
  }

  bool get isLocal => id.startsWith('local:');

  /// Only a real server id can be voted on, and only Scout's own words.
  bool get canVote => isScout && !isLocal && id.isNotEmpty;

  ScoutMessage copyWith({
    String? id,
    ScoutDelivery? delivery,
    int? vote,
    ScoutNlu? nlu,
  }) =>
      ScoutMessage(
        id: id ?? this.id,
        isScout: isScout,
        text: text,
        createdAt: createdAt,
        reply: reply,
        delivery: delivery ?? this.delivery,
        clientId: clientId,
        nlu: nlu ?? this.nlu,
        vote: vote ?? this.vote,
      );
}

/// One conversation in the chat list.
class ScoutThread {
  final String id;
  final String title;
  final bool archived;
  final String persona;
  final DateTime? createdAt;
  final DateTime? lastMessageAt;
  final String? preview;
  final int messageCount;

  const ScoutThread({
    required this.id,
    required this.title,
    this.archived = false,
    this.persona = 'Scout',
    this.createdAt,
    this.lastMessageAt,
    this.preview,
    this.messageCount = 0,
  });

  factory ScoutThread.fromJson(Map<String, dynamic> j) => ScoutThread(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString().trim().isEmpty
            ? 'New chat'
            : j['title'].toString().trim(),
        archived: j['archived_at'] != null || j['archivedAt'] != null,
        persona: (j['assistant_persona'] ?? j['persona'] ?? 'Scout').toString(),
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '')?.toLocal(),
        lastMessageAt:
            DateTime.tryParse((j['last_message_at'] ?? j['created_at'])?.toString() ?? '')
                ?.toLocal(),
        preview: (j['last_message_preview'] ?? j['preview'])?.toString(),
        messageCount: asInt(j['message_count'] ?? j['messageCount']),
      );
}

/// One page of history, oldest-first, plus the cursor for the page BEFORE it.
///
/// [cursor] is an opaque message id, not a timestamp: two messages in the same
/// turn share a `created_at` down to the microsecond, so paging by time can drop
/// or repeat one. The server sorts by `(created_at, is_assistant, id)` and this
/// cursor names a row in that order.
class ScoutHistoryPage {
  final List<ScoutMessage> messages;
  final bool hasMore;
  final String? cursor;

  /// The thread's own title and dialog state travel with the first page, so a
  /// chat reopened mid-booking restores its confirm prompt instead of looking
  /// like an idle conversation that happens to end in a confirm card.
  final String? title;
  final ScoutFsm fsm;

  const ScoutHistoryPage({
    required this.messages,
    required this.hasMore,
    required this.cursor,
    this.title,
    this.fsm = ScoutFsm.idle,
  });

  static const ScoutHistoryPage empty =
      ScoutHistoryPage(messages: [], hasMore: false, cursor: null);

  factory ScoutHistoryPage.fromJson(Map<String, dynamic> data) {
    final thread = data['thread'] is Map
        ? Map<String, dynamic>.from(data['thread'] as Map)
        : const <String, dynamic>{};
    final state = data['state'] is Map
        ? Map<String, dynamic>.from(data['state'] as Map)
        : const <String, dynamic>{};
    return ScoutHistoryPage(
      messages: (data['messages'] is List ? data['messages'] as List : const [])
          .whereType<Map>()
          .map((m) => ScoutMessage.fromHistory(Map<String, dynamic>.from(m)))
          .toList(),
      hasMore: data['hasMore'] == true,
      cursor: data['cursor']?.toString(),
      title: thread['title']?.toString(),
      fsm: ScoutFsm.from(state['fsm']),
    );
  }
}

/// One row of "what Scout can do", from `GET /capabilities` or a `capabilities`
/// card. [action] is executable, which is what makes the help sheet a set of
/// buttons rather than a paragraph.
class ScoutCapability {
  final String action;
  final String label;
  final String group;
  final String gloss;

  const ScoutCapability({
    required this.action,
    required this.label,
    required this.group,
    required this.gloss,
  });

  factory ScoutCapability.fromJson(Map<String, dynamic> j) => ScoutCapability(
        action: (j['action'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        group: (j['group'] ?? 'More').toString(),
        gloss: (j['gloss'] ?? '').toString(),
      );

  static List<ScoutCapability> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => ScoutCapability.fromJson(Map<String, dynamic>.from(m)))
        .where((c) => c.action.isNotEmpty && c.label.isNotEmpty)
        .toList();
  }

  /// Grouped in the backend's own declaration order, so the help sheet and the
  /// abstain menu list the same abilities under the same headings.
  static List<({String group, List<ScoutCapability> items})> grouped(
    List<ScoutCapability> all,
  ) {
    final order = <String>[];
    final byGroup = <String, List<ScoutCapability>>{};
    for (final c in all) {
      if (!byGroup.containsKey(c.group)) {
        byGroup[c.group] = <ScoutCapability>[];
        order.add(c.group);
      }
      byGroup[c.group]!.add(c);
    }
    return order.map((g) => (group: g, items: byGroup[g]!)).toList();
  }
}
