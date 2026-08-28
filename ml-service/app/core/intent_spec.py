"""Intent contract and dataset vocabulary for the SportLynk assistant (S.6).

THIS MODULE IS THE LABEL CONTRACT FOR MODEL #4.
It is the fourth member of the ``app/core`` contract family -- ``features.py``
(model #1, pricing), ``text_norm.py`` (model #2, sentiment), ``reco_features.py``
and ``reco_rank.py`` (model #3 and the S.5 scorer) -- and it follows the same
rule: one definition, imported by the generator, by training, by evaluation and
later by serving, with a version string and a source fingerprint stamped into
every artifact so that a silent edit becomes a load-time ``incompatible``
instead of unexplained drift three weeks later.

Two fingerprints, on purpose
----------------------------
This module carries two kinds of data with genuinely different lifetimes, so it
publishes two hashes rather than one:

* :func:`intent_spec_fingerprint` covers the LABEL CONTRACT -- the 15 intent
  names, their order, the language tags, the phenomena vocabulary. A trained
  classifier's ``classes_`` are meaningless if this changes, so a mismatch has
  to invalidate the model.
* :func:`dataset_spec_fingerprint` covers the GENERATION TABLES -- slot
  vocabularies, tidy rules, quotas, gate thresholds. These describe how one
  dataset was built. Adding a Rawalpindi sector to ``SLOT_VOCAB`` in a later
  wave changes the next dataset; it does not make an already-trained model
  wrong.

One combined hash was the first design and it was wrong: it would mark every
existing artifact incompatible the first time somebody added an area, which is
how a team learns to ignore a gate. A fingerprint must only fire for a change
that actually breaks something.

What this module is NOT
----------------------
It is not the serving-time NLU contract. Wave A produces a dataset. The request
normaliser, the confidence floor, the entity extractor's regexes and the
``/nlu/parse`` response shape are Wave B's problem and belong in their own
module. Everything here that serving will eventually need is in section 2 (the
label contract); sections 3 to 5 exist only to build a CSV.

Why the dedup key is local and does NOT reuse ``text_norm``
----------------------------------------------------------
``text_norm.normalize_text`` is right there and reusing it would be one import.
It would also quietly destroy this dataset. Its ``VARIANTS`` table folds
``nhi -> nahi``, ``kia -> kya``, ``plz -> please``, ``thk -> theek`` -- which is
exactly the spelling diversity a Roman Urdu intent corpus exists to teach.
Deduplicating on that key would delete "nhi mila" as a duplicate of "nahi mila"
and leave the classifier with one spelling of every word.

:func:`dedup_key` therefore does the minimum that makes two rows *the same
utterance* (casefold, drop punctuation, collapse whitespace) and nothing that
makes two spellings the same word. The second reason is coupling: a dataset
whose row identity depended on model #2's lexicon would change shape every time
the sentiment model was tuned.

Generated rows are repaired, hand-written rows are only judged
-------------------------------------------------------------
:func:`tidy` REWRITES a row; :func:`text_problems` only REPORTS on one. Which
applies depends on where the row came from, and the two must never be swapped.

A generated row's defects belong to the generator -- an empty ``{polite}`` draw
leaves "salam " and "hai ? ?" -- so there is nobody to ask and ``tidy`` fixes
them. An authored row's oddities are the data: "mere paise kahan gaye??" and
"20 25 log aayenge :)" are how people actually type, and running them through
``tidy`` would rewrite them into the generator's house style, which is the exact
naturalness the sprint plan spent 236 hand-written rows buying. So authored and
exam rows are checked and, if wrong, sent back to the author -- never silently
cleaned.

Determinism rules this module exists to enforce
----------------------------------------------
1. Every table is an ordered ``tuple``. Iteration order is part of the contract:
   it feeds both fingerprints and the generator's index arithmetic.
2. :func:`stable_seed` is the ONLY sanctioned way to derive a per-key RNG seed.
   Python's builtin ``hash()`` is salted per process (``PYTHONHASHSEED``), so a
   generator seeded off it emits a different CSV on every run while looking
   perfectly deterministic in code review. That is the single most likely way to
   lose reproducibility here, so the correct primitive lives in the contract
   rather than in one script.
3. :func:`slot_values` deduplicates while preserving first-seen order, so a
   value listed in both the neutral and a language bucket contributes one choice
   and not two -- otherwise a "mix" template would draw ``ground`` twice as
   often as ``pitch`` for no stated reason.

Slot realism is bounded, and that is accepted
--------------------------------------------
Template expansion is a cross product, so ``{sport} {venue_word}`` will emit
"badminton turf". Nobody says that. It stays because the classifier's job is to
recognise the FRAME -- "<sport> <venue-noun> in <area>" is a discovery request
whatever the nouns are -- and because the entity extractor is rule-based, so an
odd noun pairing costs a little realism and buys complete slot coverage. What is
NOT accepted, and what :func:`validate_pattern` rejects, is a pattern that turns
ungrammatical or changes intent for some value of its own slots.

stdlib only: ``re``, ``hashlib``, ``unicodedata``. The generator, the exam
validator and a CLI all import this, so it must not drag in pandas.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from typing import Iterable, Sequence

# ─────────────────────────────────────────────────────────────────────────────
# 1. Identity
# ─────────────────────────────────────────────────────────────────────────────

#: Bump when the label contract in section 2 changes. Stamped into
#: ``intents_meta.json``, into the exam lock, and (Wave C) into the model.
INTENT_SPEC_VERSION: str = "assistant-intents-v2"

#: Bump when the generation tables in sections 3-5 change. Recorded in
#: ``intents_meta.json`` so a regenerated corpus can be told apart from the
#: shipped one even when both happen to have 15 intents and 1,680 rows.
DATASET_SPEC_VERSION: str = "assistant-dataset-v2"


# ─────────────────────────────────────────────────────────────────────────────
# 2. The label contract
# ─────────────────────────────────────────────────────────────────────────────

#: The 23 intents, ALPHABETICAL. Alphabetical because scikit-learn sorts string
#: classes, so ``model.classes_`` lines up with this tuple with no remapping --
#: the same reason ``text_norm.LABELS`` is alphabetical. Every confusion-matrix
#: axis, every ``labels=`` argument and every ``predict_proba`` column uses this
#: order.
#:
#: A 24th intent is a new INTENT_SPEC_VERSION and a retrain, not an edit. This
#: tuple has been through that door once: v1 shipped 15 labels, v2 adds the
#: eight below, and the rule that made it a version bump rather than an edit is
#: the reason v1's released model is still loadable and still comparable.
#:
#: ── why these eight, and not the other things Scout can do ────────────────
#:
#: The test for "deserves a trained label" is: does it arrive as UNPROMPTED FREE
#: TEXT, in many phrasings, meaning something no existing label means? Eight
#: things passed it.
#:
#: * ``find_players`` -- "koi player chahiye", "need 2 guys tonight". A PERSON,
#:   which ``find_opponents`` (a whole opposing team) does not cover, and the
#:   confusion between the two is the interesting one.
#: * ``find_teams`` -- "kisi team me join karna hai". JOINING a squad, the mirror
#:   of ``find_opponents`` playing against one.
#: * ``navigate`` -- "kaise pohnchu", "location bhejo". ``venues.latitude`` and
#:   ``longitude`` are already populated, so this answers with a real map card
#:   and real directions rather than a paragraph.
#: * ``elo_help`` -- "rating kaise barhay". Answered from the seeded ``elo``
#:   block in ``global_settings``, so the numbers in the reply are the numbers
#:   the ranking system actually uses.
#: * ``app_help`` -- "app kaise use karu", "ye wallet kya hota hai". The
#:   where-is-it / what-is-it bucket. Deliberately NARROW: a specific procedure
#:   already has a label (``topup_help``, ``create_team_help``,
#:   ``refund_policy``) and must keep it, because this class is a semantic sponge
#:   and every phrasing it absorbs is one the specific label loses.
#: * ``contact_owner`` -- "owner se baat karani hai". The front door of the
#:   escalation loop: Scout does not know, a human is asked, the answer is
#:   remembered for the next person who asks.
#: * ``affirm`` / ``deny`` -- "haan bhai kar do" / "nahi ruko". A pending
#:   confirmation is resolved by a DETERMINISTIC lexicon before the classifier
#:   is consulted, because two classes of one-word replies is a job a rule does
#:   at ~100% and a 23-way classifier can only do worse. They are trained labels
#:   anyway, for the case the rule never sees: a bare "haan" arriving with
#:   nothing pending, which must land somewhere sane instead of firing the
#:   out-of-scope menu at a user who was agreeing with Scout.
#:
#: What is deliberately NOT here: new chat, switch chat, rename thread. Nobody
#: types "switch chat" at an assistant -- they tap the thread. Those are REST
#: endpoints and UI affordances, and putting them in the classifier would cost
#: real accuracy on all 23 labels to serve a gesture nobody makes.
INTENTS: tuple[str, ...] = (
    "affirm",
    "app_help",
    "book_venue",
    "cancel_booking",
    "check_availability",
    "contact_owner",
    "create_team_help",
    "deny",
    "elo_help",
    "find_opponents",
    "find_players",
    "find_teams",
    "find_venue",
    "greeting",
    "my_bookings",
    "navigate",
    "out_of_scope",
    "refund_policy",
    "team_stats",
    "topup_help",
    "tournament_list",
    "venue_info",
    "wallet_balance",
)

#: Language tags, alphabetical for census stability.
#:
#: ``mix`` means genuinely code-switched: an English noun phrase inside an Urdu
#: frame, or the reverse. A loanword everybody uses in both languages (football,
#: booking, parking, slot) is NOT a code switch. If it were, almost every Roman
#: Urdu sentence written in Pakistan would be tagged ``mix`` and the tag would
#: carry no information at all.
LANGS: tuple[str, ...] = ("en", "mix", "ru")

#: Which slot buckets each language may draw from. ``"*"`` is the
#: language-neutral bucket: sports, areas, cities, venue names and counts, all
#: written the same way in either language. ``mix`` draws from BOTH language
#: buckets, which is what makes a code-switched row possible at all.
LANG_BUCKETS: dict[str, tuple[str, ...]] = {
    "en": ("*", "en"),
    "mix": ("*", "en", "ru"),
    "ru": ("*", "ru"),
}

#: ``(intent, group, gloss, most-confusable-intent)``.
#:
#: ``group`` exists so Wave C can print a 6x6 grouped confusion matrix beside
#: the 15x15 one: 225 cells over ~330 validation rows is unreadable on its own,
#: and the committee question is "does it confuse booking with browsing", which
#: the grouped matrix answers directly.
#:
#: ``confusable`` is documentation for the annotator and for error analysis. It
#: is deliberately NOT consulted by anything at runtime -- no code in this
#: repository uses it to pick or rewrite a label.
INTENT_CATALOG: tuple[tuple[str, str, str, str], ...] = (
    ("find_venue", "discovery",
     "discover venues; the object is a ground or turf, filtered by sport, area, "
     "city, budget or date",
     "check_availability"),
    ("check_availability", "discovery",
     "is a SLOT free; the object is a time or an availability, usually at a "
     "named venue or on a given date",
     "find_venue"),
    ("book_venue", "booking",
     "commit to a booking. v2 narrows this, and the line is drawn where a "
     "classifier can actually see it: book_venue if the utterance carries a "
     "booking VERB (book, reserve, lock, karwa do) OR re-specifies a concrete "
     "option (a time, a date, a venue -- 'yes the 8pm one'). ``affirm`` is what "
     "is left: agreement carrying neither, where the thing agreed to exists only "
     "in the dialog state ('haan theek hai', 'ok wohi kar do'). v1 folded both "
     "readings in here; once ``affirm`` exists that leaves two labels claiming "
     "one utterance, and a rule about DIALOG CONTEXT would be one the model "
     "cannot apply because it never sees the context",
     "check_availability"),
    ("my_bookings", "booking",
     "list the user's own bookings, upcoming or past",
     "check_availability"),
    ("cancel_booking", "booking",
     "act to cancel an existing booking",
     "refund_policy"),
    ("wallet_balance", "account",
     "the balance number: wallet, escrow, held or frozen amounts",
     "topup_help"),
    ("topup_help", "account",
     "the procedure: adding money, payment methods, minimums, withdrawal",
     "wallet_balance"),
    ("team_stats", "team",
     "the user's own or their team's ELO rating, rank, or win-loss record",
     "find_opponents"),
    ("find_opponents", "team",
     "ask the platform for an opposing team or a match",
     "team_stats"),
    ("create_team_help", "team",
     "the procedure: creating a team, inviting players, captaincy, minimum squad",
     "find_opponents"),
    ("tournament_list", "info",
     "tournaments hosted ON SportLynk: listing, dates, how to register",
     "out_of_scope"),
    ("venue_info", "info",
     "facts about ONE venue: amenities, lights, parking, indoor or turf, price, "
     "timings, rating, location",
     "find_venue"),
    ("refund_policy", "info",
     "the RULES: deposit, cancellation window, refund share, no-show, escrow",
     "cancel_booking"),
    ("greeting", "social",
     "social pleasantries carrying no task: greetings, thanks, acknowledgements, "
     "sign-offs",
     "out_of_scope"),
    ("out_of_scope", "social",
     "anything SportLynk cannot act on, INCLUDING sports news, live scores and "
     "PSL fixtures",
     "tournament_list"),

    # ── v2 ─────────────────────────────────────────────────────────────────
    # Appended rather than interleaved: INTENT_GROUPS is derived from
    # first-appearance order here, so appending puts the two new groups at the
    # end of that tuple and leaves the six v1 groups on the axis positions the
    # v1 confusion matrices already used. INTENTS is what is alphabetical; this
    # tuple is what is ordered by reading sense, and self_check() asserts the two
    # hold the same names.
    ("navigate", "discovery",
     "how to GET to a venue: directions, distance, location, a map or a pin; the "
     "object is a route, not a ground to choose",
     "venue_info"),
    ("find_players", "team",
     "ask the platform for one or more PEOPLE to fill a squad or a side, usually "
     "with a count, a sport or a time",
     "find_opponents"),
    ("find_teams", "team",
     "ask to JOIN an existing team, or to be shown teams that are recruiting; the "
     "user wants to be on the squad, not to play against it",
     "find_opponents"),
    ("elo_help", "info",
     "the RULES of rating: how ELO moves, what a win or a loss is worth, how to "
     "climb, why a rating dropped",
     "team_stats"),
    ("app_help", "info",
     "how to USE SportLynk, or what one of its concepts means: where a screen is, "
     "what a wallet or escrow or trust score is, how to sign in. NOT a specific "
     "money, team or refund procedure -- those keep their own labels",
     "out_of_scope"),
    ("contact_owner", "support",
     "reach a HUMAN: the venue owner, the ground manager, support; includes asking "
     "Scout to pass a question on",
     "venue_info"),
    ("affirm", "dialog",
     "bare agreement with what Scout just proposed: yes, haan, ji, theek hai, kar "
     "do. Carries no task of its own -- it is an answer, not a request",
     "deny"),
    ("deny", "dialog",
     "bare refusal of what Scout just proposed: no, nahi, ruko, cancel that, "
     "rehne do. NOT cancel_booking, which acts on an existing booking",
     "affirm"),
)

#: Coarse groups, in first-appearance order in :data:`INTENT_CATALOG`.
INTENT_GROUPS: tuple[str, ...] = (
    "discovery", "booking", "account", "team", "info", "social",
    "support", "dialog",
)

#: The closed tag vocabulary for the ``phenomena`` column, alphabetical.
#:
#: A tag says what a row is testing, so error analysis can ask "how do we do on
#: typos" or "how do we do on boundary cases" instead of eyeballing 150 rows.
#: ``;``-separated in the CSV. Every row carries at least one tag; ``plain`` is
#: the tag for "nothing special about this row".
PHENOMENA: tuple[str, ...] = (
    "boundary",          # deliberately close to another intent's decision boundary
    "code_switch",       # a genuine EN/UR switch inside one clause
    "ellipsis",          # fragment; verb or subject dropped
    "emoji",
    "imperative",
    "indirect",          # the request is implied rather than stated
    "misspelled_venue",  # a catalogue venue name typed wrong
    "multi_slot",        # three or more entities in one utterance
    "negation",
    "numeric",           # a price, a count or a clock time in digits
    "plain",
    "politeness",
    "question",
    "run_on",            # two questions welded into one line
    "short",             # three tokens or fewer
    "slang",
    "sms_speak",         # plz, thnx, k, bookng
    "typo",
)

#: Row provenance. ``template`` rows come out of the cross product; ``authored``
#: rows are hand-written and are copied into the corpus verbatim.
SOURCES: tuple[str, ...] = ("authored", "template")

#: Split names.
SPLITS: tuple[str, ...] = ("train", "val")


# ─────────────────────────────────────────────────────────────────────────────
# 3. Slot vocabulary
# ─────────────────────────────────────────────────────────────────────────────
#
# ``SLOT_VOCAB[slot][bucket]`` -> the values a template written in a language
# that may draw from ``bucket`` is allowed to receive. Buckets are ``"*"``
# (language-neutral), ``"en"`` and ``"ru"``; :data:`LANG_BUCKETS` says which a
# language sees, and :func:`slot_values` resolves the union in a fixed order.
#
# Two rules that are load-bearing rather than stylistic:
#
# * A value goes in ``"*"`` only if it is written identically in both languages.
#   "tomorrow" is not; "F-11 Markaz" is.
# * ``{polite}`` and ``{opener}`` contain the EMPTY STRING as their first value.
#   That is what lets a slot-free utterance expand at all: "salam {polite}"
#   yields "salam", "salam bhai", "salam yaar", and :func:`tidy` removes the
#   whitespace the empty draw leaves behind. Without the empty value, every
#   greeting row would be forced to carry a vocative, which is not how people
#   type.
#
# Values are drawn from the real catalogue (``backend/src/scripts/seed_venues.js``
# -- 5 football and 5 cricket venues across Islamabad and Rawalpindi) and from
# ``reco_features.ZONE_SCHEMES``, so an extracted entity in Wave B has something
# real to resolve against. Sector spellings intentionally vary in case
# ("F-11" and "f-11"): both are typed, and the extractor must survive both.

SLOT_VOCAB: dict[str, dict[str, tuple[str, ...]]] = {
    # Sports the platform knows. football and cricket are the only two the app
    # offers (find_venues_screen.dart), futsal exists as a venue name, and
    # badminton/tennis are here so the extractor recognises them and the action
    # layer can answer honestly ("no badminton venues yet") instead of
    # mis-parsing the request.
    "sport": {"*": ("football", "cricket", "futsal", "badminton", "tennis")},
    "venue_word": {
        "*": ("ground", "turf", "venue"),
        "en": ("pitch", "field", "arena"),
        "ru": ("maidan",),
    },
    "area": {
        "*": (
            "F-11 Markaz", "F-11", "G-6", "F-8", "F-7 Markaz", "F-9 Park",
            "G-8/2", "G-9", "G-11", "I-8", "DHA Phase 2", "Bahria Town",
            "Bahria Town Phase 7", "Gulberg Greens", "Blue Area",
            "Satellite Town", "Saddar", "Chaklala", "Stadium Road",
        ),
        "en": ("Gulberg",),
        "ru": ("f-11", "g-6", "bahria town"),
    },
    "city": {
        "*": ("Islamabad", "Rawalpindi", "Pindi", "isb", "rwp"),
        "ru": ("islamabad", "pindi"),
    },
    # The 10 seeded venues, verbatim. A template that names a venue must name a
    # real one, or Wave B's action layer has nothing to look up and the demo
    # fails on a row that looked fine in the CSV.
    "venue": {
        "*": (
            "F-11 Markaz Football Arena", "Jinnah Sports Complex",
            "Centaurus Kickoff", "Bahria Town Futsal", "DHA Phase 2 Arena",
            "Diamond Cricket Ground", "Shalimar Cricket Academy",
            "Rawalpindi Cricket Nets", "Bahria Cricket Arena",
            "Margalla Cricket Club",
        ),
    },
    # Dates carry no time-of-day and times carry no date: a template that wants
    # both writes both slots, so "{date} {time}" can produce "kal shaam" while
    # "{date}" alone never silently smuggles a time in.
    "date": {
        "en": (
            "today", "tomorrow", "tonight", "this weekend", "Friday",
            "Saturday", "Sunday", "next week", "30 August",
        ),
        "ru": (
            "aaj", "kal", "parso", "is weekend", "jummah ko", "agle hafte",
            "is mahine", "itwar ko",
        ),
    },
    "time": {
        "en": (
            "8pm", "9pm", "7:30pm", "6am", "5pm", "10pm", "evening", "morning",
            "afternoon",
        ),
        "ru": (
            "shaam", "subah", "dopahar", "raat", "8 baje", "9 baje",
            "saade aath", "shaam 6 baje", "raat 10 baje",
        ),
    },
    # Budget phrasings, not bare numbers: "under 2000" and "2000 se kam" are
    # what the extractor has to parse, and a bare "2000" is ambiguous with a
    # time ("2000 hours") and with a count.
    "budget": {
        "en": (
            "under 2000", "below 3000", "around 2500", "max 3500",
            "under 4000", "cheap",
        ),
        "ru": (
            "2000 se kam", "2500 tak", "3000 se kam", "budget mein", "sasta",
            "zyada mehnga na ho",
        ),
    },
    # Canonical amenity words as a user types them. The canonical keys live in
    # ``reco_features.AMENITY_ALIASES``; these are the surface forms.
    "amenity": {
        "*": (
            "lights", "floodlights", "parking", "washroom", "cafe", "nets",
            "pavilion", "AC", "changing room", "water", "seating", "lockers",
        ),
    },
    "team": {
        "en": ("my team", "our team", "our squad"),
        "ru": ("hamari team", "meri team", "apni team"),
    },
    "duration": {
        "en": ("1 hour", "2 hours", "90 minutes"),
        "ru": ("ek ghanta", "do ghante", "dedh ghanta"),
    },
    "count": {"*": ("2", "3", "4", "5", "10", "11")},
    # ── decorators: the empty string is the first value, on purpose ──────────
    "polite": {
        "en": ("", "please", "plz", "thanks"),
        "ru": ("", "bhai", "yaar", "plz", "boss"),
    },
    "opener": {
        "en": ("", "hey", "hi", "listen"),
        "ru": ("", "bhai", "yaar", "sun", "acha"),
    },
}

#: Slots whose vocabulary contains the empty string. They exist to expand
#: slot-poor intents (greeting, out_of_scope, my_bookings, wallet_balance) and
#: they carry no entity, so the extractor ignores them and
#: :func:`validate_pattern` allows them where a real slot would be rejected.
DECORATOR_SLOTS: tuple[str, ...] = ("opener", "polite")

#: Every slot name, alphabetical.
SLOTS: tuple[str, ...] = tuple(sorted(SLOT_VOCAB))

#: The slots that carry a real entity. ``out_of_scope`` templates may not use
#: any of these: an out-of-scope utterance that contains a sport, a venue or an
#: area teaches the classifier that those words predict out_of_scope, which is
#: the opposite of what every other intent needs.
DOMAIN_SLOTS: tuple[str, ...] = tuple(
    slot for slot in SLOTS if slot not in DECORATOR_SLOTS
)


# ─────────────────────────────────────────────────────────────────────────────
# 4. Quotas and gate thresholds
# ─────────────────────────────────────────────────────────────────────────────
#
# These are the numbers ``gen_intents.py`` gates on. They live here rather than
# as argparse defaults for one reason: a gate whose threshold can be relaxed
# with a command-line flag is not a gate. ``--per-intent`` is tunable because it
# is a target; nothing below it is.

#: Default rows per intent, counting authored rows. 15 x 112 = 1,680, inside
#: [TOTAL_MIN, TOTAL_MAX] and close to the ~1,800 the sprint plan asked for.
#: Deliberately EQUAL across intents: a classifier trained on an unbalanced
#: intent set answers with the prior when it is unsure, and "unsure" is exactly
#: when a booking assistant must not guess.
ROWS_PER_INTENT_TARGET: int = 112

#: Hard per-intent bounds. The sprint plan says 100-130 utterances per intent.
ROWS_PER_INTENT_MIN: int = 100
ROWS_PER_INTENT_MAX: int = 130

#: Hard corpus bounds -- DERIVED from the per-intent bounds, not a second opinion
#: about corpus size. Writing 1600/2000 by hand here is how the two gates end up
#: contradicting each other: fifteen intents each sitting legally on 100 rows
#: total 1500, which a hand-written floor of 1600 would then reject with no way
#: for the author to satisfy both. The spec's "~1,800 rows" sits inside this range.
TOTAL_ROWS_MIN: int = len(INTENTS) * ROWS_PER_INTENT_MIN
TOTAL_ROWS_MAX: int = len(INTENTS) * ROWS_PER_INTENT_MAX

#: Target share of each intent's TEMPLATE rows by language. English leads
#: because it is the shortest path to a working demo; Roman Urdu is close behind
#: because it is what the committee will type; ``mix`` is smallest because a
#: code-switched row is also partly evidence for both other languages.
LANG_BUDGET: dict[str, float] = {"en": 0.40, "ru": 0.35, "mix": 0.25}

#: Hard per-intent, per-language floors over ALL rows (template + authored). The
#: budget above is a target and rounding plus capacity limits can move it; these
#: cannot be missed. Without them one intent could end up English-only and the
#: macro-F1 would hide it behind the other fourteen.
MIN_LANG_ROWS_PER_INTENT: dict[str, int] = {"en": 25, "ru": 25, "mix": 10}

#: Hand-written naturalisation rows. The sprint plan asks for ~200 hand-edited
#: utterances; these floors are what "hand-edited" is held to.
AUTHORED_MIN_TOTAL: int = 200
AUTHORED_MIN_PER_INTENT: int = 8

#: The held-out exam: 150 rows, exactly 10 per intent, with a fixed language
#: split. Equal per intent so per-class recall is measured on the same sample
#: size everywhere -- a 10-row class gives a coarse recall (0.0, 0.1, ... 1.0)
#: and that coarseness is stated in the model card rather than hidden.
EXAM_ROWS_PER_INTENT: int = 10
EXAM_ROWS_TOTAL: int = EXAM_ROWS_PER_INTENT * len(INTENTS)
EXAM_LANG_QUOTA: dict[str, int] = {"ru": 4, "mix": 3, "en": 3}

#: Grouped 80/20 split. GROUPED, not random: the group is the ``template_id``, so
#: no template family can appear on both sides. A plain random split over
#: template-expanded rows puts "show football grounds in F-11" in train and
#: "show cricket grounds in G-6" in val, and the resulting ~0.99 accuracy
#: measures slot-value memorisation. Holding out whole templates measures what
#: we actually want to know: does it generalise to a phrasing it has never seen.
#:
#: The cost, stated plainly: with ~18 templates per intent, 20% is 3-4 held-out
#: phrasings, so the validation score has real variance and is not a headline
#: number. The hand-written exam is the headline instrument. Same reasoning as
#: the S.3 time-split: the honest measurement is the one that can go down.
VAL_FRACTION: float = 0.20
VAL_FRACTION_MIN: float = 0.15
VAL_FRACTION_MAX: float = 0.25

#: Contamination gate. A corpus row this close to an exam row is dropped FROM THE
#: CORPUS -- never from the exam. Same threshold and same two-metric rule as the
#: S.4 sentiment build: character shingles miss word reordering, word sets miss
#: spelling drift, so the gate takes the max of both.
NEAR_DUP_CONTAM: float = 0.80

#: Internal-cleanliness thresholds for the exam itself: warn at 0.85, fail at
#: 0.97. Two exam rows that similar are one measurement counted twice.
NEAR_DUP_WARN: float = 0.85
NEAR_DUP_FATAL: float = 0.97

#: Character shingle width for the near-duplicate metric.
SHINGLE_N: int = 4

#: The most rows one template may contribute to the corpus. A template with
#: three slots can produce thousands of combinations, so without a cap the
#: allocator would happily fill an entire intent from its two most productive
#: phrasings -- and a grouped train/val split would then hold out 20% of the ROWS
#: by holding out one template that happens to own most of them.
#:
#: 12 is chosen against the quota: 112 rows per intent over >= 12 templates means
#: no phrasing can own more than about a ninth of its class. It is also the gate
#: that makes a slot-poor intent honest. `greeting` cannot reach 100 rows by
#: multiplying "{opener} good morning {polite}" out to 20 near-identical rows; it
#: has to be given twenty actual greetings, which is the work the sprint plan
#: means by "hand-edit for naturalness".
MAX_ROWS_PER_TEMPLATE: int = 12

#: Fewest templates an intent must have for one language. Four, because the
#: train/val split is GROUPED on template_id: at three, holding out one template
#: leaves two phrasings in train, and a class that has seen two phrasings of a
#: language is not being taught that language. It also bounds the other end -- the
#: minimum four templates times the per-template cap must still cover the largest
#: per-language quota, which is asserted in self_check() rather than hoped for.
MIN_TEMPLATES_PER_LANG: int = 4

#: Required headroom between what an intent's templates CAN produce for a
#: language and what the quota ASKS for. Exactly 1.0 would be satisfiable only by
#: exhausting every template to its last combination, which is how a corpus ends
#: up with every value of every slot appearing exactly once -- the allocator needs
#: slack to spread rows across phrasings instead.
TEMPLATE_CAPACITY_MARGIN: float = 1.30

#: Length bounds for one utterance, applied to authored and exam rows.
#: The floor rejects "ok" as a row of its own; the ceiling rejects the paragraph
#: an author writes when they are describing a scenario rather than typing a
#: message to an assistant. Both are about what a person types into a chat box,
#: not about what the model can process.
MIN_TEXT_CHARS: int = 3
MAX_TEXT_CHARS: int = 160

#: Above this Cramer's V between language and intent, the generator WARNS: it
#: would mean a model could score by detecting language instead of intent. It
#: warns rather than fails because the per-intent language floors above already
#: bound the effect structurally, and a threshold that fails on a diagnostic
#: nobody can act on just gets raised until it stops firing.
CRAMERS_V_WARN: float = 0.50


# ─────────────────────────────────────────────────────────────────────────────
# 5. Compiled patterns and helpers
# ─────────────────────────────────────────────────────────────────────────────

#: A slot reference in a template. Deliberately narrow -- lowercase ASCII and
#: underscores only -- so a typo like ``{Sport}`` or ``{ sport }`` is reported as
#: an unknown slot instead of being silently left in the emitted text.
_RE_SLOT = re.compile(r"\{([a-z_]+)\}")

#: Any brace at all, used to prove no malformed reference survives.
_RE_BRACE = re.compile(r"[{}]")

#: Anything brace-delimited, valid slot name or not. The strict ``_RE_SLOT``
#: silently ignores ``{Sport}`` and ``{ sport }``, which would then ship as
#: literal text inside a training row; this one exists purely so
#: :func:`validate_pattern` can say what is wrong with them.
_RE_SLOT_LOOSE = re.compile(r"\{[^{}]*\}")

_RE_WS = re.compile(r"\s+")
#: Space before punctuation, left behind by an empty decorator draw.
_RE_SPACE_PUNCT = re.compile(r"\s+([?!,.;:])")
#: A punctuation mark repeated with only whitespace between, same cause.
_RE_PUNCT_RUN = re.compile(r"([?!,;:])(?:\s+\1)+")
#: Leading and trailing junk: a comma or semicolon that lost its left operand.
_RE_LEAD_JUNK = re.compile(r"^[\s,;:.]+")
_RE_TRAIL_JUNK = re.compile(r"[\s,;:]+$")
#: Everything that is not a letter, a digit or whitespace, for :func:`dedup_key`.
#: ``\w`` is Unicode-aware; the corpus is ASCII by contract but a stray pasted
#: character must not change a row's identity.
_RE_NON_TOKEN = re.compile(r"[^\w\s]")
#: Whitespace before sentence punctuation, for hand-written rows. ":" is
#: deliberately absent from the class -- " :)" is an emoticon, and treating it as
#: sloppy spacing would rewrite it into "aayenge:)", which nobody types.
_RE_TEXT_SPACE_PUNCT = re.compile(r"\s[?!,.;]")



def slot_values(slot: str, lang: str) -> tuple[str, ...]:
    """The values ``slot`` may take in a template written in ``lang``.

    Buckets are concatenated in :data:`LANG_BUCKETS` order and then deduplicated
    on first appearance, so a value present in both ``"*"`` and ``"ru"``
    contributes exactly one choice. Order is stable and part of the generator's
    index arithmetic: the same seed must decode to the same value forever.
    """
    if slot not in SLOT_VOCAB:
        raise KeyError(f"unknown slot {slot!r}; known: {', '.join(SLOTS)}")
    if lang not in LANG_BUCKETS:
        raise KeyError(f"unknown lang {lang!r}; known: {', '.join(LANGS)}")
    seen: dict[str, None] = {}
    for bucket in LANG_BUCKETS[lang]:
        for value in SLOT_VOCAB[slot].get(bucket, ()):
            seen.setdefault(value, None)
    return tuple(seen)


def pattern_slots(pattern: str) -> tuple[str, ...]:
    """Slot names referenced by ``pattern``, in first-appearance order, unique.

    Unique because the generator substitutes a slot's chosen value at every
    occurrence: ``{sport} ke liye {sport} ground`` has one degree of freedom, not
    two, and counting it twice would overstate capacity.
    """
    seen: dict[str, None] = {}
    for name in _RE_SLOT.findall(pattern):
        seen.setdefault(name, None)
    return tuple(seen)


def pattern_capacity(pattern: str, lang: str) -> int:
    """How many distinct rows ``pattern`` can produce in ``lang``.

    The product of its distinct slots' vocabulary sizes; 1 for a slot-free
    pattern. This is the number the generator allocates against, and the number
    that decides whether a slot-poor intent can reach
    :data:`ROWS_PER_INTENT_MIN` at all -- which is why ``greeting`` and
    ``out_of_scope`` carry a decorator slot on almost every pattern.
    """
    total = 1
    for slot in pattern_slots(pattern):
        total *= max(1, len(slot_values(slot, lang)))
    return total


def capacity_budget(patterns: Iterable[str], lang: str) -> int:
    """How many rows a set of templates can actually contribute for one language.

    Not the sum of the capacities: the sum of ``min(capacity,
    MAX_ROWS_PER_TEMPLATE)``, because the per-template cap is what the allocator
    is bound by. The distinction is the whole point -- one three-slot template
    with a capacity of 27,000 and eleven slot-free ones look like a comfortable
    27,011 by raw capacity, and can in fact deliver only 23 rows.

    This is the number the generator's feasibility gate compares against the
    quota, so an intent that cannot reach its row target fails BEFORE any rows are
    written rather than silently shipping 61 rows in a class that claims 112.
    """
    return sum(
        min(pattern_capacity(pattern, lang), MAX_ROWS_PER_TEMPLATE)
        for pattern in patterns
    )


def render(pattern: str, choices: dict[str, str]) -> str:
    """Substitute ``choices`` into ``pattern`` and tidy the result.

    Plain string replacement rather than ``str.format``: a template is written by
    hand and will eventually contain a brace-free apostrophe, a percent sign or a
    stray brace, and ``format`` turns each of those into a runtime error halfway
    through a 1,680-row generation.
    """
    text = pattern
    for slot, value in choices.items():
        text = text.replace("{" + slot + "}", value)
    return tidy(text)


def tidy(text: str) -> str:
    """Repair the punctuation and whitespace an empty decorator draw leaves.

    ``"salam {polite}"`` with ``polite=""`` renders as ``"salam "``, and
    ``"{opener} kal ka slot?"`` renders as ``" kal ka slot?"``. Neither is
    something a person would type, and both would become their own vocabulary
    item in a character n-gram model.

    The steps, in order -- order matters, each one can create the input to the
    next::

        collapse whitespace        "salam  bhai"   -> "salam bhai"
        SPACED repeated punctuation  "hai ? ?"    -> "hai ?"
        space before punctuation   "slot khali ?"  -> "slot khali?"
        strip leading junk         ", kal ka slot" -> "kal ka slot"
        strip trailing junk        "salam bhai ,"  -> "salam bhai"
        collapse whitespace again

    Idempotent by construction and pinned as such in :func:`self_check`. It
    deliberately does NOT normalise case, fix spelling, or remove a doubled "??"
    that an author typed on purpose: this repairs generation artifacts, it is not
    a normaliser.

    That last promise is why the repeated-punctuation step requires WHITESPACE
    between the two marks, and why it runs BEFORE the space-before-punctuation
    step. Duplicated marks arrive here for two unrelated reasons: an empty
    decorator draw leaves them SPACED ("hai ? ?"), while an emphatic author types
    them ADJACENT ("kahan gaye??"). Collapsing every run would delete the second,
    which is real Roman Urdu typing and exactly the kind of surface detail the
    classifier should be able to see. The order matters because the space-before-punctuation step would
    otherwise rewrite "hai ? ?" to "hai??" first, making the generated artifact
    indistinguishable from the deliberate one.
    """
    text = _RE_WS.sub(" ", text)
    text = _RE_PUNCT_RUN.sub(r"\1", text)
    text = _RE_SPACE_PUNCT.sub(r"\1", text)
    text = _RE_LEAD_JUNK.sub("", text)
    text = _RE_TRAIL_JUNK.sub("", text)
    return _RE_WS.sub(" ", text).strip()


#: Unicode general categories a non-ASCII character may belong to in a
#: hand-written row: symbols. That admits emoji and emoticon symbols, and admits
#: nothing else -- in particular no Urdu script (Lo) and no curly quotation marks
#: (Pi/Pf), which arrive by paste rather than by typing.
_ALLOWED_NON_ASCII_CATEGORIES: tuple[str, ...] = ("So", "Sk")

#: Zero-width joiner and variation selector 16. Both are formatting characters
#: (Cf, Mn) that emoji sequences are built from, so they have to be allowed for
#: the emoji above to survive a round trip through the CSV.
_ALLOWED_NON_ASCII_CHARS: tuple[str, ...] = ("\u200d", "\ufe0f")


def text_problems(text: object) -> list[str]:
    """Every problem with one HAND-WRITTEN row, or an empty list.

    The counterpart to :func:`tidy`, and the split between them is load-bearing.
    ``tidy`` REPAIRS a generated row, because the artifacts in a generated row
    come from the generator and there is nothing to consult about them. This
    function only REPORTS, and it is deliberately weaker: an authored row is
    evidence about how a person types, so "kahan gaye??" and "log aayenge :)"
    must both survive it. Running authored rows through ``tidy`` instead would
    quietly rewrite them into the generator's house style and delete the very
    naturalness they were written for.

    What it rejects is therefore only what is unambiguously a mistake:

    * empty, untrimmed, double-spaced, or containing a control character -- all
      four are copy-paste damage, and all four change the dedup key;
    * whitespace before ``? ! , . ;`` -- "loss ??" is a slip, "loss??" is a
      choice, and only the slip is caught (see :data:`_RE_TEXT_SPACE_PUNCT`);
    * a brace -- a hand-written row containing "{sport}" is an author who pasted
      a template into the authored file, which would otherwise ship a literal
      "{sport}" as training text;
    * shorter than :data:`MIN_TEXT_CHARS` or longer than :data:`MAX_TEXT_CHARS`;
    * a non-ASCII character that is not an emoji (see
      :data:`_ALLOWED_NON_ASCII_CATEGORIES`).
    """
    if text is None:
        return ["empty text"]
    value = text if isinstance(text, str) else str(text)
    problems: list[str] = []
    if not value.strip():
        return ["empty text"]
    if value != value.strip():
        problems.append("leading or trailing whitespace")
    if "  " in value:
        problems.append("double space")
    if _RE_TEXT_SPACE_PUNCT.search(value):
        problems.append(
            "whitespace before sentence punctuation; write 'loss??' rather than "
            "'loss ??' (a doubled mark is kept, the space is not)"
        )
    if "{" in value or "}" in value:
        problems.append("contains a brace; this is an utterance, not a template")
    if not MIN_TEXT_CHARS <= len(value) <= MAX_TEXT_CHARS:
        problems.append(
            f"length {len(value)} outside [{MIN_TEXT_CHARS}, {MAX_TEXT_CHARS}]"
        )
    for char in value:
        if ord(char) < 128 and unicodedata.category(char) != "Cc":
            continue
        if char in _ALLOWED_NON_ASCII_CHARS:
            continue
        category = unicodedata.category(char)
        if ord(char) >= 128 and category in _ALLOWED_NON_ASCII_CATEGORIES:
            continue
        if category == "Cc":
            problems.append(f"control character U+{ord(char):04X}")
            continue
        name = unicodedata.name(char, "unnamed")
        problems.append(
            f"disallowed character U+{ord(char):04X} ({name}, category "
            f"{category}); the corpus is Roman Urdu and English plus emoji"
        )
    return problems


def dedup_key(text: object) -> str:
    """Identity of an utterance for duplicate detection.

    NFKC, casefold, punctuation to space, whitespace collapsed. That is all --
    see the module docstring for why this must not reuse ``text_norm``: folding
    spelling variants would delete the spelling diversity the corpus exists to
    teach.

    Punctuation becomes a SPACE rather than nothing, so "f-11" and "F 11" agree
    while "f-11" and "f11" stay distinct. Both readings are defensible; this one
    is chosen because a hyphen in a sector name is a word boundary, not a typo.
    """
    if text is None:
        return ""
    value = text if isinstance(text, str) else str(text)
    value = unicodedata.normalize("NFKC", value).casefold()
    value = _RE_NON_TOKEN.sub(" ", value)
    return _RE_WS.sub(" ", value).strip()


def words(text: object) -> frozenset[str]:
    """Word set of an utterance, for the word-set half of the near-duplicate
    metric. A SET, so reordering does not hide a duplicate."""
    return frozenset(dedup_key(text).split())


def shingles(text: object, size: int = SHINGLE_N) -> frozenset[str]:
    """Character shingles of an utterance, for the other half of the metric.

    Spaces are kept: "cricket ground" and "cricketground" are different rows and
    a shingle set that ignored the boundary would say otherwise.
    """
    key = dedup_key(text)
    if len(key) < size:
        return frozenset({key}) if key else frozenset()
    return frozenset(key[index:index + size] for index in range(len(key) - size + 1))


def jaccard(left: frozenset[str], right: frozenset[str]) -> float:
    """|A n B| / |A u B|; 0.0 when both are empty."""
    if not left or not right:
        return 0.0
    union = len(left | right)
    return len(left & right) / union if union else 0.0


def near_dup_score(left: object, right: object) -> tuple[float, str]:
    """``(score, which_metric)`` for two utterances.

    The MAX of the character-shingle and word-set Jaccards, and the name of
    whichever produced it. Both are needed and neither is sufficient: shingles
    miss word reordering ("kal shaam ka slot" vs "slot kal shaam ka"), word sets
    miss spelling drift ("nahi" vs "nhi"). Reporting which metric fired is what
    makes a dropped row auditable afterwards.
    """
    char_score = jaccard(shingles(left), shingles(right))
    word_score = jaccard(words(left), words(right))
    if word_score > char_score:
        return word_score, "word_set"
    return char_score, "char_shingle"


def stable_seed(*parts: object) -> int:
    """A 63-bit RNG seed derived from ``parts`` by sha256.

    THE ONLY sanctioned way to derive a per-key seed in this dataset. Python's
    ``hash()`` is randomised per process unless ``PYTHONHASHSEED`` is pinned, so
    ``Random(hash(template_id))`` produces a different CSV on every run while the
    code reads as deterministic. That failure is invisible in review and only
    shows up as a sha256 mismatch in a gate weeks later.

    Deriving per-template seeds from ``(global_seed, template_id)`` also makes
    each template's draw sequence independent of every other, so adding one
    template does not reshuffle the rows of all the others -- the diff between
    two corpus versions stays readable.
    """
    payload = "\x1f".join(str(part) for part in parts).encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big") >> 1


def decode_index(index: int, cardinalities: Sequence[int]) -> tuple[int, ...]:
    """Mixed-radix decode of ``index`` into one choice per slot.

    The generator draws distinct integers from ``range(capacity)`` and decodes
    each one here, which is what makes a template's rows duplicate-free by
    construction rather than by a retry loop: distinct index, distinct tuple.
    Little-endian on purpose -- the first slot varies fastest, so consecutive
    indices differ in the leftmost slot and a hand-inspected sample looks varied
    rather than looking like the same sentence with one word changed at the end.
    """
    out: list[int] = []
    remaining = index
    for size in cardinalities:
        if size <= 0:
            raise ValueError("cardinality must be positive")
        out.append(remaining % size)
        remaining //= size
    if remaining:
        raise ValueError(f"index {index} out of range for {tuple(cardinalities)}")
    return tuple(out)


def validate_pattern(pattern: str, lang: str, intent: str | None = None) -> list[str]:
    """Every structural problem with one template pattern, or an empty list.

    Returns problems instead of raising: the generator reports all of them at
    once and refuses to write the corpus, which is far more useful than fixing
    eighteen patterns one exception at a time.

    What is checked, and why each one has bitten a dataset before:

    * malformed or unknown slot -- ``{Sport}`` and ``{ sport }`` would otherwise
      survive substitution and ship as literal text inside a training row;
    * a slot with no values in this language -- an ``ru`` template referencing an
      English-only bucket would silently produce nothing;
    * tidy normal form -- a pattern that already contains a double space or a
      space before its question mark hides whether the artifact came from the
      author or from an empty decorator draw;
    * decorator position -- ``{polite}`` mid-sentence reads wrong for every
      non-empty draw, and immediately before punctuation it reads wrong for the
      empty one;
    * non-ASCII -- the corpus is Roman Urdu and English by contract, and a pasted
      Urdu character or curly quote would be one unlearnable feature;
    * a domain slot in an ``out_of_scope`` pattern -- see :data:`DOMAIN_SLOTS`.
    """
    problems: list[str] = []
    if lang not in LANG_BUCKETS:
        return [f"unknown lang {lang!r}"]
    if not pattern.strip():
        return ["empty pattern"]

    for loose in _RE_SLOT_LOOSE.findall(pattern):
        if not _RE_SLOT.fullmatch(loose):
            problems.append(
                f"malformed slot reference {loose}; slot names are lowercase "
                f"snake_case with no spaces, and anything else survives "
                f"substitution to ship as literal text in a training row"
            )
    braceless = _RE_SLOT_LOOSE.sub("", pattern)
    if _RE_BRACE.sub("", braceless) != braceless:
        problems.append("malformed slot reference (unbalanced { or })")
    for name in _RE_SLOT.findall(pattern):
        if name not in SLOT_VOCAB:
            problems.append(f"unknown slot {{{name}}}")
        elif not slot_values(name, lang):
            problems.append(f"slot {{{name}}} has no values for lang {lang!r}")
    for match in _RE_SLOT.finditer(pattern):
        after = pattern[match.end():match.end() + 1]
        before = pattern[max(0, match.start() - 1):match.start()]
        if after.isalnum():
            problems.append(
                f"{match.group(0)} is glued to {after!r}; a suffix on a slot is "
                f"only correct for some of its values -- {{venue_word}}s renders "
                f"'pitchs'. Write the plural into the vocabulary instead"
            )
        if before.isalnum():
            problems.append(f"{match.group(0)} is glued to a preceding {before!r}")
    if tidy(pattern) != pattern:
        problems.append(f"not in tidy normal form; tidy() -> {tidy(pattern)!r}")
    if not all(ord(char) < 128 for char in pattern):
        problems.append("non-ASCII character")

    tokens = pattern.split()
    for position, token in enumerate(tokens):
        for decorator in DECORATOR_SLOTS:
            marker = "{" + decorator + "}"
            if token == marker and 0 < position < len(tokens) - 1:
                problems.append(
                    f"{marker} is token {position + 1} of {len(tokens)}; "
                    f"decorators must be first or last"
                )
            elif token.startswith(marker) and len(token) > len(marker):
                problems.append(f"{marker} is glued to {token[len(marker):]!r}")
    if intent == "out_of_scope":
        for name in pattern_slots(pattern):
            if name in DOMAIN_SLOTS:
                problems.append(
                    f"out_of_scope pattern uses domain slot {{{name}}}; an "
                    f"out-of-scope row must not teach that a sport or a venue "
                    f"predicts out_of_scope"
                )
    if not problems:
        # Only meaningful once the slots are known to exist: "{opener} {polite}"
        # validates on every other rule and still renders nothing at all.
        empty = {slot: ("" if slot in DECORATOR_SLOTS else slot_values(slot, lang)[0])
                 for slot in pattern_slots(pattern)}
        if not render(pattern, empty):
            problems.append("renders empty when every decorator draws ''")
    return problems


# ─────────────────────────────────────────────────────────────────────────────
# 6. Contract identity helpers
# ─────────────────────────────────────────────────────────────────────────────


def intent_spec_fingerprint() -> str:
    """sha256 (16 hex chars) over the LABEL CONTRACT only.

    Intent names and their order, the language tags, the phenomena vocabulary,
    the sources and the splits. A model trained against one of these is wrong if
    any of them changes, which is exactly what a load-time gate should catch.
    Slot vocabularies are NOT hashed here -- see the module docstring.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", INTENT_SPEC_VERSION)
    feed("intents", "|".join(INTENTS))
    feed("langs", "|".join(LANGS))
    for lang in LANGS:
        feed(f"buckets:{lang}", "|".join(LANG_BUCKETS[lang]))
    for name, group, gloss, confusable in INTENT_CATALOG:
        feed("catalog", f"{name}|{group}|{confusable}|{gloss}")
    feed("groups", "|".join(INTENT_GROUPS))
    feed("phenomena", "|".join(PHENOMENA))
    feed("sources", "|".join(SOURCES))
    feed("splits", "|".join(SPLITS))
    return digest.hexdigest()[:16]


def dataset_spec_fingerprint() -> str:
    """sha256 (16 hex chars) over the GENERATION TABLES only.

    Slot vocabularies, decorator set, quotas, gate thresholds and the tidy /
    dedup regexes. Two corpora with the same row count and the same 15 intents
    but different vocabularies get different values here, which is what makes
    ``intents_meta.json`` able to say *which* dataset it describes.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", DATASET_SPEC_VERSION)
    for slot in SLOTS:
        for bucket in ("*", "en", "ru"):
            values = SLOT_VOCAB[slot].get(bucket)
            if values is not None:
                feed(f"slot:{slot}:{bucket}", "|".join(values))
    feed("decorators", "|".join(DECORATOR_SLOTS))
    feed("rows_per_intent", f"{ROWS_PER_INTENT_TARGET}/"
                            f"{ROWS_PER_INTENT_MIN}-{ROWS_PER_INTENT_MAX}")
    feed("total_rows", f"{TOTAL_ROWS_MIN}-{TOTAL_ROWS_MAX}")
    feed("max_rows_per_template", MAX_ROWS_PER_TEMPLATE)
    feed("min_templates_per_lang", MIN_TEMPLATES_PER_LANG)
    feed("capacity_margin", f"{TEMPLATE_CAPACITY_MARGIN:.2f}")
    feed("text_chars", f"{MIN_TEXT_CHARS}-{MAX_TEXT_CHARS}")
    feed("allowed_non_ascii", ",".join(_ALLOWED_NON_ASCII_CATEGORIES))
    feed("lang_budget", "|".join(f"{k}:{LANG_BUDGET[k]:.4f}" for k in LANGS))
    feed("lang_floor", "|".join(
        f"{k}:{MIN_LANG_ROWS_PER_INTENT[k]}" for k in LANGS))
    feed("authored", f"{AUTHORED_MIN_TOTAL}/{AUTHORED_MIN_PER_INTENT}")
    feed("exam", f"{EXAM_ROWS_PER_INTENT}x{len(INTENTS)}="
                 f"{EXAM_ROWS_TOTAL}|" + "|".join(
                     f"{k}:{EXAM_LANG_QUOTA[k]}" for k in LANGS))
    feed("val", f"{VAL_FRACTION:.4f} in "
                f"[{VAL_FRACTION_MIN:.4f},{VAL_FRACTION_MAX:.4f}]")
    feed("near_dup", f"{NEAR_DUP_CONTAM:.4f}/{NEAR_DUP_WARN:.4f}/"
                     f"{NEAR_DUP_FATAL:.4f}/n={SHINGLE_N}")
    feed("cramers_v_warn", f"{CRAMERS_V_WARN:.4f}")
    for name, compiled in (
        ("slot", _RE_SLOT), ("ws", _RE_WS), ("space_punct", _RE_SPACE_PUNCT),
        ("punct_run", _RE_PUNCT_RUN), ("lead_junk", _RE_LEAD_JUNK),
        ("trail_junk", _RE_TRAIL_JUNK), ("non_token", _RE_NON_TOKEN),
        ("text_space_punct", _RE_TEXT_SPACE_PUNCT), ("slot_loose", _RE_SLOT_LOOSE),
    ):
        feed(f"re:{name}", compiled.pattern)
    return digest.hexdigest()[:16]


def intent_group(intent: str) -> str:
    """The coarse group an intent belongs to. Raises on an unknown intent so a
    typo in a report script fails loudly instead of inventing a group."""
    for name, group, _gloss, _confusable in INTENT_CATALOG:
        if name == intent:
            return group
    raise KeyError(f"unknown intent {intent!r}")


def spec() -> dict[str, object]:
    """camelCase contract summary for ``intents_meta.json``, the exam lock and
    (Wave B) ``/health``. Mirrors ``features.spec()`` and ``text_norm.spec()``."""
    return {
        "intentSpecVersion": INTENT_SPEC_VERSION,
        "intentSpecFingerprint": intent_spec_fingerprint(),
        "datasetSpecVersion": DATASET_SPEC_VERSION,
        "datasetSpecFingerprint": dataset_spec_fingerprint(),
        "intents": list(INTENTS),
        "intentCount": len(INTENTS),
        "groups": {name: group for name, group, _g, _c in INTENT_CATALOG},
        "langs": list(LANGS),
        "phenomena": list(PHENOMENA),
        "slots": list(SLOTS),
        "domainSlots": list(DOMAIN_SLOTS),
        "decoratorSlots": list(DECORATOR_SLOTS),
        "slotSizes": {
            slot: {lang: len(slot_values(slot, lang)) for lang in LANGS}
            for slot in SLOTS
        },
        "rowsPerIntentTarget": ROWS_PER_INTENT_TARGET,
        "rowsPerIntentBounds": [ROWS_PER_INTENT_MIN, ROWS_PER_INTENT_MAX],
        "maxRowsPerTemplate": MAX_ROWS_PER_TEMPLATE,
        "minTemplatesPerLang": MIN_TEMPLATES_PER_LANG,
        "templateCapacityMargin": TEMPLATE_CAPACITY_MARGIN,
        "textChars": [MIN_TEXT_CHARS, MAX_TEXT_CHARS],
        "totalRowBounds": [TOTAL_ROWS_MIN, TOTAL_ROWS_MAX],
        "langBudget": dict(LANG_BUDGET),
        "langFloorPerIntent": dict(MIN_LANG_ROWS_PER_INTENT),
        "authoredFloors": {
            "total": AUTHORED_MIN_TOTAL, "perIntent": AUTHORED_MIN_PER_INTENT,
        },
        "exam": {
            "perIntent": EXAM_ROWS_PER_INTENT, "total": EXAM_ROWS_TOTAL,
            "langQuota": dict(EXAM_LANG_QUOTA),
        },
        "valFraction": VAL_FRACTION,
        "valFractionBounds": [VAL_FRACTION_MIN, VAL_FRACTION_MAX],
        "nearDupContam": NEAR_DUP_CONTAM,
        "nearDupWarn": NEAR_DUP_WARN,
        "nearDupFatal": NEAR_DUP_FATAL,
        "shingleN": SHINGLE_N,
        "cramersVWarn": CRAMERS_V_WARN,
    }


# ─────────────────────────────────────────────────────────────────────────────
# 7. Self-check
# ─────────────────────────────────────────────────────────────────────────────

#: ``(input, expected)`` for :func:`tidy`. Every one of these is an artifact an
#: empty decorator draw actually produces, not a hypothetical.
_TIDY_CASES: tuple[tuple[str, str], ...] = (
    ("salam ", "salam"),
    (" kal ka slot?", "kal ka slot?"),
    ("book kardo  ye wala", "book kardo ye wala"),
    ("slot khali hai ?", "slot khali hai?"),
    ("kya , yaar", "kya, yaar"),
    ("salam bhai ,", "salam bhai"),
    (", kal shaam", "kal shaam"),
    ("hai ? ?", "hai?"),
    ("kahan gaye??", "kahan gaye??"),
    ("", ""),
)

#: ``(pattern, lang, intent, expected-substring-of-first-problem)``. ``None``
#: means the pattern must validate clean.
_PATTERN_CASES: tuple[tuple[str, str, str | None, str | None], ...] = (
    ("show {sport} grounds in {area} {polite}", "en", "find_venue", None),
    ("{opener} {area} me koi {sport} {venue_word} hai", "ru", "find_venue", None),
    ("salam {polite}", "ru", "greeting", None),
    ("order pizza {polite}", "en", "out_of_scope", None),
    ("show {Sport} grounds", "en", None, "malformed"),
    ("show {sportz} grounds", "en", None, "unknown slot"),
    ("show {sport} grounds ?", "en", None, "tidy normal form"),
    ("acha {polite} kya hai", "ru", None, "decorators must be first or last"),
    ("{venue_word}s dikhao", "ru", None, "glued"),
    ("{sport} ka score kya hai", "ru", "out_of_scope", "domain slot"),
    ("show {sport ground", "en", None, "malformed"),
    ("kal ka slot – dikhao", "ru", None, "non-ASCII"),
)

#: ``(text, expected-substring-of-first-problem)`` for :func:`text_problems`.
#: ``None`` means the row must be accepted. The first three are the ones that
#: matter: they are the rows an over-eager cleaner would "fix".
_TEXT_CASES: tuple[tuple[str, str | None], ...] = (
    ("kahan gaye??", None),
    ("20 25 log aayenge :)", None),
    ("shukriya \U0001F64F", None),
    ("ok \U0001F44D thanks", None),
    ("loss ??", "whitespace before sentence punctuation"),
    ("a  b", "double space"),
    (" hi there", "leading or trailing whitespace"),
    ("ok", "length"),
    ("wallet {sport} kaise", "brace"),
    ("curly \u2019quote", "disallowed character"),
    ("kya\u0645 hai", "disallowed character"),
    ("kal\tshaam", "control character"),
    ("", "empty text"),
    ("   ", "empty text"),
)

#: :func:`stable_seed` pinned against a literal. Recomputing sha256 inside the
#: test would prove nothing; a literal is what actually detects the day somebody
#: "simplifies" this to ``hash()`` and reproducibility quietly dies.
_PINNED_SEED: int = 3481851257299005900  # stable_seed(INTENT_SPEC_VERSION, "find_venue-en-01")
#: The v1 value was 3041649028626642170. It changed because INTENT_SPEC_VERSION is
#: an input to the seed, which is the whole point of this pin: every generated row
#: is reseeded by a label-contract change, so a v2 corpus cannot silently inherit
#: v1's draws and pass itself off as the same dataset.

#: ``(left, right, same?)`` for :func:`dedup_key`. The two ``False`` rows are the
#: load-bearing ones: they pin that this key does NOT fold Roman Urdu spelling
#: variants, because folding them here would delete the very rows that teach the
#: classifier ``nhi`` and ``nahi`` are the same intent.
_DEDUP_CASES: tuple[tuple[str, str, bool], ...] = (
    ("Kal shaam slot hai?", "kal shaam slot hai", True),
    ("book  kardo", "book kardo", True),
    ("wallet me paise?", "wallet me paise!", True),
    ("nhi chahiye", "nahi chahiye", False),
    ("plz book kardo", "please book kardo", False),
)


def self_check() -> list[tuple[str, str]]:
    """Assert every invariant this contract promises; return one receipt per group.

    Receipts, not booleans: ``--self-check`` prints them, and the generator copies
    them into ``intents_meta.json`` so a reader of the metadata can see WHICH
    invariants held at build time rather than trusting one aggregate PASS.

    Raises :class:`AssertionError` on the first violation. Every message names the
    fix, because the person reading it is usually the person who just edited a
    tuple three hundred lines up.
    """
    receipts: list[tuple[str, str]] = []

    # ---- 1. the label contract ------------------------------------------------
    assert len(INTENTS) == 23, (
        f"INTENTS has {len(INTENTS)} entries; the S.6 contract fixes the v2 label "
        f"set at 23. Adding a twenty-fourth is a model-invalidating change: bump "
        f"INTENT_SPEC_VERSION and retrain, do not just append"
    )
    assert len(set(INTENTS)) == len(INTENTS), "INTENTS contains a duplicate"
    assert list(INTENTS) == sorted(INTENTS), (
        "INTENTS must stay alphabetical: scikit-learn sorts string classes, so "
        "this ordering is what makes model.classes_ line up with INTENTS without "
        "a remap, and what keeps a confusion matrix's axes stable across runs"
    )
    assert all(name.islower() and name.replace("_", "").isalnum() for name in INTENTS), (
        "intent names are lowercase snake_case; they appear verbatim in JSON "
        "responses and in the Node dialog manager's switch"
    )
    assert "out_of_scope" in INTENTS, (
        "out_of_scope is not optional -- without it the classifier must assign "
        "'order pizza' to one of the fourteen real intents, and the assistant "
        "cannot fall back gracefully (S.6 spec)"
    )
    receipts.append(("intents", f"{len(INTENTS)} unique, alphabetical, incl out_of_scope"))

    # ---- 2. the catalog agrees with the label set -----------------------------
    catalog_names = tuple(name for name, _g, _gl, _c in INTENT_CATALOG)
    assert len(set(catalog_names)) == len(catalog_names), (
        f"INTENT_CATALOG lists an intent twice: "
        f"{sorted(n for n in set(catalog_names) if catalog_names.count(n) > 1)}"
    )
    assert tuple(sorted(catalog_names)) == INTENTS, (
        f"INTENT_CATALOG covers {catalog_names} but INTENTS is {INTENTS}. The two "
        f"tuples hold the same {len(INTENTS)} names in two different ORDERS on purpose -- "
        f"INTENTS is alphabetical because that is model.classes_ order and so the "
        f"order every confusion-matrix axis must use, while the catalog keeps the "
        f"S.6 spec's presentation order (discovery, booking, account, team, info) "
        f"because that is what reads well in --intents and in the report. What may "
        f"NOT differ is the membership"
    )
    for name, group, gloss, confusable in INTENT_CATALOG:
        assert group in INTENT_GROUPS, f"{name}: unknown group {group!r}"
        assert gloss.strip(), f"{name}: empty gloss"
        assert confusable in INTENTS, f"{name}: confusable {confusable!r} is not an intent"
        assert confusable != name, (
            f"{name} is listed as its own most-confusable intent; that field "
            f"exists to point at the OTHER intent whose boundary needs authored "
            f"rows, so naming itself makes it useless"
        )
    used_groups = {group for _n, group, _gl, _c in INTENT_CATALOG}
    assert used_groups == set(INTENT_GROUPS), (
        f"INTENT_GROUPS declares {sorted(set(INTENT_GROUPS) - used_groups)} which "
        f"no intent uses; an empty row in the grouped confusion matrix reads as a "
        f"bug in the report"
    )
    receipts.append((
        "catalog",
        f"{len(INTENT_CATALOG)} glosses in spec order, {len(INTENT_GROUPS)} groups all used, "
        f"confusable != self",
    ))

    # ---- 3. languages ---------------------------------------------------------
    assert set(LANG_BUCKETS) == set(LANGS), "LANG_BUCKETS and LANGS disagree"
    for lang, buckets in LANG_BUCKETS.items():
        assert buckets, f"lang {lang!r} has no buckets"
        assert len(set(buckets)) == len(buckets), f"lang {lang!r} repeats a bucket"
        assert buckets[0] == "*", (
            f"lang {lang!r} must read the shared '*' bucket first so a value that "
            f"is language-neutral keeps the same index in every language"
        )
    assert set(LANG_BUCKETS["mix"]) >= set(LANG_BUCKETS["en"]) | set(LANG_BUCKETS["ru"]), (
        "code-mixed rows draw from both vocabularies by definition; if 'mix' did "
        "not read the union it would be a third language rather than a mixture"
    )
    receipts.append(("langs", f"{'/'.join(LANGS)}, mix reads en+ru, '*' first"))

    # ---- 4. phenomena, sources, splits ---------------------------------------
    assert list(PHENOMENA) == sorted(PHENOMENA), "PHENOMENA must stay alphabetical"
    assert len(set(PHENOMENA)) == len(PHENOMENA), "PHENOMENA contains a duplicate"
    assert "plain" in PHENOMENA, (
        "'plain' is required: a row with no interesting phenomenon still needs a "
        "tag, and an empty phenomena cell would be indistinguishable from a row "
        "somebody forgot to annotate"
    )
    assert SOURCES == ("authored", "template"), (
        f"SOURCES is {SOURCES}; the generator's census and every 'authored rows "
        f"are 12% of the corpus' claim keys off exactly these two values"
    )
    assert SPLITS == ("train", "val"), f"SPLITS is {SPLITS}, expected train/val"
    receipts.append((
        "annotation",
        f"{len(PHENOMENA)} phenomena alphabetical, sources={'/'.join(SOURCES)}, "
        f"splits={'/'.join(SPLITS)}",
    ))

    # ---- 5. slot vocabulary ---------------------------------------------------
    assert SLOTS == tuple(sorted(SLOT_VOCAB)), "SLOTS is out of sync with SLOT_VOCAB"
    assert set(DECORATOR_SLOTS) <= set(SLOTS), "a decorator slot is not in SLOT_VOCAB"
    assert set(DOMAIN_SLOTS) | set(DECORATOR_SLOTS) == set(SLOTS), (
        "DOMAIN_SLOTS and DECORATOR_SLOTS must partition SLOTS: the out_of_scope "
        "gate in validate_pattern tests membership of DOMAIN_SLOTS, so a slot in "
        "neither tuple would be silently exempt from it"
    )
    assert not set(DOMAIN_SLOTS) & set(DECORATOR_SLOTS), (
        "a slot is both a domain slot and a decorator"
    )
    for slot in SLOTS:
        buckets = SLOT_VOCAB[slot]
        assert set(buckets) <= {"*", "en", "ru"}, (
            f"slot {slot!r} has bucket {sorted(set(buckets) - {'*', 'en', 'ru'})}; "
            f"only '*', 'en' and 'ru' are read by LANG_BUCKETS"
        )
        for lang in LANGS:
            values = slot_values(slot, lang)
            assert values, (
                f"slot {slot!r} resolves to nothing for lang {lang!r}; any template "
                f"using it in that language would render a literal '{{{slot}}}' or "
                f"crash the generator"
            )
            assert len(set(values)) == len(values), (
                f"slot_values({slot!r}, {lang!r}) returned a duplicate; the "
                f"first-seen dedup in slot_values is what keeps pattern_capacity "
                f"honest, because a repeated value would inflate the count and the "
                f"mixed-radix draw would then emit the same row twice"
            )
            if slot in DECORATOR_SLOTS:
                assert values[0] == "", (
                    f"decorator {slot!r} must offer '' FIRST for lang {lang!r}: the "
                    f"empty draw is what lets a slot-poor intent reach its row "
                    f"quota without inventing phrasings, and index 0 is the value "
                    f"validate_pattern's empty-render probe uses"
                )
            else:
                assert "" not in values, (
                    f"domain slot {slot!r} offers an empty value for lang {lang!r}; "
                    f"that would ship a row with a missing entity but a label that "
                    f"claims one is present"
                )
            assert all(value == value.strip() for value in values), (
                f"slot {slot!r}/{lang!r} has a value with leading or trailing "
                f"whitespace; tidy() would repair the row but the capacity count "
                f"and the dedup key would already have diverged"
            )
            assert all(ord(char) < 128 for value in values for char in value), (
                f"slot {slot!r}/{lang!r} contains a non-ASCII value"
            )
    receipts.append((
        "slots",
        f"{len(SLOTS)} slots ({len(DOMAIN_SLOTS)} domain + {len(DECORATOR_SLOTS)} "
        f"decorator) resolve non-empty and dedup in all {len(LANGS)} langs",
    ))

    # ---- 6. tidy --------------------------------------------------------------
    for raw, expected in _TIDY_CASES:
        got = tidy(raw)
        assert got == expected, f"tidy({raw!r}) -> {got!r}, expected {expected!r}"
        assert tidy(got) == got, (
            f"tidy is not idempotent on {got!r}: it runs on generated rows and again "
            f"on hand-edited ones, so a second pass that changes the text would "
            f"make the corpus depend on how many times it had been cleaned"
        )
    receipts.append(("tidy", f"{len(_TIDY_CASES)} pinned cases, idempotent"))

    # ---- 7. the dedup key does not fold spelling ------------------------------
    for left, right, same in _DEDUP_CASES:
        got = dedup_key(left) == dedup_key(right)
        assert got == same, (
            f"dedup_key({left!r}) == dedup_key({right!r}) is {got}, expected {same}"
        )
    assert dedup_key("nhi") != dedup_key("nahi"), (
        "dedup_key folded a Roman Urdu spelling variant. It must not: text_norm's "
        "VARIANTS table exists to help a SENTIMENT model generalise, but here "
        "'nhi'/'nahi' are two rows the intent classifier is supposed to learn from. "
        "Folding them turns deliberate spelling diversity into a duplicate and "
        "deletes it"
    )
    assert dedup_key("Kal  SHAAM?") == dedup_key("kal shaam"), (
        "dedup_key must ignore case, punctuation and whitespace -- those are the "
        "differences that make two rows the same utterance"
    )
    for text, expected in _TEXT_CASES:
        problems = text_problems(text)
        if expected is None:
            assert not problems, (
                f"text_problems({text!r}) rejected an authored row: {problems}. The "
                f"three accepted cases are pinned because they are what an "
                f"over-eager cleaner deletes: an emphatic '??', an emoticon after a "
                f"space, and an emoji"
            )
        else:
            assert problems, f"text_problems({text!r}) accepted a bad row"
            assert expected in problems[0], (
                f"text_problems({text!r}) first problem is {problems[0]!r}, expected "
                f"it to mention {expected!r}"
            )
    for text, _expected in _TEXT_CASES:
        if text_problems(text):
            continue
        assert tidy(text) == text or "??" in text or ":" in text, (
            f"an accepted authored row {text!r} is not in tidy normal form and is "
            f"not one of the two documented reasons for that (a deliberate doubled "
            f"mark, an emoticon). tidy and text_problems are allowed to disagree, "
            f"but only in ways this contract has written down"
        )
    receipts.append((
        "text_problems",
        f"{len(_TEXT_CASES)} pinned cases; '??', ' :)' and emoji accepted, "
        f"Urdu script and curly quotes rejected",
    ))

    receipts.append((
        "dedup_key",
        f"{len(_DEDUP_CASES)} cases; case/punct/space folded, spelling NOT folded",
    ))

    # ---- 8. near-duplicate scoring -------------------------------------------
    score, metric = near_dup_score("kal shaam football ground", "kal shaam football ground")
    assert score == 1.0, f"identical texts scored {score}, expected 1.0"
    score, metric = near_dup_score(
        "football ground kal shaam chahiye", "kal shaam chahiye football ground"
    )
    assert score >= NEAR_DUP_CONTAM and metric == "word_set", (
        f"a pure reordering scored {score:.4f} via {metric!r}; both metrics exist "
        f"precisely because char shingles miss reordering and word sets miss "
        f"spelling drift, and this is the case that proves the word-set half is "
        f"still wired in"
    )
    score, _metric = near_dup_score("wallet balance batao", "tournament kab hai")
    assert score < 0.30, f"unrelated texts scored {score:.4f}"
    assert near_dup_score("", "")[0] == 0.0, "empty/empty must be 0.0, not a ZeroDivisionError"
    receipts.append(("near_dup", "identical=1.0, reordering caught by word_set, empty safe"))

    # ---- 9. determinism -------------------------------------------------------
    got_seed = stable_seed(INTENT_SPEC_VERSION, "find_venue-en-01")
    assert got_seed == _PINNED_SEED, (
        f"stable_seed(INTENT_SPEC_VERSION, 'find_venue-en-01') is {got_seed}, "
        f"pinned at {_PINNED_SEED}. Either the derivation changed -- in which case "
        f"every row of intents.csv changes and the committed sha256 in "
        f"intents_meta.json is now wrong -- or somebody replaced sha256 with "
        f"hash(), which is salted per process and would make the corpus differ "
        f"between two runs of the same command"
    )
    assert stable_seed("a", "b") != stable_seed("b", "a"), (
        "stable_seed must be order-sensitive; the \x1f join is what stops "
        "('ab','c') and ('a','bc') from colliding too"
    )
    assert stable_seed("a", "b") >= 0, "seed must be non-negative for random.Random"
    cardinalities = (5, 3, 4)
    total = 5 * 3 * 4
    seen = {decode_index(index, cardinalities) for index in range(total)}
    assert len(seen) == total, (
        f"decode_index produced {len(seen)} distinct tuples for {total} distinct "
        f"indices; the generator relies on 'distinct index => distinct value tuple' "
        f"to draw duplicate-free rows WITHOUT a retry loop, and a retry loop is "
        f"what makes an expansion depend on iteration order"
    )
    assert decode_index(0, cardinalities) == (0, 0, 0)
    assert decode_index(1, cardinalities) == (1, 0, 0), (
        "decode_index is little-endian on purpose: consecutive indices must vary "
        "the LEFTMOST slot, so a truncated draw still varies the head of the "
        "sentence rather than only its last word"
    )
    assert decode_index(total - 1, cardinalities) == (4, 2, 3)
    for bad in (total, -1):
        try:
            decode_index(bad, cardinalities)
        except ValueError:
            pass
        else:
            raise AssertionError(
                f"decode_index({bad}, {cardinalities}) did not raise; an "
                f"out-of-range index means the quota allocator asked for more rows "
                f"than the template can produce, which must fail loudly"
            )
    receipts.append((
        "determinism",
        f"seed pinned at {_PINNED_SEED}, decode_index bijective over {total} indices",
    ))

    # ---- 10. pattern validation ----------------------------------------------
    for pattern, lang, intent, expected in _PATTERN_CASES:
        problems = validate_pattern(pattern, lang, intent)
        if expected is None:
            assert not problems, f"{pattern!r} ({lang}) should be clean, got {problems}"
        else:
            assert problems, f"{pattern!r} ({lang}) should have failed on {expected!r}"
            assert expected in problems[0], (
                f"{pattern!r} ({lang}) first problem is {problems[0]!r}, expected it "
                f"to mention {expected!r}"
            )
    assert validate_pattern("hello", "xx") == ["unknown lang 'xx'"], (
        "an unknown lang must be reported alone; continuing would call slot_values "
        "with it and raise a KeyError from four frames down"
    )
    receipts.append(("validate_pattern", f"{len(_PATTERN_CASES)} pinned cases + unknown lang"))

    # ---- 11. capacity and rendering ------------------------------------------
    capacity = pattern_capacity("{sport} {venue_word} in {city}", "en")
    expected_capacity = (
        len(slot_values("sport", "en"))
        * len(slot_values("venue_word", "en"))
        * len(slot_values("city", "en"))
    )
    assert capacity == expected_capacity == 150, (
        f"pattern_capacity == {capacity}, computed {expected_capacity}, pinned 150. "
        f"The pin is deliberate: it fails when a slot's vocabulary grows, which is "
        f"exactly when the per-template quota allocation needs re-reading"
    )
    assert pattern_capacity("salam", "ru") == 1, (
        "a slot-free pattern has capacity 1, not 0 -- it can still contribute one row"
    )
    assert pattern_capacity("{sport} vs {sport}", "en") == len(slot_values("sport", "en")), (
        "a slot repeated in one pattern is filled once and substituted everywhere, "
        "so it multiplies capacity once"
    )
    rendered = render("{opener} {area} me {sport} {venue_word} hai", {
        "opener": "", "area": "f-11", "sport": "football", "venue_word": "ground",
    })
    assert rendered == "f-11 me football ground hai", (
        f"render+tidy of an empty opener gave {rendered!r}; the leading space an "
        f"empty decorator leaves behind is the single most common artifact in a "
        f"template corpus and tidy is what removes it"
    )
    budget = capacity_budget(["{sport} {venue_word} in {city}", "salam"], "en")
    assert budget == MAX_ROWS_PER_TEMPLATE + 1, (
        f"capacity_budget gave {budget} for a 150-combination template plus a "
        f"slot-free one; it must be min(150, {MAX_ROWS_PER_TEMPLATE}) + 1 = "
        f"{MAX_ROWS_PER_TEMPLATE + 1}. Summing raw capacities here is the bug this "
        f"function exists to prevent -- it would report 151 rows available from a "
        f"pair of templates that can honestly supply 13"
    )
    assert capacity_budget([], "en") == 0, "no templates means no rows, not an error"
    receipts.append((
        "capacity",
        f"pinned 150, slot-free=1, repeat counted once, budget caps at "
        f"{MAX_ROWS_PER_TEMPLATE}/template, render clean",
    ))

    # ---- 12. quota coherence --------------------------------------------------
    assert ROWS_PER_INTENT_MIN <= ROWS_PER_INTENT_TARGET <= ROWS_PER_INTENT_MAX, (
        f"target {ROWS_PER_INTENT_TARGET} is outside "
        f"[{ROWS_PER_INTENT_MIN}, {ROWS_PER_INTENT_MAX}]"
    )
    planned = len(INTENTS) * ROWS_PER_INTENT_TARGET
    assert TOTAL_ROWS_MIN <= planned <= TOTAL_ROWS_MAX, (
        f"{len(INTENTS)} intents x {ROWS_PER_INTENT_TARGET} rows = {planned}, outside "
        f"[{TOTAL_ROWS_MIN}, {TOTAL_ROWS_MAX}]. The two bounds are independent "
        f"gates in the generator, so they have to be able to hold at once"
    )
    assert TOTAL_ROWS_MIN == len(INTENTS) * ROWS_PER_INTENT_MIN, (
        f"TOTAL_ROWS_MIN is {TOTAL_ROWS_MIN} but 15 intents on their per-intent "
        f"floor total {len(INTENTS) * ROWS_PER_INTENT_MIN}. The total bounds are "
        f"derived so the two gates cannot contradict each other -- a hand-written "
        f"floor above the derived one is unsatisfiable, and one below it is dead code"
    )
    assert TOTAL_ROWS_MAX == len(INTENTS) * ROWS_PER_INTENT_MAX, (
        f"TOTAL_ROWS_MAX is {TOTAL_ROWS_MAX}, derived value "
        f"{len(INTENTS) * ROWS_PER_INTENT_MAX}"
    )
    assert abs(sum(LANG_BUDGET.values()) - 1.0) < 1e-9, (
        f"LANG_BUDGET sums to {sum(LANG_BUDGET.values())}, not 1.0; it is read as a "
        f"share of each intent's row quota"
    )
    assert set(LANG_BUDGET) == set(LANGS) == set(MIN_LANG_ROWS_PER_INTENT)
    for lang, floor in MIN_LANG_ROWS_PER_INTENT.items():
        share = int(LANG_BUDGET[lang] * ROWS_PER_INTENT_MIN)
        assert floor <= share, (
            f"lang {lang!r} floor is {floor} rows/intent but its budget share of the "
            f"per-intent MINIMUM is only {share}; the floor could then be "
            f"unreachable for an intent that sits near its lower bound"
        )
    assert sum(EXAM_LANG_QUOTA.values()) == EXAM_ROWS_PER_INTENT, (
        f"EXAM_LANG_QUOTA sums to {sum(EXAM_LANG_QUOTA.values())} but the exam takes "
        f"{EXAM_ROWS_PER_INTENT} rows per intent"
    )
    assert len(INTENTS) * EXAM_ROWS_PER_INTENT == EXAM_ROWS_TOTAL == 230, (
        f"the exam must be exactly 230 rows, 10 per intent -- the 150 v1 rows "
        f"byte-identical plus 80 for the eight v2 labels, which is what makes a "
        f"v1-vs-v2 score on the shared 150 an honest comparison: "
        f"{len(INTENTS)} x {EXAM_ROWS_PER_INTENT} != {EXAM_ROWS_TOTAL}"
    )
    assert EXAM_LANG_QUOTA["ru"] >= EXAM_LANG_QUOTA["en"], (
        "the exam is Roman-Urdu-heavy on purpose: it is the language the committee "
        "will type at the demo, and the one the training corpus supports least"
    )
    assert AUTHORED_MIN_TOTAL >= 200, (
        "the spec asks for ~200 hand-edited utterances; the floor may not be lowered "
        "to make a thin corpus pass"
    )
    assert AUTHORED_MIN_PER_INTENT * len(INTENTS) <= AUTHORED_MIN_TOTAL, (
        "the per-intent authored floor already exceeds the total floor, so the total "
        "gate would never bind"
    )
    assert VAL_FRACTION_MIN <= VAL_FRACTION <= VAL_FRACTION_MAX, (
        f"VAL_FRACTION {VAL_FRACTION} is outside its own bounds"
    )
    assert 0 < NEAR_DUP_CONTAM < NEAR_DUP_WARN < NEAR_DUP_FATAL < 1.0, (
        f"the three near-duplicate thresholds must stay ordered: "
        f"contamination {NEAR_DUP_CONTAM} (drop from the corpus) < warn "
        f"{NEAR_DUP_WARN} (report) < fatal {NEAR_DUP_FATAL} (refuse to write). "
        f"Out of order, the fatal gate fires before the drop gate can act"
    )
    assert 1.0 < TEMPLATE_CAPACITY_MARGIN < 2.0, (
        f"TEMPLATE_CAPACITY_MARGIN {TEMPLATE_CAPACITY_MARGIN} must leave headroom "
        f"(> 1.0) without demanding twice the corpus (< 2.0)"
    )
    largest_lang_quota = max(
        round(LANG_BUDGET[lang] * ROWS_PER_INTENT_TARGET) for lang in LANGS
    )
    reachable = MIN_TEMPLATES_PER_LANG * MAX_ROWS_PER_TEMPLATE
    assert reachable >= largest_lang_quota, (
        f"an intent sitting on the floor of {MIN_TEMPLATES_PER_LANG} templates for a "
        f"language can supply at most {reachable} rows, but the largest per-language "
        f"quota is {largest_lang_quota}. Three constants have to agree here or the "
        f"generator's feasibility gate is unsatisfiable for a legal corpus: raise "
        f"MIN_TEMPLATES_PER_LANG, raise MAX_ROWS_PER_TEMPLATE, or lower the budget"
    )
    assert MIN_TEXT_CHARS >= 2 and MAX_TEXT_CHARS > MIN_TEXT_CHARS * 10
    assert SHINGLE_N >= 3, "char shingles shorter than 3 match on noise"
    assert 0 < CRAMERS_V_WARN < 1, "Cramer's V lives in [0, 1]"
    receipts.append((
        "quotas",
        f"{len(INTENTS)}x{ROWS_PER_INTENT_TARGET}={planned} rows in "
        f"[{TOTAL_ROWS_MIN},{TOTAL_ROWS_MAX}], exam {EXAM_ROWS_TOTAL}, "
        f"val {VAL_FRACTION:.2f}, <= {MAX_ROWS_PER_TEMPLATE}/template, "
        f"thresholds ordered",
    ))

    # ---- 13. fingerprints -----------------------------------------------------
    label_fp = intent_spec_fingerprint()
    data_fp = dataset_spec_fingerprint()
    for name, value in (("intent", label_fp), ("dataset", data_fp)):
        assert len(value) == 16 and all(char in "0123456789abcdef" for char in value), (
            f"{name} fingerprint {value!r} is not 16 lowercase hex characters"
        )
        assert value == (
            intent_spec_fingerprint() if name == "intent" else dataset_spec_fingerprint()
        ), f"{name} fingerprint is not stable within a process"
    assert label_fp != data_fp, (
        "the two fingerprints are identical, which means they are hashing the same "
        "inputs. They are separate on purpose: the label fingerprint invalidates a "
        "TRAINED MODEL, the dataset fingerprint only invalidates a CORPUS, and "
        "collapsing them would mark every model incompatible the first time "
        "somebody added an area name"
    )
    assert intent_group("find_venue") == "discovery"
    try:
        intent_group("nope")
    except KeyError:
        pass
    else:
        raise AssertionError("intent_group accepted an unknown intent")
    published = spec()
    assert published["intentSpecFingerprint"] == label_fp
    assert published["datasetSpecFingerprint"] == data_fp
    assert published["intents"] == list(INTENTS)
    receipts.append(("fingerprints", f"intent={label_fp} dataset={data_fp} (distinct)"))

    return receipts


# ─────────────────────────────────────────────────────────────────────────────
# 8. CLI
# ─────────────────────────────────────────────────────────────────────────────


def _main(argv: Sequence[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m app.core.intent_spec",
        description="Inspect and verify the assistant intent/dataset contract.",
    )
    parser.add_argument(
        "--self-check", action="store_true",
        help="prove every structural property; exit 1 on any violation",
    )
    parser.add_argument(
        "--spec", action="store_true", help="print the contract summary",
    )
    parser.add_argument(
        "--intents", action="store_true",
        help="print the 15 intents with group, gloss and nearest confusable",
    )
    parser.add_argument(
        "--slots", action="store_true", help="print every slot vocabulary size",
    )
    parser.add_argument(
        "--text", metavar="STR",
        help="run the hand-written-row checks on one utterance",
    )
    parser.add_argument(
        "--pattern", metavar="STR",
        help="validate one template pattern and show what it can render",
    )
    parser.add_argument(
        "--lang", default="en", choices=list(LANGS),
        help="language bucket for --pattern (default: en)",
    )
    parser.add_argument(
        "--intent", metavar="NAME",
        help="intent for --pattern, so the out_of_scope rule is applied too",
    )
    args = parser.parse_args(argv)

    if not (args.self_check or args.spec or args.intents or args.slots
            or args.pattern or args.text):
        parser.print_help()
        return 2

    if args.spec:
        print(f"intent spec     : {INTENT_SPEC_VERSION}  {intent_spec_fingerprint()}")
        print(f"dataset spec    : {DATASET_SPEC_VERSION}  {dataset_spec_fingerprint()}")
        for key, value in spec().items():
            if key in (
                "intentSpecVersion", "intentSpecFingerprint",
                "datasetSpecVersion", "datasetSpecFingerprint",
                "groups", "slotSizes",
            ):
                continue
            if isinstance(value, list):
                value = f"{len(value)}: {', '.join(map(str, value))}"
            print(f"  {key:<22s} {value}")
        print()

    if args.intents:
        width = max(len(name) for name in INTENTS)
        for name, group, gloss, confusable in INTENT_CATALOG:
            print(f"  {name:<{width}s}  {group:<9s}  {gloss}")
            print(f"  {'':<{width}s}  confusable with: {confusable}")
        print(f"\n  {len(INTENTS)} intents in {len(INTENT_GROUPS)} groups: "
              f"{', '.join(INTENT_GROUPS)}\n")

    if args.slots:
        width = max(len(slot) for slot in SLOTS)
        print(f"  {'slot':<{width}s}  " + "  ".join(f"{lang:>4s}" for lang in LANGS)
              + "   kind")
        for slot in SLOTS:
            sizes = "  ".join(f"{len(slot_values(slot, lang)):>4d}" for lang in LANGS)
            kind = "decorator" if slot in DECORATOR_SLOTS else "domain"
            print(f"  {slot:<{width}s}  {sizes}   {kind}")
        print()

    if args.text:
        problems = text_problems(args.text)
        print(f"text       : {args.text!r}")
        print(f"dedup key  : {dedup_key(args.text)!r}")
        print(f"tidy       : {tidy(args.text)!r}")
        for problem in problems:
            print(f"  BAD  {problem}")
        if not problems:
            print("  ok   accepted as a hand-written row")
        print()
        if problems:
            return 1

    if args.pattern:
        problems = validate_pattern(args.pattern, args.lang, args.intent)
        print(f"pattern    : {args.pattern!r}")
        print(f"lang/intent: {args.lang} / {args.intent or '-'}")
        print(f"slots      : {', '.join(pattern_slots(args.pattern)) or '(none)'}")
        print(f"capacity   : {pattern_capacity(args.pattern, args.lang)}")
        if problems:
            for problem in problems:
                print(f"  BAD  {problem}")
        else:
            print("  ok   validates clean")
            names = pattern_slots(args.pattern)
            cardinalities = tuple(len(slot_values(n, args.lang)) for n in names)
            capacity = pattern_capacity(args.pattern, args.lang)
            for index in range(min(3, capacity)):
                picks = decode_index(index, cardinalities) if names else ()
                choices = {
                    name: slot_values(name, args.lang)[pick]
                    for name, pick in zip(names, picks)
                }
                print(f"  ->   {render(args.pattern, choices)!r}")
        print()
        if problems:
            return 1

    if args.self_check:
        try:
            receipts = self_check()
        except AssertionError as error:
            print("FAIL  intent_spec self-check")
            print(f"      {error}")
            return 1
        width = max(len(name) for name, _ in receipts)
        for name, detail in receipts:
            print(f"ok    {name:<{width}s}  {detail}")
        print()
        print(
            f"PASS  {len(receipts)} checks, {INTENT_SPEC_VERSION} / "
            f"{intent_spec_fingerprint()}  +  {DATASET_SPEC_VERSION} / "
            f"{dataset_spec_fingerprint()}"
        )
    return 0


__all__: Sequence[str] = (
    "INTENT_SPEC_VERSION",
    "DATASET_SPEC_VERSION",
    "INTENTS",
    "INTENT_CATALOG",
    "INTENT_GROUPS",
    "LANGS",
    "LANG_BUCKETS",
    "PHENOMENA",
    "SOURCES",
    "SPLITS",
    "SLOT_VOCAB",
    "SLOTS",
    "DOMAIN_SLOTS",
    "DECORATOR_SLOTS",
    "ROWS_PER_INTENT_TARGET",
    "ROWS_PER_INTENT_MIN",
    "ROWS_PER_INTENT_MAX",
    "TOTAL_ROWS_MIN",
    "TOTAL_ROWS_MAX",
    "MAX_ROWS_PER_TEMPLATE",
    "MIN_TEMPLATES_PER_LANG",
    "TEMPLATE_CAPACITY_MARGIN",
    "MIN_TEXT_CHARS",
    "MAX_TEXT_CHARS",
    "LANG_BUDGET",
    "MIN_LANG_ROWS_PER_INTENT",
    "AUTHORED_MIN_TOTAL",
    "AUTHORED_MIN_PER_INTENT",
    "EXAM_ROWS_PER_INTENT",
    "EXAM_ROWS_TOTAL",
    "EXAM_LANG_QUOTA",
    "VAL_FRACTION",
    "VAL_FRACTION_MIN",
    "VAL_FRACTION_MAX",
    "NEAR_DUP_CONTAM",
    "NEAR_DUP_WARN",
    "NEAR_DUP_FATAL",
    "SHINGLE_N",
    "CRAMERS_V_WARN",
    "slot_values",
    "pattern_slots",
    "pattern_capacity",
    "capacity_budget",
    "render",
    "tidy",
    "text_problems",
    "dedup_key",
    "words",
    "shingles",
    "jaccard",
    "near_dup_score",
    "stable_seed",
    "decode_index",
    "validate_pattern",
    "intent_group",
    "intent_spec_fingerprint",
    "dataset_spec_fingerprint",
    "spec",
    "self_check",
)


if __name__ == "__main__":
    raise SystemExit(_main())
