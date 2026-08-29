"""Unit tests for the S.6 assistant NLU: intent classifier + rule entity extractor.

WHY THIS FILE EXISTS
--------------------
Wave B ships two halves that fail in completely different ways. The classifier
fails STATISTICALLY -- it is 0.87 on validation and 0.62 on the exam, and no test
can assert that a learned model gets a particular utterance right without turning
a metric into a lie. The extractor fails MECHANICALLY -- "kal" is either tomorrow
or it is a bug, and that IS assertable, on every commit, in milliseconds.

So the two halves are tested differently on purpose:

  * The extractor is pinned utterance by utterance, against a FROZEN clock
    (`entities.FIXED_NOW`, 2026-08-28 15:00 Asia/Karachi). A date test that used
    the real clock would pass today and fail on Saturday, which is worse than no
    test: it teaches the team to ignore a red suite.
  * The classifier is tested for CONTRACT and BEHAVIOUR, not for accuracy: that
    its label set is exactly `intent_spec.INTENTS`, that its probabilities are a
    distribution, that the abstain floor in the artifact is the one the router
    applies, and that the three refusal paths refuse. Accuracy lives in
    `reports/intent_metrics.json` and the model card, measured once, on data this
    file never touches.

The exam (`data/assistant/assistant_test.csv`) is not read here at all. A test
suite that asserted on exam rows would be a slow way of tuning on the exam.

RUN IT
------
    ./.venv/Scripts/python.exe training/test_nlu.py          # standalone
    ./.venv/Scripts/python.exe training/test_nlu.py -k date  # filter
    ./.venv/Scripts/python.exe -m pytest training/test_nlu.py -q   # if installed

Standalone and pytest both work, deliberately: there is no pytest in this venv
(`requirements.txt` does not pin one, because the serving image must not carry a
test runner), and "run the tests before every commit" has to be a command that
works on the machine the commit is made from. Plain `assert`, no fixtures, no
parametrize -- anything pytest-only would break the standalone path.

Exit code 0 = every test passed or skipped; 1 = at least one failed.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# Run from anywhere: `training/test_nlu.py`, `ml-service/`, or a CI step that
# cd's somewhere else entirely. `app` is a package under the service root.
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except Exception:  # pragma: no cover - a plain file object is fine
        pass

from app.core import entities, intent_spec, nlu_text  # noqa: E402

#: Every date/time assertion in this file is relative to this instant, never to
#: the wall clock. Friday, 2026-08-28, 15:00 Asia/Karachi -- chosen in entities.py
#: because it is a WEEKDAY AFTERNOON: "kal" is an ordinary tomorrow, "is weekend"
#: is still ahead, "shaam" has not passed yet, and "friday ko" is today, which is
#: the one same-day weekday case that catches an off-by-one in the weekday rule.
NOW = entities.FIXED_NOW


class Skipped(Exception):
    """A test that cannot run here (no artifact, no optional dependency)."""


def skip(reason: str) -> None:
    """Skip in pytest's language when pytest is present, in ours when it is not."""
    try:
        import pytest
    except ModuleNotFoundError:
        raise Skipped(reason) from None
    pytest.skip(reason)


_ENTRY: list = []


def model_entry():
    """The loaded intent artifact, or a skip. Loaded once for the whole run.

    Going through `registry.get` rather than `joblib.load` is the point: it applies
    the same spec-version and fingerprint gates the service applies at boot, so an
    incompatible artifact shows up here as a SKIP with the registry's own reason
    instead of as thirty confusing assertion failures.
    """
    from app.core.registry import registry
    if not _ENTRY:
        _ENTRY.append(registry.get("intent"))
    entry = _ENTRY[0]
    if not entry.is_ready:
        skip(f"intent artifact not loaded: {entry.reason}")
    return entry


def ext(text: str, key: str | None = None):
    """`entities.extract` at the frozen instant. `key` returns that one slot."""
    slots = entities.extract(text, now=NOW)
    return slots if key is None else slots[key]


def parse(text: str, **kwargs):
    """One `/nlu/parse` through the router FUNCTION -- no HTTP, no uvicorn.

    The route is a plain function over a pydantic model, so calling it directly
    tests everything the endpoint does (abstention, entity attachment, timing
    fields) without needing a server, a port, or an API key. The HTTP layer itself
    is FastAPI's to test, and TESTING.md 4.18 exercises it by hand.
    """
    from app.routers import nlu
    model_entry()
    return nlu.parse(nlu.ParseRequest(text=text, **kwargs))


# ─────────────────────────────────────────────────────────────────────────────
# 1. Contracts -- the frozen specs and the artifact's agreement with them
# ─────────────────────────────────────────────────────────────────────────────


def test_nlu_text_self_check_passes():
    """The frozen normaliser's own 17 invariants (idempotence, Roman Urdu map)."""
    checks = nlu_text.self_check()
    assert checks >= 17, f"nlu_text.self_check() ran only {checks} checks"


def test_intent_spec_self_check_passes():
    """14 receipts over the label set, the catalogue and the corpus budgets."""
    receipts = intent_spec.self_check()
    assert len(receipts) >= 14, f"only {len(receipts)} intent_spec receipts"
    assert all(isinstance(name, str) and detail for name, detail in receipts)


def test_entities_self_check_passes():
    """73 rule checks. Returns a shell exit code, not a count -- 0 is pass."""
    assert entities.self_check() == 0, "entities.self_check() reported a failure"


def test_artifact_labels_are_exactly_the_spec_intents():
    """The 15 classes the model can emit must be the 15 Node routes on.

    This is the check that turns "keep the label set in sync" into something that
    fails loudly. A class the dialog manager has never heard of becomes a silent
    no-op branch; a class the model can no longer emit becomes dead code.
    """
    entry = model_entry()
    assert sorted(entry.estimator.classes_) == sorted(intent_spec.INTENTS)


def test_artifact_fingerprints_match_the_live_modules():
    """The two GATED fingerprints, asserted here as well as in the registry.

    `intentSpecFingerprint` covers the labels, `nluTextSpecFingerprint` the
    normaliser: change either and the artifact's features stop meaning what they
    meant when it was fitted. The dataset and entity fingerprints are deliberately
    NOT asserted -- they are provenance, and `registry._intent_verify` documents
    why a venue opening in G-13 must not brick a working assistant.
    """
    meta = model_entry().meta
    assert meta["intentSpecFingerprint"] == intent_spec.intent_spec_fingerprint()
    assert meta["nluTextSpecFingerprint"] == nlu_text.nlu_text_fingerprint()


def test_artifact_declares_the_abstain_floor_the_router_applies():
    """0.45 from the wave spec, carried BY the artifact, not hard-coded in serving.

    S.4 stranded a 0.90 sentiment threshold in a constant no artifact knew about.
    Here the number ships with the model that was validated at it, and the router
    only supplies a default when the artifact declares none.
    """
    from app.routers import nlu
    entry = model_entry()
    declared = entry.meta.get("confidenceThreshold")
    assert declared == 0.45, f"artifact threshold is {declared!r}, expected 0.45"
    assert nlu._threshold(entry) == declared
    assert nlu.MIN_THRESHOLD <= declared <= nlu.MAX_THRESHOLD


def test_every_label_has_a_group_and_a_gloss():
    """The catalogue `/nlu/spec` publishes must cover the label set with no gaps."""
    catalogued = {row[0] for row in intent_spec.INTENT_CATALOG}
    assert catalogued == set(intent_spec.INTENTS)
    for name, group, gloss, sibling in intent_spec.INTENT_CATALOG:
        assert group in intent_spec.INTENT_GROUPS, f"{name}: unknown group {group}"
        assert gloss.strip() and sibling != name


def test_fallback_intent_is_a_real_class():
    """`out_of_scope` is a TRAINED label, not a sentinel the router invents."""
    from app.routers import nlu
    entry = model_entry()
    assert nlu.FALLBACK_INTENT in intent_spec.INTENTS
    assert nlu._fallback_label(entry, list(entry.estimator.classes_)) == nlu.FALLBACK_INTENT


# ─────────────────────────────────────────────────────────────────────────────
# 2. Dates -- every form the corpus and the exam actually contain
# ─────────────────────────────────────────────────────────────────────────────


def test_date_kal_is_tomorrow():
    """The single most common date word in the corpus. Urdu "kal" is ambiguous in
    the language (yesterday OR tomorrow); in a BOOKING request it is always the
    future one, and that reading is the rule."""
    assert ext("kal ka slot", "date")["iso"] == "2026-08-29"


def test_date_parso_is_the_day_after_tomorrow():
    assert ext("parso ground chahiye", "date")["iso"] == "2026-08-30"


def test_date_aaj_and_its_spellings_are_today():
    """"aaj", "aj", "ajj" all reach the same rule through the normaliser."""
    for surface in ("aaj", "aj", "ajj"):
        got = ext(f"{surface} shaam", "date")
        assert got and got["iso"] == "2026-08-28", f"{surface!r} -> {got}"


def test_date_is_weekend_is_a_two_day_range():
    """A range, not a point: Node offers Saturday AND Sunday slots for it."""
    got = ext("is weekend match", "date")
    assert (got["iso"], got["endIso"]) == ("2026-08-29", "2026-08-30")
    assert got["rule"] == "range:weekend"


def test_date_weekday_naming_today_stays_today():
    """NOW is a Friday, so "friday ko" is today -- not seven days out.

    The off-by-one that "next occurrence of weekday W" invites: implemented with a
    strictly-future search, "friday ko" on a Friday silently becomes 2026-09-04 and
    every user who books on the day of gets next week.
    """
    assert ext("friday ko khelna hai", "date")["iso"] == "2026-08-28"


def test_date_next_weekday_skips_to_the_following_week():
    """"next monday" is Monday the 31st; the bare weekday rule agrees with it."""
    assert ext("next monday", "date")["iso"] == "2026-08-31"
    assert ext("monday ko", "date")["iso"] == "2026-08-31"


def test_date_roman_urdu_weekdays_resolve():
    """somwar/mangal/jumma are how the corpus writes weekdays in Roman Urdu."""
    assert ext("somwar ko", "date")["iso"] == "2026-08-31"
    assert ext("jumma ko", "date")["iso"] == "2026-08-28"


def test_date_slash_form_is_day_month_not_month_day():
    """"30/08" is 30 August. The DMY reading is Pakistan's, and it is OURS in code
    rather than dateparser's version-dependent default -- the reason the dependency
    is pinned and consulted last."""
    got = ext("30/08 ko booking", "date")
    assert got["iso"] == "2026-08-30" and got["rule"] == "absolute:dmy"


def test_date_offset_in_days():
    assert ext("2 din baad", "date")["iso"] == "2026-08-30"


def test_date_next_week_offset():
    assert ext("agle hafte", "date")["iso"] == "2026-09-04"


def test_date_past_phrases_are_not_a_booking_date():
    """"pichle hafte" is a past window: no booking date, so no slot. Guessing a
    date here would put a user's Friday game in a week that has already gone."""
    assert ext("pichle hafte kya hua", "date") is None


def test_date_follows_the_now_it_is_given():
    """Two different `now` values, two different answers -- proof the extractor
    reads the injected instant and not a hidden `datetime.now()`. This is what
    makes `/nlu/parse`'s `now` override honest for a client in another timezone."""
    import datetime as dt
    other = dt.datetime(2026, 12, 25, 9, 0, tzinfo=NOW.tzinfo)
    assert entities.extract("kal", now=NOW)["date"]["iso"] == "2026-08-29"
    assert entities.extract("kal", now=other)["date"]["iso"] == "2026-12-26"


# ─────────────────────────────────────────────────────────────────────────────
# 3. Times -- where a Pakistani football booking breaks a naive clock parser
# ─────────────────────────────────────────────────────────────────────────────


def test_time_bare_baje_takes_the_evening_reading():
    """"6 baje" is 18:00. Nobody books a five-a-side for six in the morning.

    This is the single highest-value rule in the time extractor and the one a
    library gets wrong: a generic parser resolves "6" to 06:00 and the user is
    offered a dawn slot for the match they meant to play after work.
    """
    got = ext("6 baje", "time")
    assert got["start"] == "18:00" and got["rule"] == "clock:baje"


def test_time_daypart_overrides_the_evening_default():
    """An explicit daypart wins: "subah 7 baje" is 07:00, "raat 10" is 22:00."""
    assert ext("subah 7 baje", "time")["start"] == "07:00"
    assert ext("raat 10 baje", "time")["start"] == "22:00"
    assert ext("shaam 6 baje", "time")["start"] == "18:00"


def test_time_english_am_pm_and_minutes():
    assert ext("8 pm", "time")["start"] == "20:00"
    assert ext("8:30 pm slot", "time")["start"] == "20:30"


def test_time_range_becomes_start_and_end():
    """"7 se 9" is a two-hour window the venue must be free for, not a start time."""
    got = ext("sham 7 se 9", "time")
    assert (got["start"], got["end"]) == ("19:00", "21:00")
    assert got["rule"] == "range:clock"


def test_time_daypart_alone_is_a_window():
    """No clock at all: "dopahar" is a searchable window, and Node treats a window
    as "show me what is free in it" rather than as a slot to book."""
    got = ext("dopahar khelna hai", "time")
    assert (got["start"], got["end"]) == ("12:00", "16:00")
    assert got["rule"].startswith("window:")


def test_time_twelve_baje_is_noon_not_midnight():
    """The 12-hour clock's other trap. Midnight is not a bookable ground slot."""
    assert ext("12 baje", "time")["start"] == "12:00"


def test_time_does_not_read_a_date_offset_as_a_clock():
    """"2 din baad" has a digit in it and is NOT 02:00. The date rule claims the
    span first, and the time rule respects the claim -- the mechanism that keeps
    two number-hungry rules from fighting over the same characters."""
    slots = ext("2 din baad shaam 7 baje")
    assert slots["date"]["iso"] == "2026-08-30"
    assert slots["time"]["start"] == "19:00"


# ─────────────────────────────────────────────────────────────────────────────
# 4. Sports -- the lexicon is the platform's five, on purpose
# ─────────────────────────────────────────────────────────────────────────────


def test_sport_canonical_names():
    for surface, expected in (("futsal", "futsal"), ("football", "football"),
                              ("cricket", "cricket"), ("badminton", "badminton"),
                              ("tennis", "tennis")):
        got = ext(f"{surface} ka ground", "sport")
        assert got and got["value"] == expected, f"{surface!r} -> {got}"


def test_sport_local_variants_map_to_the_canonical_sport():
    """"tape ball" is how half of Pakistan says cricket, and the variant is kept
    alongside the canonical value because a tape-ball request is a real filter."""
    got = ext("tape ball match", "sport")
    assert got["value"] == "cricket" and got.get("variant") == "tapeball"


def test_sport_misspellings_survive_normalisation():
    """The classifier's robustness to "futbal"/"futsl" comes from nlu_text.prep,
    and so does the extractor's: both read the same prepped string."""
    assert ext("futbal ground", "sport")["value"] == "football"
    assert ext("futsl court", "sport")["value"] == "futsal"


def test_sport_unsupported_sports_are_not_invented():
    """Padel and snooker are not SportLynk sports. Returning `null` lets Node say
    "we do not have that yet"; guessing "tennis" would send a user to a court they
    cannot use for the game they asked about."""
    assert ext("padel court chahiye", "sport") is None
    assert ext("snooker club", "sport") is None


def test_sport_format_phrases_are_not_a_sport():
    """"5 a side" is a FORMAT. It is also a digit followed by words, i.e. bait for
    every other rule in the file: it must produce no sport, no time, no budget."""
    slots = ext("5 a side khelna hai")
    assert slots["sport"] is None and slots["time"] is None and slots["budget"] is None


# ─────────────────────────────────────────────────────────────────────────────
# 5. Areas -- a gazetteer of the cities SportLynk actually has venues in
# ─────────────────────────────────────────────────────────────────────────────


def test_area_sector_forms_normalise_to_one_token():
    """"f-11", "f 11", "F-11 markaz" are one area. The canonical token is the one
    `reco_features.area_token` fits zones on, so an area extracted from chat and a
    zone learned by the recommender are the same string by construction."""
    for surface in ("f-11 mein", "f 11 mein", "F-11 Markaz ke paas"):
        got = ext(f"{surface} ground", "area")
        assert got and got["area"] == "F-11", f"{surface!r} -> {got}"


def test_area_multiword_place_names():
    assert ext("bahria town mein futsal", "area")["area"] == "BAHRIA-TOWN"
    assert ext("satellite town", "area")["area"] == "SATELLITE-TOWN"
    assert ext("blue area ke paas", "area")["area"] == "BLUE-AREA"


def test_area_sub_sector_collapses_to_its_sector():
    """"sector g-8/2" is a G-8 address. Venues are listed by sector, so the sub-
    sector has to collapse or the filter matches nothing."""
    got = ext("sector g-8/2 mein ground", "area")
    assert got["area"] == "G-8"


def test_area_city_only_utterance_yields_a_city_not_a_fake_area():
    """"islamabad mein" narrows the city and nothing else. Inventing an area would
    silently drop most of the city's venues from the results."""
    got = ext("islamabad mein ground chahiye", "area")
    assert got["area"] is None and got["city"] == "Islamabad"
    assert got["zone"] == "ISLAMABAD:*"


def test_area_outside_the_served_cities_is_not_guessed():
    """Johar Town is Lahore. SportLynk's venue table is Islamabad + Rawalpindi, so
    the honest answer is `null` and Node's reply is "we are not in Lahore yet" --
    not the nearest-looking sector in a city 300 km away."""
    assert ext("johar town mein ground", "area") is None


def test_area_city_comes_from_the_venue_catalogue():
    """The wave spec's "gazetteer from venues.city + venues.area": the city on an
    extracted area is read from the recommender artifact's venue snapshot, which is
    the only venue list this service is allowed to see (ml-service never touches
    Postgres). Skips when that artifact is absent -- the seed vocabulary alone is
    still a working gazetteer, just one without cities."""
    gaz = entities.default_gazetteer()
    if "artifact" not in gaz.sources:
        skip("no reco artifact on disk: gazetteer is seed-only, cities unavailable")
    assert ext("bahria town", "area")["city"] == "Rawalpindi"
    assert ext("f-9 park", "area")["city"] == "Islamabad"


# ─────────────────────────────────────────────────────────────────────────────
# 6. Budget -- money, and the digits that are not money
# ─────────────────────────────────────────────────────────────────────────────


def test_budget_ceiling_phrases():
    """"2500 se kam", "under 3000", "rs 2000 tak" are all one operator: max."""
    for text, amount in (("2500 se kam", 2500), ("under 3000", 3000),
                         ("rs 2000 tak", 2000), ("max 1800 per hour", 1800)):
        got = ext(f"{text} ka ground", "budget")
        assert got["op"] == "max" and got["amount"] == amount, f"{text!r} -> {got}"


def test_budget_range_keeps_both_ends():
    got = ext("1500 se 2500 ke beech", "budget")
    assert (got["op"], got["min"], got["max"]) == ("range", 1500, 2500)


def test_budget_qualitative_words_have_no_amount():
    """"sasta" is a preference, not a number. `op="qualitative"` with a null amount
    is what lets Node sort by price instead of inventing a ceiling the user never
    said."""
    got = ext("sasta ground dhundo", "budget")
    assert got["op"] == "qualitative" and got["amount"] is None


def test_budget_currency_is_stated_not_assumed_downstream():
    """Every amount carries PKR explicitly, so no consumer has to assume."""
    assert ext("2500 se kam", "budget")["currency"] == "PKR"


def test_budget_ignores_digits_that_are_not_money():
    """A clock, a day offset and a format are all digits. None of them is a budget.

    This is the test that would catch the classic regex-greed bug: one digit-run
    pattern applied anywhere
    in the utterance, read as rupees, turns "6 baje" into a 6-rupee ceiling and
    empties the venue list.
    """
    for text in ("6 baje", "2 din baad", "5 a side", "30/08"):
        assert ext(text, "budget") is None, f"{text!r} produced a budget"


# ─────────────────────────────────────────────────────────────────────────────
# 7. Combined utterances -- four rules over one string, no collisions
# ─────────────────────────────────────────────────────────────────────────────


def test_all_five_slots_from_one_realistic_request():
    """The utterance the assistant exists for. Every slot filled, once, correctly.

    "kal shaam 6 baje f-11 mein 2500 tak futsal ka ground chahiye" is four numbers
    and a place in twelve words, and it is what a real user types.
    """
    slots = ext("kal shaam 6 baje f-11 mein 2500 tak futsal ka ground chahiye")
    assert slots["date"]["iso"] == "2026-08-29"
    assert slots["time"]["start"] == "18:00"
    assert slots["sport"]["value"] == "futsal"
    assert slots["area"]["area"] == "F-11"
    assert (slots["budget"]["op"], slots["budget"]["amount"]) == ("max", 2500)


def test_two_numbers_are_not_read_as_the_same_thing():
    """"6 baje" and "2500" are both numbers in one sentence, and they are a clock
    and a ceiling respectively -- the span-claiming that makes that reliable."""
    slots = ext("kal 6 baje 2500 tak")
    assert slots["time"]["start"] == "18:00"
    assert slots["budget"]["amount"] == 2500
    assert slots["time"]["span"] != slots["budget"]["span"]


def test_english_and_roman_urdu_mix_in_one_utterance():
    """The corpus's third language is the mix, because that is how people type."""
    slots = ext("book a cricket ground kal subah 8 baje bahria town")
    assert slots["sport"]["value"] == "cricket"
    assert slots["date"]["iso"] == "2026-08-29"
    assert slots["time"]["start"] == "08:00"
    assert slots["area"]["area"] == "BAHRIA-TOWN"


def test_every_slot_key_is_always_present():
    """All five keys on every response, `null` when unfilled. A consumer that has
    to check `"date" in entities` before reading it will one day forget."""
    for text in ("", "kal", "asdkjh", "2500 tak f-11 mein futsal kal 6 baje"):
        slots = entities.extract(text, now=NOW)
        assert tuple(slots) == entities.ENTITY_KEYS, f"{text!r} -> {tuple(slots)}"


def test_extraction_is_deterministic_and_survives_junk():
    """Same input, same output, twice -- and emoji, punctuation and an empty string
    return five nulls instead of raising. The extractor runs on user input from a
    chat box; an exception there is a 500 on a typo."""
    for text in ("", "   ", "???", "🙏🙏", "kal shaam 6 baje f-11"):
        first = entities.extract(text, now=NOW)
        assert first == entities.extract(text, now=NOW), f"non-deterministic: {text!r}"


def test_a_500_character_utterance_is_still_parsed():
    """The router's ceiling is 500 characters; the extractor must not choke at it.

    A paste of a WhatsApp thread into the chat box is a real event, and the answer
    to it is "the slots I can find", not a stack trace.
    """
    filler = "ground chahiye " * 30
    text = (filler + "kal shaam 6 baje f-11 mein")[:500]
    slots = entities.extract(text, now=NOW)
    assert slots["date"] is not None and slots["area"]["area"] == "F-11"


# ─────────────────────────────────────────────────────────────────────────────
# 8. The classifier -- contract and behaviour, never accuracy
# ─────────────────────────────────────────────────────────────────────────────


def test_probabilities_are_a_distribution_over_every_declared_class():
    """One column per declared intent, non-negative, summing to 1. `predict_proba` is the whole basis
    of the abstain floor: a "confidence" that is not a probability makes 0.45 an
    arbitrary number instead of a rate."""
    entry = model_entry()
    row = entry.estimator.predict_proba(["kal f-11 mein futsal ground chahiye"])[0]
    assert len(row) == len(intent_spec.INTENTS)
    assert all(p >= 0.0 for p in row)
    assert abs(float(sum(row)) - 1.0) < 1e-6


def test_predict_and_argmax_of_predict_proba_agree():
    """They are computed differently on a calibrated estimator and CAN disagree,
    which is why the router derives both label and confidence from one
    `predict_proba` call. If this ever fails, that decision is the reason nothing
    downstream breaks."""
    import numpy as np
    entry = model_entry()
    texts = ["mere bookings dikhao", "book kar do 8 pm", "meri booking cancel karni hai"]
    proba = entry.estimator.predict_proba(texts)
    labels = list(entry.estimator.classes_)
    for text, predicted, row in zip(texts, entry.estimator.predict(texts), proba):
        assert labels[int(np.argmax(row))] == predicted, text


def test_unambiguous_utterances_land_in_the_right_intent():
    """Five utterances, one per group, each written to be as unambiguous as the
    domain allows. This is NOT an accuracy claim -- five rows cannot make one.
    It is a smoke test: if the artifact were fitted on shuffled labels, or the
    normaliser drifted, every one of these would move at once.
    """
    for text, expected in (
        ("f-11 mein futsal ka ground dhundo", "find_venue"),
        ("mere bookings dikhao", "my_bookings"),
        ("meri booking cancel karni hai", "cancel_booking"),
        ("assalam o alaikum", "greeting"),
        ("is weekend opponent team chahiye", "find_opponents"),
    ):
        got = parse(text)
        assert got.intent == expected, f"{text!r} -> {got.intent} ({got.confidence})"


def test_off_domain_requests_are_refused_not_forced():
    """A weather question and a food order are not assistant intents. They must
    come back as `out_of_scope` -- by the label or by the floor, either is a
    refusal -- because a forced answer books a ground for someone asking about
    biryani."""
    for text in ("mausam kaisa hai aaj", "biryani order karni hai", "dollar rate kya hai"):
        got = parse(text)
        assert got.intent == "out_of_scope", f"{text!r} -> {got.intent} ({got.confidence})"


def test_the_abstain_floor_is_actually_applied():
    """Below the artifact's threshold, the served label becomes the fallback while
    `topIntent`/`topConfidence` keep what the model actually thought.

    Both halves matter: the first is the refusal, the second is what makes the
    refusal auditable and what feeds Node's did-you-mean menu.
    """
    # A single pinned utterance made this test skip itself as soon as the model
    # got confident about it (v2 scores 'grnd chahiye' 0.55). Scan instead, and
    # FAIL rather than skip if nothing abstains: a classifier that answers every
    # vague fragment above the floor has lost the refusal, and silence about that
    # is the one outcome a test must not produce.
    vague = ("yaar wo cheez", "ground ka scene", "grnd chahiye", "batao na kuch")
    for text in vague:
        got = parse(text)
        assert got.threshold == 0.45
        if got.abstained and got.abstain_reason == "low_confidence":
            break
    else:
        raise AssertionError(
            f"none of {vague} abstained on low confidence -- the floor is not being "
            f"applied, or the model has become overconfident on fragments"
        )
    assert got.intent == "out_of_scope"
    assert got.abstain_reason == "low_confidence"
    assert got.top_confidence < got.threshold
    assert len(got.alternatives) == 3


def test_placeholder_only_input_never_reaches_the_model():
    """"???" and an emoji have no content tokens: `no_evidence`, no estimator call.
    The near-zero `intentMs` is the evidence that the call really was skipped."""
    for text in ("???", "🙏", "...."):
        got = parse(text)
        assert got.abstained and got.abstain_reason == "no_evidence", f"{text!r}"
        assert got.alternatives == [] and got.intent_ms < 1.0


def test_gibberish_is_refused_even_though_the_floor_cannot_catch_it():
    """A keyboard-mash scores 0.528 for `greeting` -- above the 0.45 floor -- because
    `char_wb` n-grams fire on any string. The out-of-vocabulary guard catches what
    the floor cannot: no token was ever seen in training, so there is no word
    evidence at all."""
    for text in ("asdkjh qwe zxcv", "xyzzy plugh", "zzzz"):
        got = parse(text)
        assert got.abstained, f"{text!r} -> {got.intent} {got.confidence}"
        assert got.abstain_reason == "no_known_terms", f"{text!r} -> {got.abstain_reason}"


def test_a_typo_is_not_treated_as_gibberish():
    """The guard must not fire on a real utterance with a misspelling in it: prep
    canonicalises "futbal" to "football" before the vocabulary is consulted.

    `now=NOW` is not optional: this asserts a DATE, and a date asserted against the
    real clock passes on the day it was written and fails the next morning.
    """
    got = parse("futbal ka grnd chahiye kal", now=NOW)
    assert got.abstain_reason != "no_known_terms"
    assert got.entities["date"]["iso"] == "2026-08-29"


# ─────────────────────────────────────────────────────────────────────────────
# 9. The endpoint's own contract
# ─────────────────────────────────────────────────────────────────────────────


def test_parse_response_carries_the_full_contract_identity():
    """Version strings for the model and all three frozen specs, on every parse.

    A logged or stored parse has to be traceable to the exact artifact and rule
    tables that produced it, months later, without a matching deploy log.
    """
    got = parse("kal f-11 mein futsal")
    assert got.model_version == model_entry().version
    assert got.intent_spec_version == intent_spec.INTENT_SPEC_VERSION
    assert got.entity_spec_version == entities.ENTITY_SPEC_VERSION
    assert got.nlu_text_spec_version == nlu_text.NLU_TEXT_SPEC_VERSION
    assert got.source == "model"


def test_an_abstention_still_returns_its_slots():
    """The slot-filling turn. The dialog manager asks "kis waqt?" and the user
    answers "kal 6 baje" -- an utterance with no intent to speak of. Returning
    empty entities alongside the abstention would break the conversation at exactly
    the point where the user was being most cooperative.

    Frozen clock, same reason as above -- "kal" is only 2026-08-29 from 2026-08-28.
    """
    got = parse("kal 6 baje", now=NOW)
    assert got.entities["date"]["iso"] == "2026-08-29"
    assert got.entities["time"]["start"] == "18:00"
    if got.abstained:
        assert got.intent == "out_of_scope"


def test_the_now_override_reaches_the_extractor():
    """`now` on the request is what lets Node replay a stored turn, and lets a test
    assert a date at all. Without it the endpoint would be untestable by
    construction."""
    import datetime as dt
    other = dt.datetime(2026, 12, 25, 9, 0, tzinfo=NOW.tzinfo)
    assert parse("kal", now=other).entities["date"]["iso"] == "2026-12-26"


def test_request_validation_rejects_what_the_service_will_not_read():
    """Empty text, over-long text and an unknown field are 422s, not silent
    truncations. `extra="forbid"` is deliberate: a typo'd `sessionID` that is
    quietly ignored produces a session that never groups."""
    from pydantic import ValidationError
    from app.routers import nlu
    for kwargs in ({"text": ""}, {"text": "x" * 501}, {"text": "kal", "bogus": 1}):
        try:
            nlu.ParseRequest(**kwargs)
        except ValidationError:
            continue
        raise AssertionError(f"ParseRequest accepted {kwargs!r}")


def test_the_published_spec_describes_what_the_router_does():
    """`/nlu/spec` is what Node validates its own label map and abstain branches
    against at startup. Everything it advertises has to be live behaviour."""
    from app.routers import nlu
    data = nlu.nlu_spec()["data"]
    assert {row["intent"] for row in data["intents"]} == set(intent_spec.INTENTS)
    assert set(data["abstainReasons"]) == {
        nlu.REASON_LOW_CONFIDENCE, nlu.REASON_NO_EVIDENCE, nlu.REASON_NO_KNOWN_TERMS,
    }
    assert data["limits"]["maxTextChars"] == nlu.MAX_TEXT_CHARS
    assert data["model"]["threshold"] == 0.45
    assert data["entities"]["keys"] == list(entities.ENTITY_KEYS)


def test_a_warm_parse_stays_inside_the_fifty_millisecond_budget():
    """The wave's latency requirement, measured the way the endpoint reports it.

    Warm, because the cold path is dominated by dateparser's language data (8.3 s
    on first use) and joblib's unpickling -- both paid once, in `warm()`, during
    uvicorn's lifespan. Twenty parses and the MEDIAN is asserted, not one parse and
    its wall clock: a single sample on a laptop that decided to index something is
    not a latency regression.
    """
    from app.routers import nlu
    texts = [
        "kal shaam 6 baje f-11 mein futsal ka ground chahiye",
        "mere bookings dikhao",
        "meri booking cancel kar do",
        "is weekend opponent team dhundo",
        "2500 se kam wala turf bahria town mein",
    ] * 4
    parse(texts[0])  # warm this process's caches, as lifespan does in serving
    measured = sorted(parse(text).elapsed_ms for text in texts)
    median = measured[len(measured) // 2]
    assert median < nlu.LATENCY_BUDGET_MS, f"median {median:.1f}ms over budget"
    assert measured[-1] < nlu.LATENCY_BUDGET_MS * 3, f"worst {measured[-1]:.1f}ms"


# ─────────────────────────────────────────────────────────────────────────────
# Standalone runner
# ─────────────────────────────────────────────────────────────────────────────


# ── the v2 label contract: 8 intents were added, and a label the model never
#    emits is dead code wearing a contract's clothes ──────────────────────────

#: Derived, not typed: whatever `intent_spec` declares minus what the last v1
#: artifact could emit. A typed list rots the moment the contract moves -- and it
#: already did once during this wave, when a hand-written "new labels" list
#: carried `help_menu` (never a label) and omitted `check_availability` (a v1 one).
V1_LABELS = frozenset({
    "book_venue", "cancel_booking", "my_bookings", "check_availability", "find_venue",
    "venue_info", "wallet_balance", "topup_help", "refund_policy", "tournament_list",
    "team_stats", "create_team_help", "find_opponents", "greeting", "out_of_scope",
})
V2_ADDED = frozenset(intent_spec.INTENTS) - V1_LABELS


def test_the_v1_label_set_is_a_subset_of_v2():
    """v2 ADDED labels; it must not have dropped any. If a v1 label disappeared,
    every Node branch and every stored `assistant_turns.intent` row referring to
    it became unreadable, and that is a migration, not a retrain."""
    missing = V1_LABELS - set(intent_spec.INTENTS)
    assert not missing, f"v2 dropped v1 label(s): {sorted(missing)}"
    assert len(V2_ADDED) == 8, f"expected 8 added labels, found {sorted(V2_ADDED)}"


def test_every_label_the_v2_contract_added_is_reachable():
    """One high-margin utterance per added label.

    This is NOT an accuracy claim -- eight rows cannot make one. It answers a
    different question: is the label OPERATIONAL? A classifier can carry a class
    it has learned to never predict, and the contract, the spec endpoint and
    Node's switch would all still list it while it silently never fires. Each
    utterance below beats its runner-up by >= 0.35, so a failure here means the
    label has gone dead or the corpus moved under it -- not that the model is
    imperfect.
    """
    cases = (
        ("we are 3 players short for the game", "find_players"),
        ("kisi team me jagah hai to bata do main join karunga", "find_teams"),
        ("how do i get to centaurus from blue area", "navigate"),
        ("i want to talk to the owner of this ground", "contact_owner"),
        ("app me profile kaise edit karun", "app_help"),
        ("elo kaise barhta hai", "elo_help"),
        ("haan bilkul kar do", "affirm"),
        ("nahi rehne do abhi", "deny"),
    )
    # A label added later must land here too, or it ships untested behind a green
    # suite. This assertion is the thing that notices.
    assert {e for _, e in cases} == V2_ADDED, (
        f"untested added label(s): {sorted(V2_ADDED - {e for _, e in cases})}"
    )
    for text, expected in cases:
        got = parse(text)
        assert got.intent == expected, f"{text!r} -> {got.intent} ({got.confidence})"


def test_the_dialog_group_is_exactly_affirm_and_deny():
    """Node needs one stable way to know an intent is meaningless without context.
    `affirm`/`deny` answer a proposal Scout made a turn ago; served with no pending
    proposal they mean nothing, and acting on them would confirm a booking the user
    never saw. The `dialog` group IS that flag, so its membership is a contract.
    """
    dialog = {i for i in intent_spec.INTENTS if intent_spec.intent_group(i) == "dialog"}
    assert dialog == {"affirm", "deny"}, dialog
    for i in ("book_venue", "cancel_booking", "greeting", "out_of_scope"):
        assert intent_spec.intent_group(i) != "dialog"


def test_every_intent_has_a_group_and_a_gloss():
    """The gloss is not documentation -- it is what decided six v1 rows were
    mislabelled this wave. An intent without one cannot be argued about, so its
    boundary is whatever the model happened to learn."""
    assert len(intent_spec.INTENT_CATALOG) == len(intent_spec.INTENTS)
    for intent, group, gloss, _confusable in intent_spec.INTENT_CATALOG:
        assert intent in intent_spec.INTENTS, intent
        assert group in intent_spec.INTENT_GROUPS, (intent, group)
        assert len(gloss.split()) >= 5, f"{intent}: gloss too thin to adjudicate: {gloss!r}"


def test_a_squad_short_of_players_is_find_players_not_find_opponents():
    """Regression guard for the corpus defect this wave fixed.

    v1 had no `find_players`, so "we need 2 more players for a match" was filed
    under `find_opponents` -- the least-wrong label then, a label error under the
    v2 gloss ("ask for one or more PEOPLE to fill a squad"). Three templates and
    two authored rows taught it, so the model answered the single most likely
    find_players utterance with find_opponents at 0.77. Recruiting PEOPLE into my
    side and seeking a TEAM to play against are different actions with different
    Node handlers, so this stays pinned in all three languages.
    """
    for text in (
        "need 2 more players for tonights cricket match",
        "hamare 2 players short hain cricket ke liye",
        "2 khiladi kam hain kal ke match ke liye",
    ):
        got = parse(text)
        assert got.intent == "find_players", f"{text!r} -> {got.intent} ({got.confidence})"
    for text in (
        "we need a team to play against this sunday",
        "koi team hai jo hamare saath khele",
    ):
        got = parse(text)
        assert got.intent == "find_opponents", f"{text!r} -> {got.intent} ({got.confidence})"


def collect(pattern: str | None = None) -> list[tuple[str, object]]:
    """Every `test_*` in DEFINITION order, optionally filtered by substring.

    Definition order, not alphabetical: module globals preserve insertion order, so
    the suite reads top to bottom the way the file does -- contracts, then dates,
    then the model. A failure list that follows the file is a failure list you can
    walk down.
    """
    found = [
        (name, obj) for name, obj in globals().items()
        if name.startswith("test_") and callable(obj)
    ]
    if pattern:
        needle = pattern.lower()
        found = [pair for pair in found if needle in pair[0].lower()]
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the S.6 NLU unit tests without pytest.",
    )
    parser.add_argument("-k", dest="pattern", default=None,
                        help="only tests whose name contains this substring")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="one line per failure, plus the summary")
    args = parser.parse_args(argv)

    tests = collect(args.pattern)
    if not tests:
        print(f"no tests match -k {args.pattern!r}")
        return 1

    passed: list[str] = []
    skipped: list[tuple[str, str]] = []
    failed: list[tuple[str, str]] = []
    started = time.perf_counter()

    for name, fn in tests:
        try:
            fn()
        except Skipped as exc:
            skipped.append((name, str(exc)))
            mark = "SKIP"
        except AssertionError as exc:
            failed.append((name, str(exc) or "assertion failed"))
            mark = "FAIL"
        except Exception as exc:  # an error is a failure, with its type named
            failed.append((name, f"{type(exc).__name__}: {exc}"))
            mark = "ERROR"
        else:
            passed.append(name)
            mark = "ok"
        if not args.quiet:
            print(f"  {mark:<5} {name}")

    elapsed = time.perf_counter() - started
    for name, why in failed:
        print(f"\nFAIL  {name}\n      {why}")
    for name, why in skipped:
        print(f"SKIP  {name}: {why}")
    print(
        f"\n{len(passed)} passed, {len(skipped)} skipped, {len(failed)} failed "
        f"of {len(tests)} in {elapsed:.1f}s"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
