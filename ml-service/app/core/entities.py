"""
Rule-based entity extraction for the SportLynk Assistant

WHAT THIS IS, PLAINLY
This is a RULE-BASED extractor. There is no model in this file: no weights, no
training run, nothing fitted. It is regexes, lexicons and a calendar. That is
not a shortcut and it is not an embarrassment to be hidden in a viva -- it is
how production NLU is built. Rasa's ``DucklingEntityExtractor`` and
``RegexEntityExtractor``, Google Dialogflow's system entities, Amazon Lex's
built-in slot types and Apple's ``NSDataDetector`` are all rules. The reason is
the same everywhere:

  * A date has a RIGHT answer. "kal" on Friday 2026-08-28 is 2026-08-29, and a
    statistical model that gets it right 94% of the time is worse than five
    lines of arithmetic that gets it right always.
  * Entity labels are the expensive kind of annotation. Teaching a model to tag
    spans needs per-token labels over thousands of utterances; the project's
    budget bought 1,700 utterance-level INTENT labels instead, which is the
    label the classifier actually needs.
  * Rules are debuggable in the demo. When "shaam 8 baje" resolves wrongly a
    reviewer can be shown the exact line that did it and the fix ships in a
    minute. A mis-tagged span in a sequence model is a retrain.

So the division of labour in this service is deliberate: the INTENT is learned
(``training/train_intents.py`` fits model #4 over :mod:`app.core.nlu_text`), and
the SLOTS are resolved by rule. Both halves are reported honestly.

WHY IT DOES NOT RUN ON ``nlu_text.prep``
The classifier's view of an utterance masks numbers: ``LONG_DIGITS = 3`` turns
"under 3000" into "under <num>" so that 2000 and 3500 are the same feature and a
budget phrase generalises. That view is right for classification and fatal here
-- the digits ARE the entity. This module therefore prepares its own view
(:func:`prep`), which keeps digits, ``-``, ``/``, ``:`` and ``,`` intact, and
borrows only the parts of the text contract that help word matching:
``PHRASE_FOLD`` and ``fold_token``, so "kl sham" matches one canonical spelling
("kal shaam") instead of needing an entry per misspelling. One spelling table,
two views of the text.

WHY ``dateparser`` IS THE FALLBACK AND NOT THE ENGINE
The spec says "dateparser + Roman Urdu pre-mapping". It was installed
(1.4.2) and measured before being designed in, and the measurements decided the
order:

  * import: ~400 ms. FIRST parse on this machine EVER: 8254.8 ms -- dateparser
    builds its language data once and caches it to disk. After that cache
    exists, a cold process costs 63-66 ms on its first parse and 3-4 ms after.
    Both numbers matter: 66 ms alone exceeds the whole request budget, and the
    8.25 s returns on every fresh container, which is exactly what S.7's Render
    deploy is.
  * ``dateparser.parse("next friday")`` -> None.
    ``dateparser.parse("friday evening")`` -> None.
    ``dateparser.parse("kal shaam")`` -> None.

A first call that costs between 66 ms and 8.25 s depending on whether a disk
cache happens to exist cannot live inside a 50 ms request budget, and a library
that returns None for the three most common shapes in this corpus cannot be the
primary resolver for it. So: deterministic rules first, dateparser tried
last and only on a narrow date-looking fragment, the cold cost paid at startup
by :func:`warm`, and the import kept optional (``HAVE_DATEPARSER``) so the
service and the test suite run without it. The rules are what the demo depends
on; dateparser only widens the tail ("30/08/2026", "sep 3").

WHY THE AREA GAZETTEER DOES NOT COME FROM POSTGRES
The spec says the gazetteer is built from ``venues.city`` and
``venues.area`` at startup, and it is -- but not by querying the database. The
ML tier never touches Postgres (see ``training/build_reco.py``); the catalogue
reaches it as a read-only snapshot pulled by Node's
``GET /api/internal/export/reco-data``, and that snapshot is already sitting
inside ``models/reco_latest.joblib`` as ``model.venues``. :func:`build_gazetteer`
therefore seeds from :data:`app.core.intent_spec.SLOT_VOCAB` (the areas the
classifier was TRAINED on, so serving and training agree) and extends from the
artifact's venue rows via :func:`app.core.reco_features.area_token`, with an
optional ``data/assistant/areas.txt`` override for a venue added after the last
export. No new coupling, and the same area token the recommender's zone block
uses.

PRECISION OVER RECALL, ON PURPOSE
An extractor that guesses fills a booking form with a wrong date. Every rule
here is CUE-ANCHORED: a bare number is never a budget (it needs "under", "tak",
"rs", ...), never a time (it needs "baje", "pm", ":" or a daypart word), and
"hafta" is deliberately NOT mapped to Saturday because it also means "week"
("agle hafte"). When a rule is unsure it returns None and the dialog manager
asks -- which is the correct product behaviour and a much cheaper failure than a
confidently wrong slot.

THE FIVE KEYS ARE A CONTRACT
:func:`extract` returns exactly ``{"date","time","sport","area","budget"}``
(:data:`ENTITY_KEYS`), each either ``None`` or a dict of camelCase fields ready
to cross the wire to Node unchanged. Venue names, durations and head-counts are
NOT in the contract even though the corpus has slots for them: Node owns the
catalogue and can resolve a venue name against the real table far better than a
gazetteer can, and adding keys later is a compatible change while removing them
is not.

Fingerprint: :func:`entity_fingerprint` hashes the RULES (lexicons, windows,
regex sources), never the runtime gazetteer. A venue opening in G-13 must not
mark a trained artifact incompatible; editing the "shaam" window must.

Run it:  python app/core/entities.py --self-check
         python app/core/entities.py --parse "kal shaam f-11 me 3000 tak"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from dataclasses import dataclass
from datetime import date as _date
from datetime import datetime, time as _time, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable, Sequence
from zoneinfo import ZoneInfo

if __package__ in (None, ""):  # allow `python app/core/entities.py`
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from app.core import config, nlu_text, reco_features
from app.core.intent_spec import SLOT_VOCAB

#: Bumped when a rule changes in a way that alters resolved slots.
ENTITY_SPEC_VERSION = "nlu-entities-v1"

#: The frozen key set of :func:`extract`. Order is the documented order.
ENTITY_KEYS: tuple[str, ...] = ("date", "time", "sport", "area", "budget")

#: Everything is resolved in Pakistan Standard Time. A user typing "kal" means
#: tomorrow in Islamabad, not tomorrow in whatever timezone the container drew.
TZ_NAME = "Asia/Karachi"
KARACHI = ZoneInfo(TZ_NAME)

#: Currency of every amount this extractor returns. Reported explicitly rather
#: than implied, so a number crossing the wire is never unit-ambiguous.
CURRENCY = "PKR"


# 1. The extractor's view of the text
# Keep: letters, digits, and the four characters that carry meaning inside a
# slot -- "-" (f-11, 6-8pm), "/" (30/08, g-8/2), ":" (7:30) and "," (2,500).
# Everything else becomes a space, so "f-11?" and "3000/-" stop hiding a match.
_KEEP = re.compile(r"[^0-9a-z\-/:.,\s]+")
_EDGE_PUNCT = "-/:,."
_ZW_CODEPOINTS = (0x200b, 0x200c, 0x200d, 0x200e, 0x200f, 0x2060, 0xfeff)
_ZERO_WIDTH = re.compile("[" + "".join(map(chr, _ZW_CODEPOINTS)) + "]")
# Elongation squeeze, digits excluded. This is the one place this module must
# not copy nlu_text: "3000" contains a run of three zeroes, so a general
# one-character repeat rule rewrites it to "300" and every budget silently
# loses a factor of ten. It is invisible in the classifier's view (both
# collapse to <num>) and fatal here, which is why the pinned cases include
# "10000 tak".
_ELONG = re.compile(r"([^0-9])\1{2,}")     # shaaaam -> shaam, 3000 untouched
_THOUSANDS = re.compile(r"(?<=[0-9]),(?=[0-9]{3}(?![0-9]))")
_SPACES = re.compile(r"\s+")


def prep(text: Any) -> str:
    """Lower-cased, punctuation-stripped text with the digits INTACT.

    Deliberately not :func:`app.core.nlu_text.normalize` -- see the module
    docstring. Shares that module's ``PHRASE_FOLD`` and per-token folding so one
    spelling table serves both views.
    """
    if text is None:
        return ""
    s = unicodedata.normalize("NFKC", str(text))
    s = _ZERO_WIDTH.sub("", s).casefold()
    for phrase, canon in nlu_text.PHRASE_FOLD:
        s = s.replace(phrase, canon)
    s = _ELONG.sub(r"\1\1", s)
    s = _THOUSANDS.sub("", s)              # 2,500 -> 2500
    s = _KEEP.sub(" ", s)
    s = _SPACES.sub(" ", s).strip()
    out: list[str] = []
    for token in s.split(" "):
        token = token.strip(_EDGE_PUNCT)   # "kal." -> "kal", "3000/-" -> "3000"
        if token:
            out.append(_fold(token))
    return " ".join(out)


def _fold(token: str) -> str:
    """``nlu_text.fold_token`` on the token's alphabetic core.

    A token like "f-11" or "7:30" has no fold entry and must survive untouched,
    so folding is attempted only when the token is pure letters. This is what
    makes "kl", "sham", "futbal" and "grownd" reach the lexicons as "kal",
    "shaam", "football" and "ground".
    """
    return nlu_text.fold_token(token) if token.isalpha() else token


def _words(prepped: str) -> list[str]:
    return prepped.split(" ") if prepped else []


def _has(prepped: str, *needles: str) -> bool:
    """Whole-word / whole-phrase containment on prepped text."""
    padded = f" {prepped} "
    return any(f" {n} " in padded for n in needles)


# 2. Sport
# Canonical values are exactly SLOT_VOCAB["sport"] -- the vocabulary the
# classifier was trained on and the values Node's venue filter understands.
# futsal is not folded into football: they are different products with different
# venues, and telling them apart is the whole point of extracting a sport.
#
# Most surface variants are already handled upstream (nlu_text folds futbal,
# fotball, krikat, ...). What is added here is words that are not spellings of
# the canonical term: the ball codes, and "5-a-side" style forms that name a
# format rather than a sport.
SPORT_WORDS: dict[str, tuple[str, ...]] = {
    "football": ("football", "soccer", "fifa"),
    "futsal": ("futsal",),
    "cricket": ("cricket", "tapeball", "hardball", "gully", "nets"),
    "badminton": ("badminton", "shuttle", "shuttlecock"),
    "tennis": ("tennis",),
}

#: Ball code -> the ``variant`` field. Cricket in Pakistan is two different
#: games and a venue that only has tape-ball nets is the wrong answer for a
#: hard-ball match, so the distinction is carried rather than dropped.
SPORT_VARIANTS: dict[str, str] = {
    "tapeball": "tapeball",
    "hardball": "hardball",
    "nets": "nets",
    "gully": "tapeball",
}

#: Formats that imply a pitch size, not a sport. Recorded so the extractor can
#: see them without inventing a sport from them: "5v5" is played on futsal
#: courts and football turf alike, so guessing here would be a wrong answer.
FORMAT_WORDS: tuple[str, ...] = ("5v5", "6v6", "7v7", "8v8", "11v11")


def extract_sport(prepped: str) -> dict[str, Any] | None:
    """First sport word wins, scanning left to right."""
    for token in _words(prepped):
        for canon, surfaces in SPORT_WORDS.items():
            if token in surfaces:
                out: dict[str, Any] = {"value": canon, "text": token, "source": "lexicon"}
                variant = SPORT_VARIANTS.get(token)
                if variant:
                    out["variant"] = variant
                return out
    return None


# 3. Dates
# The Roman Urdu pre-mapping the spec asks for. Offsets in days from
# "today in Asia/Karachi".
#
# "kal" is ambiguous in Urdu -- it is both yesterday and tomorrow, disambiguated
# by verb tense that this extractor does not parse. It resolves to +1 because
# every intent that carries a date here is about a booking, and yesterday cannot
# be booked. Recorded as a known limitation rather than left as a surprise: an
# utterance about a past booking ("kal ka refund") gets tomorrow's date, which
# the dialog manager ignores for refund intents because it does not ask for one.
RELATIVE_DAYS: dict[str, int] = {
    "aaj": 0, "today": 0, "abhi": 0, "now": 0,
    "tonight": 0, "tonite": 0,
    "kal": 1, "tomorrow": 1, "tomorow": 1, "tommorow": 1, "tommorrow": 1,
    "parso": 2,          # nlu_text folds parsun/parson/parsoon and "day after tomorrow"
}

#: Words that carry a time-of-day as well as a day. Kept separate so
#: :func:`extract_time` can pick "tonight" up without :func:`extract_date`
#: having to hand it over.
DAY_AND_TIME: dict[str, str] = {"tonight": "raat", "tonite": "raat"}

# Weekday names -> Monday=0. Roman Urdu included; two deliberate omissions:
#   * "sun" -- SLOT_VOCAB's opener list has "sun" as the Urdu imperative
#     "listen" ("sun bhai"), so mapping it to Sunday would date every third
#     greeting. "sunday" is unambiguous and stays.
#   * "hafta" -- it means both Saturday and week ("agle hafte" = next week).
#     Only the unambiguous Saturday words are mapped.
WEEKDAYS: dict[str, int] = {
    "monday": 0, "mon": 0, "peer": 0, "somwar": 0,
    "tuesday": 1, "tue": 1, "tues": 1, "mangal": 1,
    "wednesday": 2, "wed": 2, "budh": 2,
    "thursday": 3, "thu": 3, "thur": 3, "thurs": 3, "jumeraat": 3, "jumerat": 3,
    "friday": 4, "fri": 4, "jumma": 4, "juma": 4, "jummah": 4, "jumah": 4,
    "saturday": 5, "sat": 5, "sanicher": 5, "sanichar": 5,
    "sunday": 6, "itwar": 6, "itwaar": 6, "aitwar": 6,
}

#: "next friday" / "agle jumma" -- forces the strictly next occurrence, so on a
#: Friday it means +7 and not today.
NEXT_CUES: tuple[str, ...] = ("next", "agle", "agli", "aane", "aanay", "coming")

#: Whole-week and weekend phrases, checked before the weekday lexicon because
#: "agle hafte" must not be read as a Saturday.
WEEK_AHEAD_CUES: tuple[str, ...] = ("next week", "agle hafte", "agle hafta", "agle week")
WEEKEND_CUES: tuple[str, ...] = ("weekend", "is weekend", "this weekend", "wikend")

MONTHS: dict[str, int] = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
}
_MONTH_ALT = "|".join(sorted(MONTHS, key=len, reverse=True))

_RE_ISO_DATE = re.compile(r"\b(20[0-9]{2})-([01]?[0-9])-([0-3]?[0-9])\b")
# Numeric day/month. "/" always; "-" only with a 4-digit year, because "6-8pm"
# is a time range and would otherwise parse as the 6th of August.
_RE_DMY_SLASH = re.compile(r"\b([0-3]?[0-9])/([01]?[0-9])(?:/((?:20)?[0-9]{2}))?\b")
_RE_DMY_DASH = re.compile(r"\b([0-3]?[0-9])-([01]?[0-9])-(20[0-9]{2})\b")
_RE_DAY_MONTH = re.compile(rf"\b([0-3]?[0-9])(?:st|nd|rd|th)?\s+({_MONTH_ALT})\b")
_RE_MONTH_DAY = re.compile(rf"\b({_MONTH_ALT})\s+([0-3]?[0-9])(?:st|nd|rd|th)?\b")
_RE_DAYS_LATER = re.compile(r"\b([0-9]{1,2})\s+din\s+baad\b")
#: Fragment handed to dateparser when every rule above has declined. Narrow on
#: purpose -- dateparser is aggressive enough to read a bare "5" as a date.
_RE_DATE_FRAGMENT = re.compile(
    rf"\b(?:[0-3]?[0-9][/\-][01]?[0-9](?:[/\-][0-9]{{2,4}})?|"
    rf"[0-3]?[0-9]\s+(?:{_MONTH_ALT})(?:\s+[0-9]{{4}})?|"
    rf"(?:{_MONTH_ALT})\s+[0-3]?[0-9](?:\s+[0-9]{{4}})?)\b"
)


def today_in_karachi(now: datetime | None = None) -> _date:
    """The current date in Asia/Karachi. ``now`` is injectable so tests are fixed."""
    moment = now or datetime.now(KARACHI)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=KARACHI)
    return moment.astimezone(KARACHI).date()


def _resolve_weekday(base: _date, target: int, strict: bool) -> _date:
    delta = (target - base.weekday()) % 7
    if strict and delta == 0:
        delta = 7
    return base + timedelta(days=delta)


def _resolve_partial(day: int, month: int, base: _date, year: int | None = None) -> _date | None:
    """Complete a day/month into a date, rolling to next year when it has passed.

    ``PREFER_DATES_FROM: future`` as arithmetic: "30 august" typed on 2 September
    means next year's, because nobody books a ground into the past.
    """
    for candidate_year in ([year] if year else [base.year, base.year + 1]):
        try:
            candidate = _date(candidate_year, month, day)
        except ValueError:
            continue
        if year or candidate >= base:
            return candidate
    return None


def _alt(words: Iterable[str]) -> re.Pattern[str]:
    """Word-boundary alternation, longest first so "sept" beats "sep"."""
    ordered = sorted(set(words), key=lambda w: (-len(w), w))
    return re.compile(r"\b(" + "|".join(re.escape(w) for w in ordered) + r")\b")


_RE_RELATIVE = _alt(RELATIVE_DAYS)
_RE_WEEKDAY = _alt(WEEKDAYS)
_RE_WEEK_AHEAD = _alt(WEEK_AHEAD_CUES)
_RE_WEEKEND = _alt(WEEKEND_CUES)
_RE_NEXT_CUE = _alt(NEXT_CUES)


def _overlaps(span: tuple[int, int], claimed: Sequence[tuple[int, int]]) -> bool:
    return any(span[0] < end and start < span[1] for start, end in claimed)


def _words_before(prepped: str, index: int, count: int = 2) -> list[str]:
    return prepped[:index].split(" ")[-count:] if index else []


def _word_after(prepped: str, index: int) -> str:
    rest = prepped[index:].lstrip()
    return rest.split(" ", 1)[0] if rest else ""


def _date_hit(
    start: _date,
    end: _date | None,
    text: str,
    rule: str,
    span: tuple[int, int],
    source: str = "rule",
) -> dict[str, Any]:
    return {
        "iso": start.isoformat(),
        "endIso": end.isoformat() if end else None,
        "text": text,
        "rule": rule,
        "source": source,
        "span": [span[0], span[1]],
    }


def extract_date(
    prepped: str,
    *,
    now: datetime | None = None,
    claimed: Sequence[tuple[int, int]] = (),
) -> dict[str, Any] | None:
    """Resolve at most one date. Most specific rule first, ``None`` when unsure.

    ``endIso`` is set only by rules that genuinely name a range ("this weekend");
    a single day leaves it ``None`` rather than repeating ``iso``, so Node can
    tell "Saturday" from "Saturday to Sunday".
    """
    base = today_in_karachi(now)

    # 1. Ranges and whole weeks, before the weekday lexicon: "agle hafte" is a
    #    week, not a Saturday.
    match = _RE_WEEKEND.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        weekday = base.weekday()
        if weekday == 5:                       # already Saturday
            start, end = base, base + timedelta(days=1)
        elif weekday == 6:                     # Sunday: the weekend is today
            start, end = base, base
        else:
            start = _resolve_weekday(base, 5, strict=False)
            end = start + timedelta(days=1)
        return _date_hit(start, end, match.group(1), "range:weekend", match.span())

    match = _RE_WEEK_AHEAD.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        return _date_hit(base + timedelta(days=7), None, match.group(1), "offset:next-week", match.span())

    # 2. Absolute dates.
    match = _RE_ISO_DATE.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        try:
            exact = _date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        except ValueError:
            exact = None
        if exact:
            return _date_hit(exact, None, match.group(0), "absolute:iso", match.span())

    for pattern, rule in ((_RE_DMY_SLASH, "absolute:dmy"), (_RE_DMY_DASH, "absolute:dmy")):
        match = pattern.search(prepped)
        if not match or _overlaps(match.span(), claimed):
            continue
        day, month = int(match.group(1)), int(match.group(2))
        raw_year = match.group(3)
        year = None
        if raw_year:
            year = int(raw_year) if len(raw_year) == 4 else 2000 + int(raw_year)
        resolved = _resolve_partial(day, month, base, year)
        if resolved:
            return _date_hit(resolved, None, match.group(0), rule, match.span())

    for pattern, day_group, month_group in ((_RE_DAY_MONTH, 1, 2), (_RE_MONTH_DAY, 2, 1)):
        match = pattern.search(prepped)
        if not match or _overlaps(match.span(), claimed):
            continue
        resolved = _resolve_partial(
            int(match.group(day_group)), MONTHS[match.group(month_group)], base
        )
        if resolved:
            return _date_hit(resolved, None, match.group(0), "absolute:month-name", match.span())

    # 3. "3 din baad".
    match = _RE_DAYS_LATER.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        offset = int(match.group(1))
        if 1 <= offset <= 60:
            return _date_hit(base + timedelta(days=offset), None, match.group(0),
                             "offset:din-baad", match.span())

    # 4. The Roman Urdu / English relative words.
    match = _RE_RELATIVE.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        word = match.group(1)
        return _date_hit(base + timedelta(days=RELATIVE_DAYS[word]), None, word,
                         f"relative:{word}", match.span())

    # 5. Weekday names. "next"/"agle" immediately before forces +7 on the day
    #    itself.
    match = _RE_WEEKDAY.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        word = match.group(1)
        before = _words_before(prepped, match.start(), 2)
        strict = any(_RE_NEXT_CUE.fullmatch(w) for w in before)
        resolved = _resolve_weekday(base, WEEKDAYS[word], strict=strict)
        rule = f"weekday:{word}{':next' if strict else ''}"
        return _date_hit(resolved, None, word, rule, match.span())

    # 6. Last resort: hand a date-looking fragment to dateparser. Never the whole
    #    utterance -- see the module docstring for what it does with one.
    match = _RE_DATE_FRAGMENT.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        parsed = _dateparser_date(match.group(0), base)
        if parsed:
            return _date_hit(parsed, None, match.group(0), "dateparser", match.span(),
                             source="dateparser")
    return None


# 4. dateparser: optional, last, and warmed
try:                                    # pragma: no cover - environment dependent
    import dateparser as _dateparser_mod

    HAVE_DATEPARSER = True
except Exception:                       # pragma: no cover
    _dateparser_mod = None
    HAVE_DATEPARSER = False

#: DMY, because "30/08" is the day of August in Pakistan and the month of the
#: 30th nowhere. dateparser's default is locale-guessed; it is pinned here.
_DATEPARSER_SETTINGS: dict[str, Any] = {
    "TIMEZONE": TZ_NAME,
    "TO_TIMEZONE": TZ_NAME,
    "RETURN_AS_TIMEZONE_AWARE": False,
    "PREFER_DATES_FROM": "future",
    "DATE_ORDER": "DMY",
}


def _dateparser_date(fragment: str, base: _date) -> _date | None:
    """dateparser on one fragment, or None. Never raises into a request."""
    if not HAVE_DATEPARSER or not fragment.strip():
        return None
    settings = dict(_DATEPARSER_SETTINGS)
    settings["RELATIVE_BASE"] = datetime(base.year, base.month, base.day)
    try:
        parsed = _dateparser_mod.parse(fragment, languages=["en"], settings=settings)
    except Exception:                   # pragma: no cover - defensive
        return None
    return parsed.date() if parsed else None


def warm() -> dict[str, Any]:
    """Pay the one-off costs before the first request does.

    Two of them: dateparser's language data (measured at 8254.8 ms on the FIRST
    parse, 1-7 ms after) and the gazetteer's read of ``models/reco_latest.joblib``.
    Called from the service lifespan, and safe to call twice.
    """
    started = datetime.now()
    parsed = _dateparser_date("30 august 2026", _date(2026, 8, 1))
    gazetteer = default_gazetteer()
    return {
        "dateparser": HAVE_DATEPARSER,
        "dateparserOk": parsed is not None,
        "areas": len(gazetteer.entries),
        "elapsedMs": round((datetime.now() - started).total_seconds() * 1000, 1),
    }


# 5. Times
# The daypart windows the spec names, plus their English equivalents. These
# are Windows, not instants: "shaam" is a three-hour slot the action layer can
# search, and collapsing it to 18:00 would silently drop 19:00 and 20:00 from a
# result set the user would have accepted.
#
# "raat" ends at 00:00 rather than 23:59 because a booking end of midnight is the
# real boundary; Node compares half-open ranges.
DAYPART_WINDOWS: dict[str, tuple[str, str]] = {
    "subah": ("06:00", "11:00"),
    "morning": ("06:00", "11:00"),
    "dopahar": ("12:00", "16:00"),
    "afternoon": ("12:00", "16:00"),
    "noon": ("12:00", "13:00"),
    "shaam": ("18:00", "21:00"),
    "evening": ("18:00", "21:00"),
    "raat": ("21:00", "00:00"),
    "night": ("21:00", "00:00"),
    "tonight": ("21:00", "00:00"),
    "tonite": ("21:00", "00:00"),
    "midnight": ("00:00", "01:00"),
}

#: Dayparts that mean AM, for the bare-hour inference below.
_AM_DAYPARTS: tuple[str, ...] = ("subah", "morning")

# Urdu clock fractions. "saade aath" is 8:30 and appears in SLOT_VOCAB, so it is
# in the corpus and has to resolve. "dedh"/"dhai" are irregular: they are not
# "half past N", they are 1:30 and 2:30.
URDU_FRACTIONS: dict[str, int] = {
    "saade": 30, "sade": 30, "sadhe": 30, "sarhe": 30,
    "sawa": 15, "sava": 15,
    "paune": -15,
}
URDU_FIXED_TIMES: dict[str, tuple[int, int]] = {
    "dedh": (1, 30), "derh": (1, 30),
    "dhai": (2, 30), "dhaai": (2, 30),
}
#: Urdu numerals 1-12, which is how a time is spoken as often as it is digited.
URDU_NUMBERS: dict[str, int] = {
    "ek": 1, "do": 2, "teen": 3, "char": 4, "chaar": 4, "panch": 5, "paanch": 5,
    "che": 6, "chey": 6, "chah": 6, "saat": 7, "aath": 8, "ath": 8, "nau": 9,
    "no": 9, "das": 10, "dus": 10, "gyara": 11, "gyarah": 11, "bara": 12,
    "barah": 12,
}

#: Words that make a number a duration, not a clock time. "2 hours" is how long,
#: not when, and reading it as 14:00 would book the wrong slot.
DURATION_WORDS: tuple[str, ...] = (
    "hour", "hours", "hr", "hrs", "ghanta", "ghante", "ghanto", "ghantay",
    "minute", "minutes", "min", "mins", "mint", "mints", "din", "days", "day",
)

#: A bare hour needs one of these to be a time at all (precision over recall):
#: an explicit marker, a ":" , "baje", or a daypart word elsewhere in the
#: utterance. nlu_text already folds bajay/bje/bajey to "baje", so one form
#: covers the spellings.
_TIME_CUES: tuple[str, ...] = ("baje", "am", "pm")

_NUM_ALT = "|".join(sorted(URDU_NUMBERS, key=len, reverse=True))
_FRACTION_ALT = "|".join(sorted(URDU_FRACTIONS, key=len, reverse=True))
_RE_DAYPART = _alt(DAYPART_WINDOWS)
_RE_CLOCK = re.compile(r"\b([0-2]?[0-9])(?::([0-5][0-9]))?\s*(am|pm)?\b")
_RE_BAJE = re.compile(rf"\b(?:([0-2]?[0-9])|({_NUM_ALT}))(?::([0-5][0-9]))?\s*baje\b")
_RE_FRACTION = re.compile(rf"\b({_FRACTION_ALT})\s+(?:([0-2]?[0-9])|({_NUM_ALT}))\b")
_RE_FIXED_TIME = _alt(URDU_FIXED_TIMES)
_RE_RANGE = re.compile(
    r"\b([0-2]?[0-9])(?::([0-5][0-9]))?\s*(am|pm)?\s*(?:se|to|-)\s*"
    r"([0-2]?[0-9])(?::([0-5][0-9]))?\s*(am|pm)?\b"
)


def _fmt_minutes(total: int) -> str:
    total %= 24 * 60
    return f"{total // 60:02d}:{total % 60:02d}"


def _to_24h(hour: int, minute: int, marker: str | None, hint: str | None) -> int:
    """(hour, minute, am/pm, daypart hint) -> minutes past midnight.

    The inference for a bare hour is a documented BOOKING assumption, not a
    guess: "8 baje" with no marker resolves to 20:00 because 1-11 o'clock in a
    ground-booking request is the evening in practice -- the platform's slots run
    late afternoon to midnight. A daypart word overrides it ("subah 8 baje" is
    08:00), and 0 or 13-23 are already unambiguous 24-hour values.
    """
    total = hour * 60 + minute
    if marker == "am":
        return (0 if hour == 12 else hour) * 60 + minute
    if marker == "pm":
        return (12 if hour == 12 else (hour + 12 if hour < 12 else hour)) * 60 + minute
    if hour == 0 or hour >= 12:
        return total
    if hint == "am":
        return total
    return total + 12 * 60


def _time_hit(
    start: int,
    end: int | None,
    text: str,
    rule: str,
    span: tuple[int, int],
) -> dict[str, Any]:
    return {
        "start": _fmt_minutes(start),
        "end": _fmt_minutes(end) if end is not None else None,
        "text": text,
        "rule": rule,
        "source": "rule",
        "span": [span[0], span[1]],
    }


def extract_time(
    prepped: str,
    *,
    now: datetime | None = None,
    claimed: Sequence[tuple[int, int]] = (),
) -> dict[str, Any] | None:
    """Resolve at most one time or time window.

    ``end`` is None for an instant ("8 baje" is a start; how long the booking
    runs is the duration slot's business, which Node owns) and set for a window
    ("shaam" is 18:00-21:00).
    """
    daypart_match = _RE_DAYPART.search(prepped)
    if daypart_match and _overlaps(daypart_match.span(), claimed):
        daypart_match = None
    daypart = daypart_match.group(1) if daypart_match else None
    hint = "am" if daypart in _AM_DAYPARTS else ("pm" if daypart else None)

    # 1. An explicit range: "6 se 8", "6-8pm", "shaam 6 se 8 tak".
    for match in _RE_RANGE.finditer(prepped):
        if _overlaps(match.span(), claimed):
            continue
        if _word_after(prepped, match.end()) in DURATION_WORDS:
            continue
        start_h, start_m, start_mark, end_h, end_m, end_mark = match.groups()
        if int(start_h) > 23 or int(end_h) > 23:
            continue
        marker = start_mark or end_mark
        start = _to_24h(int(start_h), int(start_m or 0), start_mark or marker, hint)
        end = _to_24h(int(end_h), int(end_m or 0), end_mark or marker, hint)
        if end <= start:                       # "6 se 8" read as 18:00-08:00
            end += 12 * 60
        return _time_hit(start, end % (24 * 60), match.group(0), "range:clock", match.span())

    # 2. Urdu fractions: "saade aath" (8:30), "paune nau" (8:45).
    for match in _RE_FRACTION.finditer(prepped):
        if _overlaps(match.span(), claimed):
            continue
        word, digits, urdu = match.group(1), match.group(2), match.group(3)
        hour = int(digits) if digits else URDU_NUMBERS[urdu]
        if hour > 23:
            continue
        total = hour * 60 + URDU_FRACTIONS[word]
        return _time_hit(
            _to_24h(total // 60, total % 60, None, hint), None, match.group(0),
            f"fraction:{word}", match.span(),
        )

    # 3. The two irregular ones: "dedh baje" is 1:30, "dhai baje" is 2:30.
    match = _RE_FIXED_TIME.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        hour, minute = URDU_FIXED_TIMES[match.group(1)]
        if _word_after(prepped, match.end()) not in DURATION_WORDS:
            return _time_hit(_to_24h(hour, minute, None, hint), None, match.group(1),
                             f"fixed:{match.group(1)}", match.span())

    # 4. "N baje" / "aath baje".
    for match in _RE_BAJE.finditer(prepped):
        if _overlaps(match.span(), claimed):
            continue
        digits, urdu, minute = match.group(1), match.group(2), match.group(3)
        hour = int(digits) if digits else URDU_NUMBERS[urdu]
        if hour > 23:
            continue
        return _time_hit(_to_24h(hour, int(minute or 0), None, hint), None,
                         match.group(0), "clock:baje", match.span())

    # 5. A digit clock, but only when something makes it a time.
    for match in _RE_CLOCK.finditer(prepped):
        if _overlaps(match.span(), claimed):
            continue
        hour, minute, marker = match.group(1), match.group(2), match.group(3)
        if int(hour) > 23:
            continue
        if _word_after(prepped, match.end()) in DURATION_WORDS:
            continue
        qualified = bool(marker) or minute is not None or daypart is not None
        if not qualified:
            continue
        return _time_hit(_to_24h(int(hour), int(minute or 0), marker, hint), None,
                         match.group(0), "clock:digits", match.span())

    # 6. The daypart window on its own: "shaam", "subah", "tonight".
    if daypart_match:
        start_text, end_text = DAYPART_WINDOWS[daypart]
        start = int(start_text[:2]) * 60 + int(start_text[3:])
        end = int(end_text[:2]) * 60 + int(end_text[3:])
        return _time_hit(start, end, daypart, f"window:{daypart}", daypart_match.span())
    return None


# 6. Budget
# Cue-anchored, always. A bare "2000" is a price, a jersey number, a year and a
# count; only a cue makes it a budget, and inventing one from a naked number is
# how an extractor starts filtering the catalogue for reasons the user cannot
# see. The magnitude split does the rest of the work: a budget needs three
# digits (or a "k"), a clock hour is at most two, so time and money can never
# claim the same token.
BUDGET_MAX_CUES: tuple[str, ...] = (
    "under", "below", "upto", "max", "maximum", "se kam", "se neeche",
    "se niche", "tak", "ke andar", "andar", "se zyada nahi", "not more than",
    "less than",
)
BUDGET_MIN_CUES: tuple[str, ...] = (
    "at least", "atleast", "se zyada", "se upar", "se oper", "minimum",
    "more than", "above", "over",
)
BUDGET_ABOUT_CUES: tuple[str, ...] = (
    "around", "about", "approx", "approximately", "takriban", "lagbhag",
    "aas paas", "ke qareeb", "qareeb", "ke lagbhag",
)
#: No number at all -- "sasta ground dikhao". Returned as op "qualitative" with
#: every amount None, so the dialog manager can offer the cheapest results
#: instead of guessing a ceiling the user never said.
BUDGET_QUALITATIVE_CUES: tuple[str, ...] = (
    "sasta", "cheap", "cheapest", "budget", "affordable", "kifayati",
    "sab se sasta", "kam paise", "kam rate",
)
CURRENCY_WORDS: tuple[str, ...] = ("rs", "rupees", "rupee", "rupay", "rupaye", "pkr")

_RE_BUDGET_RANGE = re.compile(r"\b([0-9]{3,6})\s*(?:se|to|-)\s*([0-9]{3,6})\b")
_RE_AMOUNT_K = re.compile(r"\b([0-9]{1,3})(?:\.([0-9]))?\s*k\b")
_RE_AMOUNT = re.compile(r"\b([0-9]{3,6})\b")
_RE_MAX_CUE = _alt(BUDGET_MAX_CUES)
_RE_MIN_CUE = _alt(BUDGET_MIN_CUES)
_RE_ABOUT_CUE = _alt(BUDGET_ABOUT_CUES)
_RE_QUAL_CUE = _alt(BUDGET_QUALITATIVE_CUES)
_RE_CURRENCY = _alt(CURRENCY_WORDS)

#: How far either side of the number a cue is looked for. Wide enough for
#: "2000 rupay se kam", narrow enough that a cue three clauses away is not read
#: as attached to this number.
_CUE_WINDOW_BEFORE = 24
_CUE_WINDOW_AFTER = 20


def _budget_hit(
    op: str,
    amount: int | None,
    low: int | None,
    high: int | None,
    text: str,
    span: tuple[int, int],
) -> dict[str, Any]:
    return {
        "op": op,
        "amount": amount,
        "min": low,
        "max": high,
        "currency": CURRENCY,
        "text": text,
        "source": "rule",
        "span": [span[0], span[1]],
    }


def extract_budget(
    prepped: str,
    *,
    claimed: Sequence[tuple[int, int]] = (),
) -> dict[str, Any] | None:
    """Resolve a price constraint, or None.

    ``op`` is one of ``max``, ``min``, ``about``, ``range`` and ``qualitative``.
    ``about`` deliberately leaves ``min``/``max`` unset: "around 2500" is not a
    filter, and turning it into 2250-2750 would be a tolerance the user never
    stated. The dialog manager owns that decision.
    """
    match = _RE_BUDGET_RANGE.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        low, high = sorted((int(match.group(1)), int(match.group(2))))
        return _budget_hit("range", None, low, high, match.group(0), match.span())

    candidates: list[tuple[tuple[int, int], int, str]] = []
    for hit in _RE_AMOUNT_K.finditer(prepped):
        whole, tenth = int(hit.group(1)), hit.group(2)
        value = whole * 1000 + (int(tenth) * 100 if tenth else 0)
        candidates.append((hit.span(), value, hit.group(0)))
    for hit in _RE_AMOUNT.finditer(prepped):
        candidates.append((hit.span(), int(hit.group(1)), hit.group(0)))
    candidates.sort(key=lambda item: item[0][0])

    for span, value, text in candidates:
        if _overlaps(span, claimed):
            continue
        before = prepped[max(0, span[0] - _CUE_WINDOW_BEFORE):span[0]]
        after = prepped[span[1]:span[1] + _CUE_WINDOW_AFTER]
        window = f"{before} {after}"
        if _RE_MAX_CUE.search(window):
            return _budget_hit("max", value, None, value, text, span)
        if _RE_MIN_CUE.search(window):
            return _budget_hit("min", value, value, None, text, span)
        if _RE_ABOUT_CUE.search(window):
            return _budget_hit("about", value, None, None, text, span)
        if _RE_CURRENCY.search(window):
            # "rs 2500 ka ground" -- an amount with a currency and no comparator.
            # Read as approximate, not as a ceiling: the user stated a price, not
            # a limit, and asking is cheaper than filtering wrongly.
            return _budget_hit("about", value, None, None, text, span)

    match = _RE_QUAL_CUE.search(prepped)
    if match and not _overlaps(match.span(), claimed):
        return _budget_hit("qualitative", None, None, None, match.group(1), match.span())
    return None


# 7. Areas -- the gazetteer
CITY_ALIASES: dict[str, str] = {
    "islamabad": "Islamabad", "isb": "Islamabad", "isl": "Islamabad",
    "isd": "Islamabad", "capital": "Islamabad",
    "rawalpindi": "Rawalpindi", "pindi": "Rawalpindi", "rwp": "Rawalpindi",
    "rpi": "Rawalpindi",
}
_RE_CITY = _alt(CITY_ALIASES)

# Islamabad/Rawalpindi sector token, for a sector nobody seeded ("g-13", "i-10").
# The letter range matches reco_features._RE_SECTOR (A-I is what the twin cities
# use). The spaced form ("f 11") is accepted for every letter except "a"
# and "i", which are English words: "i 8 baje" is "I ... 8 o'clock" far more often
# than it is sector I-8, and "a 5" is never sector A-5. Dashed and joined forms
# ("i-8", "i8") work for all letters, and that is how a sector is typed.
_RE_SECTOR = re.compile(r"\b([a-i])\s*(-?)\s*([0-9]{1,2})(?:/[0-9]{1,2})?\b")
_SPACED_SECTOR_BLOCKED: tuple[str, ...] = ("a", "i")


@dataclass(frozen=True)
class GazetteerEntry:
    """One phrase the extractor recognises as a place."""

    surface: str            # prepped form, what the regex matches
    area: str               # canonical token, e.g. "F-11", "BAHRIA-TOWN"
    city: str | None        # when the source knew it
    origin: str             # "slot-vocab" | "artifact" | "override"


@dataclass(frozen=True)
class Gazetteer:
    entries: tuple[GazetteerEntry, ...]
    pattern: re.Pattern[str]
    index: dict[str, GazetteerEntry]
    sources: tuple[str, ...]

    def find(self, prepped: str) -> tuple[GazetteerEntry, tuple[int, int]] | None:
        match = self.pattern.search(prepped)
        if not match:
            return None
        return self.index[match.group(1)], match.span()


def _area_canonical(surface: str) -> str:
    """Canonical area token for a surface phrase.

    Reuses :func:`app.core.reco_features.area_token` so an area extracted here and
    a zone fitted by the recommender agree by construction; falls back to an
    upper-hyphen slug for a named place with no scheme and no sector
    ("stadium road" -> "STADIUM-ROAD"), which is the same shape ZONE_SCHEMES uses.
    """
    token = reco_features.area_token(surface)
    if token:
        return token
    return re.sub(r"[^A-Z0-9]+", "-", surface.upper()).strip("-")


def load_venue_areas(model_path: Path | None = None) -> list[tuple[str, str | None]]:
    """(area surface, city) pairs from the recommender artifact's venue snapshot.

    This is the spec's "gazetteer built from venues.city + venues.area at
    startup" without a database: the catalogue is already inside
    ``models/reco_latest.joblib``, put there by ``build_reco.py`` from Node's
    read-only export. Returns [] and stays silent when the artifact is absent --
    the seed vocabulary alone is a working gazetteer.
    """
    path = Path(model_path) if model_path else (config.MODEL_DIR / "reco_latest.joblib")
    if not path.exists():
        return []
    try:
        import joblib

        artifact = joblib.load(path)
        venues = getattr(artifact.get("model"), "venues", None) or []
    except Exception:                   # pragma: no cover - a bad artifact is not fatal here
        return []

    found: list[tuple[str, str | None]] = []
    for venue in venues:
        if not isinstance(venue, dict):
            continue
        city = venue.get("city") or None
        address = str(venue.get("address") or "")
        if not address:
            continue
        # The first comma-separated part of a seeded address is the area as a
        # user types it ("F-7 Markaz, Islamabad"), so it becomes a surface form.
        head = address.split(",")[0].strip()
        if head:
            found.append((head, city))
        token = reco_features.area_token(address)
        if token:
            found.append((token.replace("-", " "), city))
    return found


def load_area_overrides(path: Path | None = None) -> list[tuple[str, str | None]]:
    """Optional ``data/assistant/areas.txt``: one phrase per line, ``#`` comments.

    Exists so a venue added after the last export can be recognised without a
    retrain or a rebuild. One phrase per line, with an optional city after a
    pipe: ``F-6 Markaz | Islamabad``, or just ``F-6 Markaz``.
    """
    target = Path(path) if path else (config.DATA_DIR / "assistant" / "areas.txt")
    if not target.exists():
        return []
    out: list[tuple[str, str | None]] = []
    for line in target.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split("|")]
        out.append((parts[0], parts[1] if len(parts) > 1 and parts[1] else None))
    return out


def seed_area_phrases() -> list[str]:
    """The areas the CLASSIFIER was trained on -- ``SLOT_VOCAB["area"]``, every bucket.

    Seeding from the training vocabulary rather than from the catalogue alone is
    deliberate: serving must recognise at least what training taught, or a
    perfectly classified utterance loses its slot for a reason no metric shows.
    """
    return [value for bucket in SLOT_VOCAB["area"].values() for value in bucket]


def build_gazetteer(
    *,
    extra: Iterable[tuple[str, str | None]] = (),
    use_artifact: bool = True,
    use_overrides: bool = True,
) -> Gazetteer:
    """Assemble the place lexicon. Seed first, then catalogue, then overrides."""
    collected: dict[str, GazetteerEntry] = {}
    sources: list[str] = []

    def add(surface: str, city: str | None, origin: str) -> None:
        key = prep(surface)
        if not key or len(key) < 2:
            return
        existing = collected.get(key)
        if existing and (existing.city or not city):
            return
        collected[key] = GazetteerEntry(key, _area_canonical(surface), city, origin)

    for phrase in seed_area_phrases():
        add(phrase, None, "slot-vocab")
    sources.append("slot-vocab")

    for scheme_needle, token in reco_features.ZONE_SCHEMES:
        add(scheme_needle, None, "slot-vocab")

    if use_artifact:
        venue_areas = load_venue_areas()
        for surface, city in venue_areas:
            add(surface, city, "artifact")
        if venue_areas:
            sources.append("artifact")
    if use_overrides:
        overrides = load_area_overrides()
        for surface, city in overrides:
            add(surface, city, "override")
        if overrides:
            sources.append("override")
    for surface, city in extra:
        add(surface, city, "override")

    entries = tuple(sorted(collected.values(), key=lambda e: (-len(e.surface), e.surface)))
    pattern = re.compile(
        r"\b(" + "|".join(re.escape(entry.surface) for entry in entries) + r")\b"
    ) if entries else re.compile(r"(?!x)x")
    return Gazetteer(entries, pattern, {e.surface: e for e in entries}, tuple(sources))


@lru_cache(maxsize=1)
def default_gazetteer() -> Gazetteer:
    """Process-wide gazetteer, built once. ``cache_clear()`` after a reco refresh."""
    return build_gazetteer()


def extract_area(
    prepped: str,
    *,
    gazetteer: Gazetteer | None = None,
    claimed: Sequence[tuple[int, int]] = (),
) -> dict[str, Any] | None:
    """Resolve a place: a gazetteer phrase first, then a bare sector token.

    ``zone`` is the recommender's own key format (``"ISLAMABAD:F-11"``) so a
    parsed area can be handed straight to a reco call. Node may recompute it with
    the authenticated user's city when the utterance did not name one.
    """
    gaz = gazetteer or default_gazetteer()
    city_match = _RE_CITY.search(prepped)
    city = CITY_ALIASES[city_match.group(1)] if city_match else None

    hit = gaz.find(prepped)
    if hit and not _overlaps(hit[1], claimed):
        entry, span = hit
        return _area_hit(entry.area, entry.city or city, entry.surface,
                         f"gazetteer:{entry.origin}", span)

    for match in _RE_SECTOR.finditer(prepped):
        if _overlaps(match.span(), claimed):
            continue
        letter, dash, number = match.group(1), match.group(2), match.group(3)
        if " " in match.group(0) and not dash and letter in _SPACED_SECTOR_BLOCKED:
            continue
        sector = int(number)
        if not 1 <= sector <= 20:       # the twin cities stop well short of 20
            continue
        return _area_hit(f"{letter.upper()}-{sector}", city, match.group(0),
                         "sector", match.span())

    if city_match:
        # A city with no area is still a real constraint: "islamabad me ground".
        return _area_hit(None, city, city_match.group(1), "city", city_match.span())
    return None


def _area_hit(
    area: str | None,
    city: str | None,
    text: str,
    rule: str,
    span: tuple[int, int],
) -> dict[str, Any]:
    zone = reco_features.zone_of(area or text, city)
    if area and zone.endswith(f":{reco_features.ZONE_AREA_ANY}"):
        zone = zone[: -len(reco_features.ZONE_AREA_ANY)] + area
    return {
        "area": area,
        "city": city,
        "zone": zone,
        "text": text,
        "rule": rule,
        "source": "rule",
        "span": [span[0], span[1]],
    }


# 8. The contract: five keys, in one pass
def extract(
    text: Any,
    *,
    now: datetime | None = None,
    gazetteer: Gazetteer | None = None,
) -> dict[str, Any]:
    """Resolve every slot in one utterance. Always returns all of :data:`ENTITY_KEYS`.

    Order is not cosmetic. Each extractor CLAIMS the character span it consumed
    and later ones skip claimed spans, which is what stops the three real
    collisions in this domain:

      * "g-8/2" is an area, not the 8th of February -- area runs first.
      * "30-08-2026" is a date, not 08:00 to 20:00 -- date runs before time.
      * "2500" is money and "8" is an hour -- the magnitude split separates them,
        and the claim makes it certain.

    ``now`` is injectable so every date assertion in ``training/test_nlu.py`` is
    deterministic; production passes nothing and gets Asia/Karachi's today.
    """
    prepped = prep(text)
    claimed: list[tuple[int, int]] = []
    resolved: dict[str, Any] = {}

    for key, extractor in (
        ("area", lambda: extract_area(prepped, gazetteer=gazetteer, claimed=claimed)),
        ("date", lambda: extract_date(prepped, now=now, claimed=claimed)),
        ("time", lambda: extract_time(prepped, now=now, claimed=claimed)),
        ("budget", lambda: extract_budget(prepped, claimed=claimed)),
    ):
        hit = extractor()
        resolved[key] = hit
        if hit:
            claimed.append((hit["span"][0], hit["span"][1]))

    resolved["sport"] = extract_sport(prepped)
    return {key: resolved[key] for key in ENTITY_KEYS}


# 9. Fingerprint, and what /nlu/spec publishes
_FINGERPRINTED_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("keep", _KEEP), ("thousands", _THOUSANDS), ("elongation", _ELONG),
    ("iso_date", _RE_ISO_DATE), ("dmy_slash", _RE_DMY_SLASH),
    ("dmy_dash", _RE_DMY_DASH), ("day_month", _RE_DAY_MONTH),
    ("month_day", _RE_MONTH_DAY), ("days_later", _RE_DAYS_LATER),
    ("date_fragment", _RE_DATE_FRAGMENT), ("clock", _RE_CLOCK), ("baje", _RE_BAJE),
    ("fraction", _RE_FRACTION), ("range", _RE_RANGE),
    ("budget_range", _RE_BUDGET_RANGE), ("amount_k", _RE_AMOUNT_K),
    ("amount", _RE_AMOUNT), ("sector", _RE_SECTOR),
)


def _fingerprint_payload() -> dict[str, Any]:
    """Every RULE, and nothing that is runtime data.

    The gazetteer's seed and the artifact's venue list are deliberately excluded:
    a venue opening in G-13 must not mark a trained intent artifact incompatible,
    while moving the "shaam" window or changing a budget cue must. That is the
    same reasoning ``intent_spec`` uses to keep its label and dataset
    fingerprints apart.
    """
    return {
        "version": ENTITY_SPEC_VERSION,
        "keys": list(ENTITY_KEYS),
        "timezone": TZ_NAME,
        "currency": CURRENCY,
        "relative_days": RELATIVE_DAYS,
        "day_and_time": DAY_AND_TIME,
        "weekdays": WEEKDAYS,
        "next_cues": list(NEXT_CUES),
        "week_ahead": list(WEEK_AHEAD_CUES),
        "weekend": list(WEEKEND_CUES),
        "months": MONTHS,
        "sports": {k: list(v) for k, v in SPORT_WORDS.items()},
        "sport_variants": SPORT_VARIANTS,
        "formats": list(FORMAT_WORDS),
        "dayparts": {k: list(v) for k, v in DAYPART_WINDOWS.items()},
        "am_dayparts": list(_AM_DAYPARTS),
        "fractions": URDU_FRACTIONS,
        "fixed_times": {k: list(v) for k, v in URDU_FIXED_TIMES.items()},
        "urdu_numbers": URDU_NUMBERS,
        "duration_words": list(DURATION_WORDS),
        "time_cues": list(_TIME_CUES),
        "budget_max": list(BUDGET_MAX_CUES),
        "budget_min": list(BUDGET_MIN_CUES),
        "budget_about": list(BUDGET_ABOUT_CUES),
        "budget_qualitative": list(BUDGET_QUALITATIVE_CUES),
        "currency_words": list(CURRENCY_WORDS),
        "cue_window": [_CUE_WINDOW_BEFORE, _CUE_WINDOW_AFTER],
        "cities": CITY_ALIASES,
        "spaced_sector_blocked": list(_SPACED_SECTOR_BLOCKED),
        "patterns": {name: pattern.pattern for name, pattern in _FINGERPRINTED_PATTERNS},
        "text_contract": nlu_text.NLU_TEXT_SPEC_VERSION,
    }


def entity_fingerprint() -> str:
    """16 hex chars over the rule tables. Stamped into the intent artifact."""
    blob = json.dumps(
        _fingerprint_payload(), sort_keys=True, ensure_ascii=False, separators=(",", ":")
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def describe() -> dict[str, Any]:
    """Public shape of the extractor, for ``GET /nlu/spec`` and the model card."""
    gaz = default_gazetteer()
    return {
        "specVersion": ENTITY_SPEC_VERSION,
        "fingerprint": entity_fingerprint(),
        "approach": "rule-based (regex + lexicon + calendar); no model, no training",
        "keys": list(ENTITY_KEYS),
        "timezone": TZ_NAME,
        "currency": CURRENCY,
        "textContract": {
            "version": nlu_text.NLU_TEXT_SPEC_VERSION,
            "fingerprint": nlu_text.nlu_text_fingerprint(),
            "note": "shared spelling tables; digits preserved here, masked there",
        },
        "dateparser": {"available": HAVE_DATEPARSER, "role": "fallback on a date fragment only"},
        "dayparts": {name: list(window) for name, window in DAYPART_WINDOWS.items()},
        "sports": sorted(SPORT_WORDS),
        "budgetOps": ["max", "min", "about", "range", "qualitative"],
        "gazetteer": {
            "areas": len(gaz.entries),
            "sources": list(gaz.sources),
            "cities": sorted(set(CITY_ALIASES.values())),
        },
        "counts": {
            "relativeDays": len(RELATIVE_DAYS),
            "weekdays": len(WEEKDAYS),
            "months": len(MONTHS),
            "urduNumbers": len(URDU_NUMBERS),
            "budgetCues": len(BUDGET_MAX_CUES) + len(BUDGET_MIN_CUES)
            + len(BUDGET_ABOUT_CUES) + len(BUDGET_QUALITATIVE_CUES),
        },
    }


# 10. Self-check
#: Friday. Every date assertion below is relative to it, so the pinned answers
#: are stable in 2027 -- a self-check whose answers move with the wall clock is
#: not a check. A Friday on purpose: it makes "friday ko" (today) and "next
#: friday" (+7) two different pinned cases instead of one.
FIXED_NOW = datetime(2026, 8, 28, 15, 0, tzinfo=KARACHI)

#: (utterance, {dotted path: expected}). A path that is a bare key with value
#: None asserts the whole slot stayed empty -- the false-positive half of the
#: check, which matters more than the hits: a wrong slot books a wrong ground, an
#: empty one asks a question.
_CASES: tuple[tuple[str, dict[str, Any]], ...] = (
    ("KAL SHAAAAM F-11 me futbal grownd dikha do",
     {"date.iso": "2026-08-29", "time.start": "18:00", "time.end": "21:00",
      "sport.value": "football", "area.area": "F-11"}),
    ("parso subah 8 baje cricket ground chahiye",
     {"date.iso": "2026-08-30", "time.start": "08:00", "sport.value": "cricket"}),
    ("mujhe 3000 se kam wala turf chahiye",
     {"budget.op": "max", "budget.max": 3000, "time": None}),
    ("3k tak ka ground chahiye", {"budget.op": "max", "budget.max": 3000}),
    # Locks the digit-run bug: an elongation rule that squeezed "000" made
    # this 100 and the 3000 cases 300.
    ("10000 tak ka ground", {"budget.op": "max", "budget.max": 10000}),
    ("aaj raat 10 baje", {"date.iso": "2026-08-28", "time.start": "22:00"}),
    ("next friday shaam", {"date.iso": "2026-09-04", "time.start": "18:00"}),
    ("friday ko booking", {"date.iso": "2026-08-28"}),
    ("this weekend cricket",
     {"date.iso": "2026-08-29", "date.endIso": "2026-08-30", "sport.value": "cricket"}),
    ("30 august 8pm", {"date.iso": "2026-08-30", "time.start": "20:00"}),
    ("g-8/2 me tapeball match",
     {"area.area": "G-8", "sport.value": "cricket", "sport.variant": "tapeball",
      "date": None}),
    ("saade aath baje", {"time.start": "20:30"}),
    ("2 hours ke liye ground chahiye", {"time": None, "budget": None}),
    ("5v5 futsal", {"sport.value": "futsal", "time": None, "budget": None}),
    ("shaam 6 se 8 tak", {"time.start": "18:00", "time.end": "20:00"}),
    ("bahria town me sasta ground",
     {"area.area": "BAHRIA-TOWN", "budget.op": "qualitative"}),
    ("itwar ko islamabad me cricket",
     {"date.iso": "2026-08-30", "area.city": "Islamabad"}),
    ("8 baje", {"time.start": "20:00"}),
    ("subah 8 baje", {"time.start": "08:00"}),
    ("paune nau baje", {"time.start": "20:45"}),
    ("dopahar", {"time.start": "12:00", "time.end": "16:00"}),
    ("kal 2000 se 3000 ke darmiyan",
     {"date.iso": "2026-08-29", "budget.op": "range", "budget.min": 2000,
      "budget.max": 3000}),
    ("agle hafte", {"date.iso": "2026-09-04"}),
    ("3 din baad", {"date.iso": "2026-08-31", "time": None}),
    ("dedh baje", {"time.start": "13:30"}),
    ("sun bhai kal ka rate kya hai", {"date.iso": "2026-08-29"}),
    ("wallet balance kitna hai",
     {"date": None, "time": None, "sport": None, "area": None, "budget": None}),
    ("f-11 markaz me football 3000 tak kal shaam",
     {"area.area": "F-11", "date.iso": "2026-08-29", "time.start": "18:00",
      "budget.max": 3000, "sport.value": "football"}),
    ("rs 2500 ka ground", {"budget.op": "about", "budget.amount": 2500}),
    ("30/08/2026 ko", {"date.iso": "2026-08-30"}),
    ("i-8 me cricket", {"area.area": "I-8", "sport.value": "cricket"}),
)


def _dig(result: dict[str, Any], path: str) -> Any:
    node: Any = result
    for part in path.split("."):
        if node is None:
            return None
        node = node.get(part) if isinstance(node, dict) else None
    return node


def self_check(verbose: bool = False) -> int:
    """0 when every pinned case holds. Run before every commit."""
    failures: list[str] = []
    checks = 0

    for utterance, expectations in _CASES:
        parsed = extract(utterance, now=FIXED_NOW)
        if set(parsed) != set(ENTITY_KEYS):
            failures.append(f"key contract broken for {utterance!r}: {sorted(parsed)}")
        for path, expected in expectations.items():
            checks += 1
            actual = _dig(parsed, path)
            if actual != expected:
                failures.append(f"{utterance!r}: {path} -> {actual!r}, expected {expected!r}")
            elif verbose:
                print(f"  ok  {utterance!r:52.52} {path} = {actual!r}")

    # The wire has to survive json.dumps: a date object or a numpy int here would
    # 500 the router at serialisation time, not at extraction time.
    checks += 1
    try:
        json.dumps([extract(text, now=FIXED_NOW) for text, _ in _CASES])
    except TypeError as exc:
        failures.append(f"result is not JSON-serialisable: {exc}")

    # prep must be idempotent, or the gazetteer's keys (built with prep) stop
    # matching text prepped at request time.
    checks += 1
    unstable = [text for text, _ in _CASES if prep(prep(text)) != prep(text)]
    if unstable:
        failures.append(f"prep is not idempotent: {unstable[:3]}")

    # Every seeded area must be findable, or serving knows less than training.
    checks += 1
    gaz = default_gazetteer()
    missing = [phrase for phrase in seed_area_phrases() if not gaz.find(prep(phrase))]
    if missing:
        failures.append(f"seeded areas not matched: {missing}")

    fingerprint = entity_fingerprint()
    if failures:
        print(f"FAIL  {len(failures)} of {checks} checks, {ENTITY_SPEC_VERSION} / {fingerprint}")
        for line in failures:
            print(f"  - {line}")
        return 1
    print(f"PASS  {checks} checks, {ENTITY_SPEC_VERSION} / {fingerprint}")
    print(
        f"      {len(gaz.entries)} area phrases from {'+'.join(gaz.sources) or 'seed only'}, "
        f"dateparser {'available' if HAVE_DATEPARSER else 'MISSING (fallback disabled)'}"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rule-based NLU entity extraction")
    parser.add_argument("--self-check", action="store_true", help="run the pinned cases")
    parser.add_argument("--verbose", action="store_true", help="print every assertion")
    parser.add_argument("--parse", metavar="TEXT", help="extract from one utterance")
    parser.add_argument("--now", metavar="ISO", help="fix today, e.g. 2026-08-28T15:00")
    parser.add_argument("--spec", action="store_true", help="print describe() as JSON")
    args = parser.parse_args(argv)

    if args.spec:
        print(json.dumps(describe(), indent=2, ensure_ascii=False))
        return 0
    if args.parse:
        moment = datetime.fromisoformat(args.now).replace(tzinfo=KARACHI) if args.now else None
        print(json.dumps(
            {"text": args.parse, "prepped": prep(args.parse),
             "entities": extract(args.parse, now=moment)},
            indent=2, ensure_ascii=False,
        ))
        return 0
    return self_check(verbose=args.verbose)


__all__ = [
    "ENTITY_SPEC_VERSION", "ENTITY_KEYS", "TZ_NAME", "KARACHI", "CURRENCY",
    "prep", "extract", "extract_date", "extract_time", "extract_sport",
    "extract_area", "extract_budget", "today_in_karachi",
    "Gazetteer", "GazetteerEntry", "build_gazetteer", "default_gazetteer",
    "seed_area_phrases", "load_venue_areas", "load_area_overrides",
    "entity_fingerprint", "describe", "warm", "self_check", "main",
    "HAVE_DATEPARSER", "DAYPART_WINDOWS", "FIXED_NOW",
]


if __name__ == "__main__":
    raise SystemExit(main())
