"""Build the SportLynk assistant intent corpus -- Model #4, S.6 Wave A.

Three hand-written inputs, one generated output:

    data/assistant/templates.csv          patterns  ("{sport} ground {area} me")
    data/assistant/authored_intents.csv   hand-written rows, kept verbatim
    data/assistant/assistant_test.csv     hand-written rows -- THE EXAM, read-only
                    |
                    v
    data/assistant/intents.csv            the corpus, with a train/val split
    data/assistant/intents_meta.json      sha256 + census + gate receipts

The corpus is gitignored and the metadata is committed. That is the same trade the
sentiment corpus makes: the generator plus the seed IS the reproducibility story,
so a fresh clone rebuilds the corpus and *verifies* it against a committed sha256
instead of trusting a blob in git history. Same seed, byte-identical file.

No vocabulary and no threshold lives in this file. Intents, slot values, quotas
and every gate limit come from ``app/core/intent_spec.py``; this script is an
allocator, a gate runner and a writer. A number you can change here is a number
that was never a contract.

WHAT THE GATES ARE ACTUALLY FOR
-------------------------------
* THE EXAM IS NEVER TRAINED ON. Every corpus row is checked against all 150 exam
  rows -- exact match on the dedup key, then near-duplicate -- and the CORPUS row
  is dropped. The exam is never edited to accommodate the corpus; that is the one
  direction in which this repository does not permit a fix.
* THE SPLIT IS GROUPED BY ``template_id``. A random split over template-expanded
  rows puts "book Rawal FC for kal" in train and "book Rawal FC for parso" in val,
  reports 0.99, and has measured slot-value memorisation. Grouping by template
  means no validation phrasing was seen at fit time.
* PER-TEMPLATE OUTPUT IS CAPPED (``MAX_ROWS_PER_TEMPLATE``). Without it an intent
  reaches its row target by multiplying one phrasing ninety times, and the
  headline accuracy measures the template list, not the language.
* THE SAME TEXT UNDER TWO INTENTS IS FATAL, not deduplicated. It is a labelling
  contradiction: no threshold makes it acceptable and silently dropping one side
  hides a bad template.

Every check is named, is recorded in ``intents_meta.json`` with its detail string,
and a hard failure writes ``intents.rejected.csv`` instead of ``intents.csv`` --
so a failed run leaves the evidence on disk and the previous good corpus intact.

Run:
    ./.venv/Scripts/python.exe training/gen_intents.py
    ./.venv/Scripts/python.exe training/gen_intents.py --no-write   # gates only
    ./.venv/Scripts/python.exe training/gen_intents.py --seed 7 --per-intent 120

Exit 0 = corpus written and every hard gate passed; 1 = a hard gate failed.
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import hashlib
import json
import math
import random
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # ml-service/
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from app.core import intent_spec as isp  # noqa: E402  (path insert must precede)

# Windows consoles default to cp1252 and authored rows carry emoji.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

# Paths
DATA = ROOT / "data" / "assistant"
TEMPLATES_PATH = DATA / "templates.csv"
AUTHORED_PATH = DATA / "authored_intents.csv"
EXAM_PATH = DATA / "assistant_test.csv"
EXAM_META_PATH = DATA / "assistant_test_meta.json"
OUT_PATH = DATA / "intents.csv"
REJECT_PATH = DATA / "intents.rejected.csv"
META_PATH = DATA / "intents_meta.json"

#: Day 15 of the sprint, the day Wave A was allocated. A seed has to be *some*
#: number; one that says which run produced the corpus is worth more than 42.
DEFAULT_SEED = 20260824

CSV_COLUMNS = ("id", "text", "intent", "lang", "source", "template_id",
               "phenomena", "split")
TEMPLATE_COLUMNS = ["template_id", "intent", "lang", "pattern", "phenomena"]
AUTHORED_COLUMNS = ["id", "text", "intent", "lang", "phenomena", "note"]
EXAM_COLUMNS = ["id", "text", "intent", "lang", "phenomena", "notes"]

_RE_TEMPLATE_ID = re.compile(r"^([a-z_]+)-(en|mix|ru)-(\d{2,})$")
_RE_AUTHORED_ID = re.compile(r"^au-\d{3,}$")


# Check ledger
class Ledger:
    """Named checks with a severity. ``gate`` fails the run, ``warn`` reports.

    The severity is per-check and fixed in code for the same reason the
    thresholds live in the spec module: a gate that can be downgraded from the
    command line is a log line with extra steps.
    """

    def __init__(self) -> None:
        self.rows: list[tuple[str, bool, str, str]] = []

    def gate(self, name: str, ok: bool, detail: str = "") -> bool:
        self.rows.append((name, bool(ok), detail, "gate"))
        return bool(ok)

    def warn(self, name: str, ok: bool, detail: str = "") -> bool:
        self.rows.append((name, bool(ok), detail, "warn"))
        return bool(ok)

    @property
    def failures(self) -> list[tuple[str, bool, str, str]]:
        return [row for row in self.rows if not row[1] and row[3] == "gate"]

    @property
    def passed(self) -> bool:
        return not self.failures

    def render(self) -> str:
        width = max((len(name) for name, _, _, _ in self.rows), default=4)
        lines = []
        for name, ok, detail, severity in self.rows:
            mark = "PASS" if ok else ("FAIL" if severity == "gate" else "WARN")
            line = f"  [{mark}] {name.ljust(width)}"
            if detail:
                line += f"  {detail}"
            lines.append(line)
        return "\n".join(lines)

    def as_json(self) -> list[dict[str, object]]:
        return [{"name": n, "ok": ok, "severity": sev, "detail": d}
                for n, ok, d, sev in self.rows]


# Small helpers
def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    """Columns and rows. ``utf-8-sig`` because a hand-edited CSV acquires a BOM
    the first time somebody opens it in Excel, and a BOM on the first header
    turns ``id`` into ``﻿id`` and every lookup into ``None``."""
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = list(reader.fieldnames or [])
        return columns, [{key: (value or "") for key, value in row.items()}
                         for row in reader]


def tags_of(value: str) -> list[str]:
    return [tag.strip() for tag in (value or "").split(";") if tag.strip()]


def largest_remainder(weights: dict[str, float], total: int) -> dict[str, int]:
    """Split ``total`` across ``weights`` so the parts are integers that sum to
    ``total`` exactly. Rounding each share independently loses or invents rows,
    and "1,679 of 1,680" is the kind of discrepancy that gets explained away."""
    keys = list(weights)
    if total <= 0:
        return {key: 0 for key in keys}
    mass = sum(max(0.0, weights[key]) for key in keys)
    if mass <= 0:
        share = {key: 1.0 for key in keys}
        return largest_remainder(share, total)
    exact = {key: total * max(0.0, weights[key]) / mass for key in keys}
    out = {key: int(exact[key]) for key in keys}
    order = sorted(keys, key=lambda key: (-(exact[key] - out[key]),
                                          isp.LANGS.index(key)
                                          if key in isp.LANGS else 0, key))
    for key in order[:total - sum(out.values())]:
        out[key] += 1
    return out


def water_fill(caps: list[int], total: int) -> list[int]:
    """Spread ``total`` as evenly as possible across bins of capacity ``caps``.

    Even by design: the alternative is to let a high-capacity template absorb the
    quota, which is how a corpus ends up with 40 rows from one pattern and 2 from
    another and a per-template cap that never binds. Deterministic in index
    order; the last few rows land in the earliest bins with room."""
    out = [0] * len(caps)
    remaining = min(total, sum(caps))
    while remaining > 0:
        active = [index for index, cap in enumerate(caps) if out[index] < cap]
        if not active:
            break
        if remaining < len(active):
            for index in active[:remaining]:
                out[index] += 1
            break
        share = max(1, remaining // len(active))
        for index in active:
            if remaining <= 0:
                break
            add = min(share, caps[index] - out[index], remaining)
            out[index] += add
            remaining -= add
    return out


def cramers_v(pairs: list[tuple[str, str]]) -> tuple[float, float, int]:
    """``(V, chi2, dof)`` for a contingency table given as observed pairs.

    Hand-rolled in stdlib, like the sentiment builder's: this script runs before
    any model is fit and should not pull in a numerics dependency to divide two
    sums. Deliberately returns NO p-value -- at n = 1,680 the null is rejected by
    associations far too weak to matter, so a p-value would read as evidence
    while carrying none. The effect size answers the question being asked: how
    STRONG is the shortcut, not whether it is exactly zero."""
    if not pairs:
        return 0.0, 0.0, 0
    rows = sorted({left for left, _ in pairs})
    cols = sorted({right for _, right in pairs})
    observed = Counter(pairs)
    n = len(pairs)
    row_totals = {row: sum(observed[(row, col)] for col in cols) for row in rows}
    col_totals = {col: sum(observed[(row, col)] for row in rows) for col in cols}
    chi2 = 0.0
    for row in rows:
        for col in cols:
            expected = row_totals[row] * col_totals[col] / n
            if expected > 0:
                chi2 += (observed[(row, col)] - expected) ** 2 / expected
    smaller = min(len(rows), len(cols))
    v = math.sqrt(chi2 / (n * (smaller - 1))) if smaller > 1 else 0.0
    return v, chi2, (len(rows) - 1) * (len(cols) - 1)


# Inputs
@dataclass
class Template:
    template_id: str
    intent: str
    lang: str
    pattern: str
    phenomena: str
    pool: list[str] = field(default_factory=list)   # rendered candidates, ordered
    used: int = 0                                   # how many of them shipped


@dataclass
class Hand:
    """A hand-written row: authored (goes into the corpus) or exam (never does)."""
    row_id: str
    text: str
    intent: str
    lang: str
    phenomena: str
    note: str = ""


def load_templates(path: Path, led: Ledger) -> list[Template]:
    columns, rows = read_csv(path)
    led.gate("templates_columns", columns == TEMPLATE_COLUMNS,
             ",".join(columns) if columns == TEMPLATE_COLUMNS else f"got {columns}")

    templates: list[Template] = []
    bad_ids: list[str] = []
    unknown: list[str] = []
    problems: list[str] = []
    seen_ids: Counter[str] = Counter()
    seen_patterns: dict[tuple[str, str, str], str] = {}
    duplicate_patterns: list[str] = []

    for row in rows:
        template_id = row["template_id"].strip()
        intent = row["intent"].strip()
        lang = row["lang"].strip()
        pattern = row["pattern"]
        phenomena = row["phenomena"].strip()
        seen_ids[template_id] += 1

        match = _RE_TEMPLATE_ID.match(template_id)
        if not match or match.group(1) != intent or match.group(2) != lang:
            # The id encodes its own intent and lang, so a row that was copied
            # and half-edited is caught here instead of quietly training
            # 'find_venue' text under 'book_venue'.
            bad_ids.append(f"{template_id} (intent={intent}, lang={lang})")
        if intent not in isp.INTENTS:
            unknown.append(f"{template_id}: intent {intent!r}")
        if lang not in isp.LANGS:
            unknown.append(f"{template_id}: lang {lang!r}")
        for tag in tags_of(phenomena):
            if tag not in isp.PHENOMENA:
                unknown.append(f"{template_id}: phenomenon {tag!r}")
        if intent in isp.INTENTS and lang in isp.LANGS:
            for problem in isp.validate_pattern(pattern, lang, intent):
                problems.append(f"{template_id}: {problem}")
            key = (intent, lang, isp.dedup_key(pattern))
            if key in seen_patterns:
                duplicate_patterns.append(f"{template_id} == {seen_patterns[key]}")
            else:
                seen_patterns[key] = template_id
        templates.append(Template(template_id, intent, lang, pattern, phenomena))

    duplicate_ids = sorted(tid for tid, count in seen_ids.items() if count > 1)
    led.gate("templates_ids_unique", not duplicate_ids,
             f"{len(duplicate_ids)} repeated: {duplicate_ids[:4]}"
             if duplicate_ids else f"{len(templates)} distinct ids")
    led.gate("templates_ids_agree", not bad_ids,
             f"{len(bad_ids)}: {bad_ids[:3]}" if bad_ids
             else "every id is <intent>-<lang>-NN and matches its own columns")
    led.gate("templates_contract", not unknown,
             f"{len(unknown)}: {unknown[:3]}" if unknown
             else f"{len(isp.INTENTS)} intents, {len(isp.LANGS)} langs, "
                  f"{len(isp.PHENOMENA)} phenomena all recognised")
    led.gate("templates_valid", not problems,
             f"{len(problems)} problem(s); first: {problems[:2]}" if problems
             else f"all {len(templates)} patterns pass validate_pattern()")
    led.gate("templates_distinct", not duplicate_patterns,
             f"{len(duplicate_patterns)}: {duplicate_patterns[:3]}"
             if duplicate_patterns
             else "no two patterns of one (intent, lang) are the same utterance")
    return templates


def load_hand(path: Path, expected_columns: list[str], id_pattern: re.Pattern[str],
              label: str, led: Ledger) -> list[Hand]:
    """Load ``authored_intents.csv`` or ``assistant_test.csv``.

    Hand-written rows are JUDGED, never repaired: ``text_problems`` reports and
    the run fails, and a human edits the CSV. Running ``tidy`` over them instead
    would silently rewrite an author's deliberate "kahan gaye??" and the corpus
    would lose exactly the informal punctuation it is meant to teach.
    """
    columns, rows = read_csv(path)
    led.gate(f"{label}_columns", columns == expected_columns,
             ",".join(columns) if columns == expected_columns else f"got {columns}")

    note_column = expected_columns[-1]
    hands: list[Hand] = []
    bad_ids: list[str] = []
    unknown: list[str] = []
    problems: list[str] = []
    seen_ids: Counter[str] = Counter()
    seen_keys: dict[str, str] = {}
    duplicates: list[str] = []

    for row in rows:
        row_id = row["id"].strip()
        text = row["text"]
        intent = row["intent"].strip()
        lang = row["lang"].strip()
        seen_ids[row_id] += 1
        if not id_pattern.match(row_id):
            bad_ids.append(row_id)
        if intent not in isp.INTENTS:
            unknown.append(f"{row_id}: intent {intent!r}")
        if lang not in isp.LANGS:
            unknown.append(f"{row_id}: lang {lang!r}")
        for tag in tags_of(row["phenomena"]):
            if tag not in isp.PHENOMENA:
                unknown.append(f"{row_id}: phenomenon {tag!r}")
        for problem in isp.text_problems(text):
            problems.append(f"{row_id}: {problem} -- {text!r}")
        key = isp.dedup_key(text)
        if key in seen_keys:
            duplicates.append(f"{row_id} == {seen_keys[key]}")
        else:
            seen_keys[key] = row_id
        hands.append(Hand(row_id, text, intent, lang, row["phenomena"].strip(),
                          row.get(note_column, "").strip()))

    duplicate_ids = sorted(rid for rid, count in seen_ids.items() if count > 1)
    led.gate(f"{label}_ids", not duplicate_ids and not bad_ids,
             f"{len(duplicate_ids)} repeated, {len(bad_ids)} malformed "
             f"{(duplicate_ids + bad_ids)[:4]}" if (duplicate_ids or bad_ids)
             else f"{len(hands)} rows, ids unique and well formed")
    led.gate(f"{label}_contract", not unknown,
             f"{len(unknown)}: {unknown[:3]}" if unknown
             else "intents, langs and phenomena all recognised")
    led.gate(f"{label}_text_clean", not problems,
             f"{len(problems)} row(s); first: {problems[:2]}" if problems
             else f"all {len(hands)} rows pass text_problems()")
    led.gate(f"{label}_distinct", not duplicates,
             f"{len(duplicates)}: {duplicates[:3]}" if duplicates
             else "no two rows are the same utterance")
    return hands


def check_exam_lock(exam_path: Path, meta_path: Path, led: Ledger) -> str:
    """sha256 of the exam, compared with the fingerprint the validator recorded.

    The corpus builder reads the exam for one purpose -- to exclude overlap -- and
    it has to be reading the SAME exam the model will eventually be graded on.
    Absent metadata is a warning (the validator has not been run yet); metadata
    that disagrees is a hard failure, because one of the two files moved and
    guessing which is not this script's job."""
    digest = sha256_file(exam_path)
    if not meta_path.is_file():
        led.warn("exam_lock", True,
                 f"{digest[:12]}.. -- no {meta_path.name} yet; "
                 f"run validate_intent_test.py to pin it")
        return digest
    try:
        recorded = json.loads(meta_path.read_text(encoding="utf-8")).get("sha256", "")
    except (json.JSONDecodeError, OSError) as exc:
        led.gate("exam_lock", False, f"{meta_path.name} unreadable: {exc!r}")
        return digest
    led.gate("exam_lock", recorded == digest,
             f"matches {meta_path.name} ({digest[:12]}..)" if recorded == digest
             else f"exam sha256 {digest[:12]}.. != recorded {str(recorded)[:12]}..")
    return digest


def build_pools(templates: list[Template], seed: int, led: Ledger) -> None:
    """Render each template's candidate rows once, in a seeded order.

    Every template gets a pool of at most ``MAX_ROWS_PER_TEMPLATE`` rendered rows
    drawn from its full combination space by index, so the allocator only ever
    takes a prefix of a pool and per-template output is capped by construction
    rather than by a check afterwards. The pool is NOT index-sorted: a prefix of a
    sorted pool would always take the first few values of the slowest-varying
    slot, and a template with capacity 9 would ship 'today, tomorrow, tonight'
    forever and never 'Saturday'."""
    dirty: list[str] = []
    for template in templates:
        slots = isp.pattern_slots(template.pattern)
        cardinalities = [len(isp.slot_values(slot, template.lang)) for slot in slots]
        capacity = 1
        for size in cardinalities:
            capacity *= size
        wanted = min(capacity, isp.MAX_ROWS_PER_TEMPLATE)
        rng = random.Random(isp.stable_seed(seed, template.template_id))
        seen: set[str] = set()
        pool: list[str] = []
        for index in rng.sample(range(capacity), wanted):
            choices = {slot: isp.slot_values(slot, template.lang)[choice]
                       for slot, choice in zip(slots, isp.decode_index(index, cardinalities))}
            text = isp.render(template.pattern, choices)
            problems = isp.text_problems(text)
            if problems:
                dirty.append(f"{template.template_id}: {problems[0]} -- {text!r}")
                continue
            key = isp.dedup_key(text)
            if key in seen:      # "Islamabad" and "islamabad" are one utterance
                continue
            seen.add(key)
            pool.append(text)
        template.pool = pool
    led.gate("rendered_clean", not dirty,
             f"{len(dirty)} rendered row(s) fail text_problems(); first: {dirty[:2]}"
             if dirty else
             f"{sum(len(t.pool) for t in templates)} candidate rows across "
             f"{len(templates)} templates, all clean and deduplicated")


def fit_caps(want: dict[str, int], caps: dict[str, int]) -> tuple[dict[str, int], int]:
    """Clip a per-language plan to what the templates can deliver, moving the
    overflow to the languages with headroom. Returns the plan and whatever could
    not be placed anywhere -- the number the feasibility gate refuses on."""
    out = dict(want)
    for _ in range(len(out) + 2):
        overflow = 0
        for lang in out:
            if out[lang] > caps[lang]:
                overflow += out[lang] - caps[lang]
                out[lang] = caps[lang]
        if overflow == 0:
            return out, 0
        headroom = {lang: caps[lang] - out[lang] for lang in out}
        movable = min(overflow, sum(headroom.values()))
        if movable <= 0:
            return out, overflow
        for lang, extra in largest_remainder(
                {lang: float(room) for lang, room in headroom.items()}, movable).items():
            out[lang] += extra
    return out, max(0, sum(want.values()) - sum(out.values()))


def apply_floors(rows: dict[str, int], authored: dict[str, int],
                 caps: dict[str, int]) -> tuple[dict[str, int], list[str]]:
    """Enforce ``MIN_LANG_ROWS_PER_INTENT`` by moving rows from the language with
    the largest surplus. The floors exist so no intent is monolingual: a
    ``wallet_balance`` classifier trained on English alone answers the Roman Urdu
    half of the user base with its prior."""
    moved: list[str] = []
    for lang in isp.LANGS:
        floor = isp.MIN_LANG_ROWS_PER_INTENT[lang]
        while authored[lang] + rows[lang] < floor and rows[lang] < caps[lang]:
            surplus = {
                other: authored[other] + rows[other] - isp.MIN_LANG_ROWS_PER_INTENT[other]
                for other in isp.LANGS if other != lang and rows[other] > 0
            }
            donors = sorted((o for o, extra in surplus.items() if extra > 0),
                            key=lambda o: (-surplus[o], o))
            if not donors:
                break
            rows[donors[0]] -= 1
            rows[lang] += 1
            moved.append(f"{donors[0]}->{lang}")
    return rows, moved


def plan_quota(templates: list[Template], authored: list[Hand], per_intent: int,
               led: Ledger) -> tuple[dict[tuple[str, str], int], dict[str, object]]:
    """How many template rows each (intent, lang) must produce.

    Authored rows count toward the intent's total and toward its language budget,
    so an intent with 18 authored Roman Urdu rows generates fewer Roman Urdu rows
    -- the budget describes the CORPUS, not the generator's output."""
    by_il: dict[tuple[str, str], list[Template]] = defaultdict(list)
    for template in templates:
        by_il[(template.intent, template.lang)].append(template)
    for key in by_il:
        by_il[key].sort(key=lambda t: t.template_id)
    authored_count = Counter((hand.intent, hand.lang) for hand in authored)

    plan: dict[tuple[str, str], int] = {}
    thin_langs: list[str] = []
    tight: list[str] = []
    infeasible: list[str] = []
    report: dict[str, object] = {}

    for intent in isp.INTENTS:
        have = {lang: authored_count[(intent, lang)] for lang in isp.LANGS}
        caps = {lang: sum(len(t.pool) for t in by_il[(intent, lang)])
                for lang in isp.LANGS}
        spec_caps = {lang: isp.capacity_budget(
            [t.pattern for t in by_il[(intent, lang)]], lang) for lang in isp.LANGS}
        want = {lang: max(0.0, isp.LANG_BUDGET[lang] * per_intent - have[lang])
                for lang in isp.LANGS}
        rows = largest_remainder(want, max(0, per_intent - sum(have.values())))
        rows, unplaced = fit_caps(rows, caps)
        rows, moved = apply_floors(rows, have, caps)

        for lang in isp.LANGS:
            count = len(by_il[(intent, lang)])
            if count < isp.MIN_TEMPLATES_PER_LANG:
                thin_langs.append(f"{intent}/{lang}={count}")
            if rows[lang] and caps[lang] < isp.TEMPLATE_CAPACITY_MARGIN * rows[lang]:
                tight.append(f"{intent}/{lang} cap {caps[lang]} < "
                             f"{isp.TEMPLATE_CAPACITY_MARGIN:.2f}x{rows[lang]}")
            plan[(intent, lang)] = rows[lang]
        if unplaced:
            infeasible.append(f"{intent} short {unplaced} row(s) "
                              f"(caps {caps}, authored {have})")
        report[intent] = {
            "authored": have, "template_rows": rows, "effective_capacity": caps,
            "spec_capacity": spec_caps, "floor_moves": moved,
            "unplaced": unplaced,
        }

    led.gate("templates_per_lang", not thin_langs,
             f"{len(thin_langs)} below {isp.MIN_TEMPLATES_PER_LANG}: {thin_langs[:6]}"
             if thin_langs else
             f"every (intent, lang) has >= {isp.MIN_TEMPLATES_PER_LANG} templates")
    led.gate("capacity_margin", not tight,
             f"{len(tight)} tight: {tight[:6]}" if tight else
             f"every (intent, lang) can deliver >= "
             f"{isp.TEMPLATE_CAPACITY_MARGIN:.2f}x its quota")
    led.gate("quota_feasible", not infeasible,
             f"{len(infeasible)}: {infeasible[:3]}" if infeasible else
             f"{per_intent} rows reachable for all {len(isp.INTENTS)} intents")
    return plan, report


def draw_rows(templates_for_il: list[Template], need: int, seen: set[str],
              exam_keys: set[str], stats: Counter[str]) -> list[dict[str, str]]:
    """Take ``need`` rows from a (intent, lang)'s templates, evenly and in order.

    A candidate is skipped if it exact-matches an exam row (contamination, and the
    exam always wins) or if it repeats a row the intent already has. Skipping is
    why the allocator needs the top-up pass below: an even allocation of 40 rows
    over 8 templates that loses 2 to duplicates must go back for 2 more, or the
    intent quietly ships 38."""
    caps = [len(template.pool) for template in templates_for_il]
    take = water_fill(caps, need)
    cursor = [0] * len(templates_for_il)
    out: list[dict[str, str]] = []

    def pull(index: int, quota: int) -> int:
        template = templates_for_il[index]
        got = 0
        while got < quota and cursor[index] < len(template.pool):
            text = template.pool[cursor[index]]
            cursor[index] += 1
            key = isp.dedup_key(text)
            if key in exam_keys:
                stats["exam_exact_skipped"] += 1
                continue
            if key in seen:
                stats["duplicate_skipped"] += 1
                continue
            seen.add(key)
            template.used += 1
            out.append({"id": "", "text": text, "intent": template.intent,
                        "lang": template.lang, "source": "template",
                        "template_id": template.template_id,
                        "phenomena": template.phenomena, "split": ""})
            got += 1
        return got

    for index, quota in enumerate(take):
        pull(index, quota)
    while len(out) < need:
        progressed = False
        for index in range(len(templates_for_il)):
            if len(out) >= need:
                break
            if pull(index, 1):
                progressed = True
        if not progressed:
            break
    return out


def near_dup_filter(rows: list[dict[str, str]], exam: list[Hand],
                    led: Ledger) -> tuple[list[dict[str, str]], dict[str, object]]:
    """Drop every corpus row that is a near-duplicate of an exam row.

    Exact matches are already gone (the draw skipped them and authored collisions
    were dropped); this catches "kal shaam football ground dikhao" against "kal
    shaam ka football ground dikhao dijiye", which no amount of exact matching
    finds. Precomputes both shingle and word sets so 1,680 x 150 comparisons cost
    two set operations each instead of four set constructions."""
    exam_sets = [(hand, isp.shingles(hand.text), isp.words(hand.text))
                 for hand in exam]
    kept: list[dict[str, str]] = []
    dropped: list[dict[str, object]] = []
    by_metric: Counter[str] = Counter()
    worst = 0.0
    for row in rows:
        row_shingles = isp.shingles(row["text"])
        row_words = isp.words(row["text"])
        hit: tuple[float, str, Hand] | None = None
        for hand, hand_shingles, hand_words in exam_sets:
            char_score = isp.jaccard(row_shingles, hand_shingles)
            word_score = isp.jaccard(row_words, hand_words)
            score, metric = ((word_score, "word_set") if word_score > char_score
                             else (char_score, "char_shingle"))
            worst = max(worst, score)
            if score >= isp.NEAR_DUP_CONTAM and (hit is None or score > hit[0]):
                hit = (score, metric, hand)
        if hit is None:
            kept.append(row)
            continue
        by_metric[hit[1]] += 1
        dropped.append({
            "text": row["text"], "intent": row["intent"],
            "source": row["source"], "template_id": row["template_id"],
            "exam_id": hit[2].row_id, "exam_text": hit[2].text,
            "score": round(hit[0], 4), "metric": hit[1],
        })
    led.warn("exam_near_dup", True,
             f"{len(dropped)} corpus row(s) dropped at >= {isp.NEAR_DUP_CONTAM:.2f} "
             f"({dict(by_metric)}), max score seen {worst:.3f}")
    return kept, {
        "threshold": isp.NEAR_DUP_CONTAM,
        "metric": "max(char 4-shingle Jaccard, word-set Jaccard)",
        "dropped": len(dropped),
        "by_metric": dict(by_metric),
        "max_score_seen": round(worst, 4),
        "examples": dropped[:20],
    }


def assign_split(rows: list[dict[str, str]], seed: int,
                 led: Ledger) -> dict[str, object]:
    """Stratified per intent, GROUPED by ``template_id``.

    Two independent draws per intent -- one over its authored rows, one over its
    template groups -- so validation contains both hand-written and generated
    rows at roughly the designed fraction. Doing it in one pass lets a greedy fill
    take all its rows from whichever source has the convenient group sizes, and
    "97% on validation" then means "97% on generated rows only".

    An authored row is its own group of one, which is what makes the no-group-in-
    both-splits check uniform over the whole corpus."""
    by_intent: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        by_intent[row["intent"]].append(row)

    per_intent: dict[str, dict[str, object]] = {}
    thin: list[str] = []
    for intent in isp.INTENTS:
        intent_rows = by_intent[intent]
        total = len(intent_rows)
        authored = [row for row in intent_rows if row["source"] == "authored"]
        groups: dict[str, list[dict[str, str]]] = defaultdict(list)
        for row in intent_rows:
            if row["source"] == "template":
                groups[row["template_id"]].append(row)

        rng = random.Random(isp.stable_seed(seed, "split", intent))
        want_val = round(isp.VAL_FRACTION * total)
        ceiling = int(isp.VAL_FRACTION_MAX * total)

        authored_val = rng.sample(sorted(row["template_id"] for row in authored),
                                 min(len(authored), round(isp.VAL_FRACTION * len(authored))))
        chosen_authored = set(authored_val)
        count = len(chosen_authored)

        order = sorted(groups)
        rng.shuffle(order)
        chosen_groups: set[str] = set()
        for template_id in order:
            size = len(groups[template_id])
            if count >= want_val:
                break
            if count + size <= ceiling:
                chosen_groups.add(template_id)
                count += size

        for row in intent_rows:
            in_val = (row["template_id"] in chosen_authored if row["source"] == "authored"
                      else row["template_id"] in chosen_groups)
            row["split"] = "val" if in_val else "train"

        val_rows = [row for row in intent_rows if row["split"] == "val"]
        fraction = len(val_rows) / total if total else 0.0
        per_intent[intent] = {
            "rows": total, "val": len(val_rows),
            "val_fraction": round(fraction, 4),
            "val_authored": len(chosen_authored),
            "val_template_groups": len(chosen_groups),
            "train_template_groups": len(groups) - len(chosen_groups),
        }
        if len(chosen_groups) < 2 or not chosen_authored:
            thin.append(f"{intent} ({len(chosen_groups)} groups, "
                        f"{len(chosen_authored)} authored)")

    fractions = {intent: float(info["val_fraction"]) for intent, info in per_intent.items()}
    out_of_band = {intent: value for intent, value in fractions.items()
                   if not (isp.VAL_FRACTION_MIN <= value <= isp.VAL_FRACTION_MAX)}
    led.gate("split_fraction", not out_of_band,
             f"outside [{isp.VAL_FRACTION_MIN:.2f},{isp.VAL_FRACTION_MAX:.2f}]: "
             f"{out_of_band}" if out_of_band else
             f"every intent's val share in "
             f"[{min(fractions.values()):.3f},{max(fractions.values()):.3f}]")

    leaked = sorted({row["template_id"] for row in rows if row["split"] == "val"} &
                    {row["template_id"] for row in rows if row["split"] == "train"})
    led.gate("split_grouped", not leaked,
             f"{len(leaked)} group(s) in both splits: {leaked[:4]}" if leaked else
             "no template_id appears in both train and val -- val phrasings are unseen")
    led.gate("split_val_composition", not thin,
             f"{len(thin)} intent(s) with < 2 val template groups or no authored "
             f"val row: {thin[:4]}" if thin else
             "every intent's val set mixes authored rows with >= 2 unseen templates")
    return {"grouped_by": "template_id", "fraction_target": isp.VAL_FRACTION,
            "per_intent": per_intent}


# The pipeline
def generate(per_intent: int, seed: int, led: Ledger,
             templates_path: Path = TEMPLATES_PATH,
             authored_path: Path = AUTHORED_PATH,
             exam_path: Path = EXAM_PATH,
             exam_meta_path: Path = EXAM_META_PATH) -> dict[str, object]:
    """Load, allocate, expand, decontaminate, split. Pure with respect to disk:
    called twice with the same seed it must return the same rows, which is what
    the determinism gate in ``main`` checks."""
    templates = load_templates(templates_path, led)
    authored = load_hand(authored_path, AUTHORED_COLUMNS, _RE_AUTHORED_ID,
                         "authored", led)
    exam = load_hand(exam_path, EXAM_COLUMNS, re.compile(r"^at-\d{3,}$"), "exam", led)
    exam_digest = check_exam_lock(exam_path, exam_meta_path, led)

    led.gate("intent_coverage",
             {template.intent for template in templates} == set(isp.INTENTS)
             and {hand.intent for hand in authored} == set(isp.INTENTS),
             f"templates cover {len({t.intent for t in templates})}/"
             f"{len(isp.INTENTS)}, authored {len({h.intent for h in authored})}/"
             f"{len(isp.INTENTS)}")
    authored_per_intent = Counter(hand.intent for hand in authored)
    short_authored = {intent: authored_per_intent[intent] for intent in isp.INTENTS
                      if authored_per_intent[intent] < isp.AUTHORED_MIN_PER_INTENT}
    led.gate("authored_floor",
             not short_authored and len(authored) >= isp.AUTHORED_MIN_TOTAL,
             f"{len(authored)} rows (need {isp.AUTHORED_MIN_TOTAL}), "
             f"short per intent: {short_authored}" if
             (short_authored or len(authored) < isp.AUTHORED_MIN_TOTAL) else
             f"{len(authored)} hand-written rows, "
             f">= {isp.AUTHORED_MIN_PER_INTENT} for every intent")

    if not led.passed:      # a broken input makes every later number meaningless
        return {"rows": [], "aborted": True, "exam_sha256": exam_digest,
                "templates": templates, "authored": authored, "exam": exam}

    build_pools(templates, seed, led)
    plan, plan_report = plan_quota(templates, authored, per_intent, led)

    by_il: dict[tuple[str, str], list[Template]] = defaultdict(list)
    for template in templates:
        by_il[(template.intent, template.lang)].append(template)
    for key in by_il:
        by_il[key].sort(key=lambda t: t.template_id)

    exam_keys = {isp.dedup_key(hand.text) for hand in exam}
    # Seeded with explicit zeros so the metadata always carries the counters. An
    # absent key and a key that is zero read the same way in JSON, and "nothing was
    # skipped" is a result worth stating rather than an empty object to interpret.
    stats: Counter[str] = Counter(
        {"exam_exact_skipped": 0, "duplicate_skipped": 0,
         "authored_exam_exact_dropped": 0})
    rows: list[dict[str, str]] = []
    for intent in isp.INTENTS:
        seen: set[str] = set()
        for hand in authored:
            if hand.intent != intent:
                continue
            key = isp.dedup_key(hand.text)
            if key in exam_keys:
                stats["authored_exam_exact_dropped"] += 1
                continue
            seen.add(key)
            rows.append({"id": "", "text": hand.text, "intent": hand.intent,
                         "lang": hand.lang, "source": "authored",
                         "template_id": hand.row_id, "phenomena": hand.phenomena,
                         "split": ""})
        for lang in isp.LANGS:
            rows.extend(draw_rows(by_il[(intent, lang)], plan[(intent, lang)],
                                  seen, exam_keys, stats))

    rows, contamination = near_dup_filter(rows, exam, led)
    contamination.update({
        "exam_file": exam_path.name,
        "exam_sha256": exam_digest,
        "exam_rows": len(exam),
        "exact_skipped_during_draw": stats["exam_exact_skipped"],
        "authored_exact_dropped": stats["authored_exam_exact_dropped"],
        "limitation": "the exam is compared against every corpus row, generated "
                      "and authored alike, and only corpus rows are ever dropped",
    })

    by_key: dict[str, set[str]] = defaultdict(set)
    for row in rows:
        by_key[isp.dedup_key(row["text"])].add(row["intent"])
    contradictions = sorted(key for key, intents in by_key.items() if len(intents) > 1)
    led.gate("no_label_contradiction", not contradictions,
             f"{len(contradictions)} text(s) under two intents: "
             f"{[(key, sorted(by_key[key])) for key in contradictions[:3]]}"
             if contradictions else
             f"all {len(by_key)} distinct utterances carry exactly one label")

    split_report = assign_split(rows, seed, led)
    rows.sort(key=lambda row: (isp.INTENTS.index(row["intent"]),
                               isp.LANGS.index(row["lang"]),
                               row["source"], row["template_id"], row["text"]))
    for index, row in enumerate(rows, start=1):
        row["id"] = f"it-{index:04d}"
    return {"rows": rows, "aborted": False, "templates": templates,
            "authored": authored, "exam": exam, "exam_sha256": exam_digest,
            "plan": plan_report, "contamination": contamination,
            "split": split_report, "draw_stats": dict(stats)}


def audit(rows: list[dict[str, str]], templates: list[Template],
          led: Ledger) -> dict[str, object]:
    """Post-generation gates and the census that goes into the metadata."""
    per_intent = Counter(row["intent"] for row in rows)
    grid = Counter((row["intent"], row["lang"]) for row in rows)

    out_of_band = {intent: per_intent[intent] for intent in isp.INTENTS
                   if not (isp.ROWS_PER_INTENT_MIN <= per_intent[intent]
                           <= isp.ROWS_PER_INTENT_MAX)}
    led.gate("rows_per_intent", not out_of_band,
             f"outside [{isp.ROWS_PER_INTENT_MIN},{isp.ROWS_PER_INTENT_MAX}]: "
             f"{out_of_band}" if out_of_band else
             f"all {len(per_intent)} intents in [{min(per_intent.values())},"
             f"{max(per_intent.values())}]")
    led.gate("rows_total", isp.TOTAL_ROWS_MIN <= len(rows) <= isp.TOTAL_ROWS_MAX,
             f"{len(rows)} rows (want [{isp.TOTAL_ROWS_MIN},{isp.TOTAL_ROWS_MAX}])")

    short = {f"{intent}/{lang}": grid[(intent, lang)]
             for intent in isp.INTENTS for lang in isp.LANGS
             if grid[(intent, lang)] < isp.MIN_LANG_ROWS_PER_INTENT[lang]}
    led.gate("lang_floor", not short,
             f"{len(short)} cell(s) below floor: {short}" if short else
             "every intent meets its per-language floor "
             + ", ".join(f"{lang}>={isp.MIN_LANG_ROWS_PER_INTENT[lang]}"
                         for lang in isp.LANGS))

    used = Counter(row["template_id"] for row in rows if row["source"] == "template")
    over = {tid: count for tid, count in used.items()
            if count > isp.MAX_ROWS_PER_TEMPLATE}
    led.gate("rows_per_template", not over,
             f"over {isp.MAX_ROWS_PER_TEMPLATE}: {over}" if over else
             f"max {max(used.values())} rows from one template "
             f"(cap {isp.MAX_ROWS_PER_TEMPLATE}), mean "
             f"{sum(used.values()) / max(1, len(used)):.1f}")
    unused = sorted(template.template_id for template in templates
                    if template.template_id not in used)
    led.warn("templates_used", not unused,
             f"{len(unused)} template(s) contributed no rows: {unused[:6]}"
             if unused else f"all {len(templates)} templates contributed")

    duplicates = [key for key, count in
                  Counter(isp.dedup_key(row["text"]) for row in rows).items()
                  if count > 1]
    led.gate("corpus_distinct", not duplicates,
             f"{len(duplicates)} repeated utterance(s)" if duplicates else
             f"{len(rows)} rows, {len(rows)} distinct utterances")

    ids = [row["id"] for row in rows]
    led.gate("ids_unique", len(set(ids)) == len(ids),
             f"{len(ids) - len(set(ids))} duplicate id(s)" if
             len(set(ids)) != len(ids) else f"{ids[0]}..{ids[-1]}")

    # out_of_scope is the fallback class; it must be as well populated as any
    # other, and its ROWS must not be recognisable by their entities.
    topic_words = {value.casefold() for slot in ("sport", "venue", "venue_word")
                   for lang in isp.LANGS for value in isp.slot_values(slot, lang)}
    oos_rows = [row for row in rows if row["intent"] == "out_of_scope"]
    with_topic = [row["text"] for row in oos_rows
                  if isp.words(row["text"]) & topic_words]
    led.warn("out_of_scope_topic_words", True,
             f"{len(with_topic)} of {len(oos_rows)} out_of_scope rows mention a "
             f"sport or venue word -- deliberate: the fallback class must not be "
             f"identifiable by the ABSENCE of domain vocabulary")

    lengths = [len(row["text"]) for row in rows]
    word_counts = [len(row["text"].split()) for row in rows]
    return {
        "per_intent": {intent: per_intent[intent] for intent in isp.INTENTS},
        "langs": {lang: sum(1 for row in rows if row["lang"] == lang)
                  for lang in isp.LANGS},
        "sources": {source: sum(1 for row in rows if row["source"] == source)
                    for source in isp.SOURCES},
        "splits": {split: sum(1 for row in rows if row["split"] == split)
                   for split in isp.SPLITS},
        "intent_x_lang": {f"{intent}|{lang}": grid[(intent, lang)]
                          for intent in isp.INTENTS for lang in isp.LANGS},
        "phenomena": dict(sorted(
            Counter(tag for row in rows for tag in tags_of(row["phenomena"])).items(),
            key=lambda item: (-item[1], item[0]))),
        "per_template": {
            "templates": len(templates), "used": len(used), "unused": len(unused),
            "max": max(used.values()) if used else 0,
            "min": min(used.values()) if used else 0,
            "mean": round(sum(used.values()) / max(1, len(used)), 2),
            "cap": isp.MAX_ROWS_PER_TEMPLATE,
            "unused_ids": unused,
        },
        "text_length": {
            "chars_min": min(lengths), "chars_max": max(lengths),
            "chars_mean": round(sum(lengths) / len(lengths), 1),
            "words_min": min(word_counts), "words_max": max(word_counts),
            "words_mean": round(sum(word_counts) / len(word_counts), 2),
        },
    }


def shortcut_report(rows: list[dict[str, str]], led: Ledger) -> dict[str, object]:
    """Two questions a corpus census cannot answer on its own.

    1. Can the label be predicted from something that is not the utterance? If
       Roman Urdu rows were mostly ``find_venue`` and English rows mostly
       ``my_bookings``, a classifier could score well by detecting LANGUAGE. Same
       for source, and for the split itself.
    2. Does validation actually test generalisation? If every word in val also
       appears in train, val measures recall of seen vocabulary. The out-of-
       vocabulary rate is reported, not gated: a small OOV rate on a
       template-generated corpus is expected and honest -- the grouped split is
       what carries the guarantee, this number just makes its size visible."""
    associations: dict[str, object] = {}
    for name, key in (("lang_x_intent", "lang"), ("source_x_intent", "source"),
                      ("split_x_intent", "split")):
        v, chi2, dof = cramers_v([(row[key], row["intent"]) for row in rows])
        associations[name] = {"cramers_v": round(v, 4), "chi2": round(chi2, 2),
                             "dof": dof, "n": len(rows)}
    worst = max(("lang_x_intent", "source_x_intent"),
                key=lambda name: associations[name]["cramers_v"])  # type: ignore[index]
    led.warn("shortcut_association",
             all(associations[name]["cramers_v"] < isp.CRAMERS_V_WARN  # type: ignore[index]
                 for name in ("lang_x_intent", "source_x_intent")),
             f"strongest is {worst} V={associations[worst]['cramers_v']} "  # type: ignore[index]
             f"(warn at {isp.CRAMERS_V_WARN:.2f}); split_x_intent V="
             f"{associations['split_x_intent']['cramers_v']} "  # type: ignore[index]
             f"(stratification, want ~0)")

    train_vocab = {word for row in rows if row["split"] == "train"
                   for word in isp.words(row["text"])}
    val_rows = [row for row in rows if row["split"] == "val"]
    val_vocab = {word for row in val_rows for word in isp.words(row["text"])}
    unseen = val_vocab - train_vocab
    rows_with_unseen = sum(1 for row in val_rows
                           if isp.words(row["text"]) - train_vocab)
    led.warn("val_generalisation", True,
             f"{rows_with_unseen}/{len(val_rows)} val rows contain a token unseen "
             f"in train ({len(unseen)} of {len(val_vocab)} val types)")
    associations["vocabulary"] = {
        "train_types": len(train_vocab), "val_types": len(val_vocab),
        "val_types_unseen": len(unseen),
        "val_rows_with_unseen_token": rows_with_unseen,
        "val_rows": len(val_rows),
    }
    return associations


def write_corpus(rows: list[dict[str, str]], path: Path) -> str:
    """Write the CSV and return its sha256.

    ``lineterminator="\n"`` on purpose: the default is CRLF, and a corpus whose
    bytes depend on which platform generated it cannot be pinned by sha256 -- the
    gate would fail on a colleague's machine for a reason that has nothing to do
    with the data."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(CSV_COLUMNS)
        for row in rows:
            writer.writerow([row[column] for column in CSV_COLUMNS])
    return sha256_file(path)


def render_table(rows: list[dict[str, str]]) -> str:
    """One line per intent: rows, language mix, split, sources. The only human
    view of the corpus that fits on a screen."""
    grid = Counter((row["intent"], row["lang"]) for row in rows)
    per_intent = Counter(row["intent"] for row in rows)
    val = Counter(row["intent"] for row in rows if row["split"] == "val")
    authored = Counter(row["intent"] for row in rows if row["source"] == "authored")
    width = max(len(intent) for intent in isp.INTENTS)
    lines = [f"  {'intent'.ljust(width)}  rows   en  mix   ru   auth   val  val%",
             f"  {'-' * width}  ----  ---  ---  ---  -----  ----  ----"]
    for intent in isp.INTENTS:
        total = per_intent[intent]
        lines.append(
            f"  {intent.ljust(width)}  {total:>4}  "
            f"{grid[(intent, 'en')]:>3}  {grid[(intent, 'mix')]:>3}  "
            f"{grid[(intent, 'ru')]:>3}  {authored[intent]:>5}  "
            f"{val[intent]:>4}  {100 * val[intent] / max(1, total):>4.1f}")
    lines.append(
        f"  {'TOTAL'.ljust(width)}  {len(rows):>4}  "
        f"{sum(1 for r in rows if r['lang'] == 'en'):>3}  "
        f"{sum(1 for r in rows if r['lang'] == 'mix'):>3}  "
        f"{sum(1 for r in rows if r['lang'] == 'ru'):>3}  "
        f"{sum(1 for r in rows if r['source'] == 'authored'):>5}  "
        f"{sum(1 for r in rows if r['split'] == 'val'):>4}  "
        f"{100 * sum(1 for r in rows if r['split'] == 'val') / max(1, len(rows)):>4.1f}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate the assistant intent corpus (S.6 Wave A, model #4)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED,
                        help=f"RNG seed (default {DEFAULT_SEED}); same seed, same bytes")
    parser.add_argument("--per-intent", type=int, default=isp.ROWS_PER_INTENT_TARGET,
                        help=f"target rows per intent (default "
                             f"{isp.ROWS_PER_INTENT_TARGET}, must stay inside "
                             f"[{isp.ROWS_PER_INTENT_MIN},{isp.ROWS_PER_INTENT_MAX}])")
    parser.add_argument("--out", type=Path, default=OUT_PATH)
    parser.add_argument("--meta", type=Path, default=META_PATH)
    parser.add_argument("--quiet", action="store_true",
                        help="print only the RESULT line and any failure detail")
    parser.add_argument("--no-write", action="store_true",
                        help="run every gate, write nothing")
    args = parser.parse_args(argv)

    led = Ledger()
    led.gate("per_intent_in_range",
             isp.ROWS_PER_INTENT_MIN <= args.per_intent <= isp.ROWS_PER_INTENT_MAX,
             f"--per-intent {args.per_intent} outside "
             f"[{isp.ROWS_PER_INTENT_MIN},{isp.ROWS_PER_INTENT_MAX}]"
             if not (isp.ROWS_PER_INTENT_MIN <= args.per_intent
                     <= isp.ROWS_PER_INTENT_MAX) else f"{args.per_intent} rows/intent")

    result = generate(args.per_intent, args.seed, led)
    rows: list[dict[str, str]] = result["rows"]  # type: ignore[assignment]
    if not rows:
        print(f"Inputs:  {TEMPLATES_PATH.name}, {AUTHORED_PATH.name}, {EXAM_PATH.name}")
        print(led.render())
        print("\nRESULT: FAIL -- inputs did not validate; nothing was generated.")
        return 1

    census = audit(rows, result["templates"], led)  # type: ignore[arg-type]
    shortcuts = shortcut_report(rows, led)

    replay = generate(args.per_intent, args.seed, Ledger())
    signature = [tuple(row[column] for column in CSV_COLUMNS) for row in rows]
    replayed = [tuple(row[column] for column in CSV_COLUMNS)
                for row in replay["rows"]]  # type: ignore[union-attr]
    led.gate("determinism", signature == replayed,
             "seed replays to the same rows, ids and splits" if signature == replayed
             else f"replay differs: {sum(1 for a, b in zip(signature, replayed) if a != b)}"
                  f" row(s) of {len(signature)} changed")

    target = args.out if led.passed else REJECT_PATH
    meta_target = args.meta if led.passed else REJECT_PATH.with_suffix(".json")
    digest = write_corpus(rows, target) if not args.no_write else ""

    meta = {
        "generated_by": "training/gen_intents.py",
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "wave": "S.6 Wave A",
        "model": "#4 SportLynk assistant -- intent classifier corpus",
        "seed": args.seed,
        "per_intent_target": args.per_intent,
        "intent_spec_version": isp.INTENT_SPEC_VERSION,
        "intent_spec_fingerprint": isp.intent_spec_fingerprint(),
        "dataset_spec_version": isp.DATASET_SPEC_VERSION,
        "dataset_spec_fingerprint": isp.dataset_spec_fingerprint(),
        "inputs": {
            "templates": {"file": TEMPLATES_PATH.name,
                          "rows": len(result["templates"]),  # type: ignore[arg-type]
                          "sha256": sha256_file(TEMPLATES_PATH)},
            "authored": {"file": AUTHORED_PATH.name,
                         "rows": len(result["authored"]),  # type: ignore[arg-type]
                         "sha256": sha256_file(AUTHORED_PATH)},
            "exam": {"file": EXAM_PATH.name,
                     "rows": len(result["exam"]),  # type: ignore[arg-type]
                     "sha256": result["exam_sha256"],
                     "used_for": "exclusion only -- never mixed into the corpus"},
        },
        "rows": len(rows),
        "columns": list(CSV_COLUMNS),
        "census": census,
        "allocation": result["plan"],
        "draw": result["draw_stats"],
        "contamination_gate": result["contamination"],
        "split": result["split"],
        "independence": shortcuts,
        "checks": led.as_json(),
        "all_passed": led.passed,
        "sha256": digest,
        "output": str(target.relative_to(ROOT)).replace("\\", "/"),
        "reproduce": f"python training/gen_intents.py --seed {args.seed} "
                     f"--per-intent {args.per_intent}",
    }
    if not args.no_write:
        meta_target.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
                               encoding="utf-8")

    if not args.quiet:
        print(f"Corpus:      {target.relative_to(ROOT)}"
              f"{'  (NOT WRITTEN: --no-write)' if args.no_write else ''}")
        print(f"Label spec:  {isp.INTENT_SPEC_VERSION} / {isp.intent_spec_fingerprint()}")
        print(f"Data spec:   {isp.DATASET_SPEC_VERSION} / {isp.dataset_spec_fingerprint()}")
        print(f"Seed:        {args.seed}   target {args.per_intent} rows/intent")
        print(f"sha256:      {digest or '(not written)'}")
        print()
        print(render_table(rows))
        print()
        print(led.render())

    if led.passed:
        if not args.quiet:
            print(f"\nRESULT: PASS -- {len(rows)} rows, "
                  f"{census['splits']['train']} train / "  # type: ignore[index]
                  f"{census['splits']['val']} val, "  # type: ignore[index]
                  f"{len(result['exam'])} exam rows excluded and untouched.")  # type: ignore[arg-type]
        else:
            print(f"RESULT: PASS -- {len(rows)} rows, sha256 {digest[:12] or '-'}..")
        return 0
    print(f"\nRESULT: FAIL -- {len(led.failures)} hard gate(s) failed: "
          f"{[name for name, _, _, _ in led.failures]}")
    if not args.no_write:
        print(f"Rejected corpus written to {target.relative_to(ROOT)} for inspection; "
              f"{args.out.name} was left untouched.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
