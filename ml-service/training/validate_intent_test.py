"""Validate and fingerprint the assistant intent exam (assistant_test.csv).

WHY THIS EXISTS
---------------
`data/assistant/assistant_test.csv` is the *exam* for Model #4 (the SportLynk
assistant's intent classifier). It is 150 utterances written by hand, never
generated from a template, and never trained on. Every number the intent model
eventually reports -- accuracy, the per-class confusion matrix the assistant definition
of done asks for -- is only as trustworthy as this file.

So before any training run reports a figure against it, we must be able to prove
-- mechanically, on every run -- that the exam itself is:

  * structurally intact   (150 rows, the exact 6 columns, unique ids),
  * balanced as designed  (the 15 x 3 grid of INTENT x LANG from intent_spec,
                           not silently re-weighted towards the easy classes),
  * contract-compatible   (every row passes the frozen text_problems() judge, so
                           no row is unscoreable or secretly malformed),
  * internally clean      (no exact or near-duplicate rows inflating a metric,
                           and no utterance carrying two different labels),
  * disjoint from training (no hand-written *training* row restates an exam row),
  * hard on purpose       (boundary rows for every intent -- the confusable
                           pairs are the whole reason the exam is hand-written),
  * pinned by sha256      (so the exam cannot drift between runs without
                           gen_intents.py and the trainer noticing).

It is the sibling of `validate_domain_test.py`, which does the same job for the
sentiment exam, and it emits `assistant_test_meta.json` -- the sha256 plus the
full census -- which `gen_intents.py` compares against the live file and refuses
to proceed when the two disagree.

It NEVER writes to, samples from, repairs, or re-balances the exam. Read-only.
The exam is the measuring instrument: an instrument you adjust after reading it
is no longer measuring anything.

Run:
    ./.venv/Scripts/python.exe training/validate_intent_test.py
    ./.venv/Scripts/python.exe training/validate_intent_test.py --quiet
    ./.venv/Scripts/python.exe training/validate_intent_test.py --no-write

Exit code 0 = exam is valid and fingerprint written; 1 = a hard check failed.
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime as _dt
import hashlib
import json
import re
import sys
from pathlib import Path

# Windows consoles default to cp1252; exam text and detail strings carry Roman
# Urdu, punctuation and the odd emoji. Never let rendering crash a validation run.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

# Contract linkage
# Import the same frozen spec the corpus builder and the model will use. If this
# import fails the exam cannot be checked against the real contract, and there is
# no silent fallback: the run stops.
ROOT = Path(__file__).resolve().parents[1]  # ml-service/
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from app.core import intent_spec as isp  # noqa: E402

# Paths
EXAM_PATH = ROOT / "data" / "assistant" / "assistant_test.csv"
META_PATH = ROOT / "data" / "assistant" / "assistant_test_meta.json"
AUTHORED_PATH = ROOT / "data" / "assistant" / "authored_intents.csv"

# Pinned expectations
# Hard-coded on purpose. The census below was verified against the committed file
# on 2026-08-24; this script's job is to scream if the exam is ever edited,
# re-balanced or truncated. Changing the exam deliberately means changing these
# constants in the same commit -- exactly the reviewable act it should be.
#
# The grid is not restated here: it comes from intent_spec (EXAM_ROWS_PER_INTENT
# and EXAM_LANG_QUOTA), because the design of the exam is part of the frozen
# contract, and a second copy of a number is a second thing to keep in sync.
EXPECTED_COLUMNS = ["id", "text", "intent", "lang", "phenomena", "notes"]
EXPECTED_TOTAL = isp.EXAM_ROWS_PER_INTENT * len(isp.INTENTS)  # 10 x 15 = 150
ID_PATTERN = re.compile(r"^at-\d{3,}$")

# Phenomena the exam must exercise, as minimums (tags are multi-valued, so these
# are row counts carrying the tag). These are the hard cases the classifier is
# graded on, not a description of what happens to be in the file: every number
# here sits comfortably below the actual count, so an edit that thins out the
# hard rows fails while an edit that adds more does not.
REQUIRED_PHENOMENA = {
    "boundary": 40,      # nearest-neighbour intents -- the point of the exam
    "code_switch": 25,   # EN/Roman Urdu mixing inside one utterance
    "indirect": 25,      # intent implied, never named ("kal khelna hai")
    "short": 15,         # two-to-three word queries, no context
    "numeric": 10,       # dates, times, counts, budgets
    "negation": 8,       # "cancel nahi karna", "not tomorrow"
}
MIN_PHENOMENA_TAGS = 15          # of the 18 in the contract
MIN_BOUNDARY_PER_INTENT = 1      # every class must have at least one hard row
NEAR_DUP_AUTHORED = isp.NEAR_DUP_CONTAM  # 0.80: training row restates an exam row


# Tiny check ledger
class Ledger:
    """Accumulates named checks; renders a table; decides pass/fail."""

    def __init__(self) -> None:
        self.rows: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.rows.append((name, bool(ok), detail))
        return bool(ok)

    @property
    def passed(self) -> bool:
        return all(ok for _, ok, _ in self.rows)

    def render(self) -> str:
        width = max((len(n) for n, _, _ in self.rows), default=4)
        lines = []
        for name, ok, detail in self.rows:
            line = f"  [{'PASS' if ok else 'FAIL'}] {name.ljust(width)}"
            if detail:
                line += f"  {detail}"
            lines.append(line)
        return "\n".join(lines)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_rows(path: Path) -> list[dict[str, str]]:
    # utf-8-sig strips a BOM if one crept in from a spreadsheet round-trip.
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def _tags(row: dict[str, str]) -> list[str]:
    return [t.strip() for t in (row.get("phenomena") or "").split(";") if t.strip()]


def validate(exam_path: Path, meta_path: Path, write: bool, quiet: bool) -> int:
    led = Ledger()

    # Existence & parse
    if not led.check("file_exists", exam_path.is_file(), str(exam_path)):
        print(led.render())
        print(f"\nFAILED: exam file not found at {exam_path}")
        return 1
    try:
        rows = _read_rows(exam_path)
    except Exception as exc:  # pragma: no cover - defensive
        led.check("csv_parses", False, repr(exc))
        print(led.render())
        return 1
    led.check("csv_parses", True, f"{len(rows)} data rows")

    columns = list(rows[0].keys()) if rows else []
    led.check("columns", columns == EXPECTED_COLUMNS,
              ",".join(EXPECTED_COLUMNS) if columns == EXPECTED_COLUMNS else f"got {columns}")
    led.check("row_count", len(rows) == EXPECTED_TOTAL,
              f"{len(rows)} (want {EXPECTED_TOTAL})")

    # Ids
    ids = [(r.get("id") or "").strip() for r in rows]
    bad_ids = [i for i in ids if not ID_PATTERN.match(i)]
    dup_ids = [i for i, c in collections.Counter(ids).items() if c > 1]
    led.check("ids_well_formed", not bad_ids,
              f"{len(bad_ids)} malformed: {bad_ids[:5]}" if bad_ids else "all match at-NNN")
    led.check("ids_unique", not dup_ids,
              f"dups: {dup_ids[:5]}" if dup_ids else f"{ids[0]}..{ids[-1]}, all unique")

    # Intents: in the contract, all present, evenly weighted
    intent_counts = dict(collections.Counter((r.get("intent") or "").strip() for r in rows))
    unknown = sorted(set(intent_counts) - set(isp.INTENTS))
    led.check("intents_in_contract", not unknown,
              f"unknown: {unknown}" if unknown else f"subset of {len(isp.INTENTS)} contract intents")
    missing = [i for i in isp.INTENTS if i not in intent_counts]
    led.check("all_intents_present", not missing,
              f"missing: {missing}" if missing else f"{len(isp.INTENTS)}/{len(isp.INTENTS)} intents graded")
    off_quota = {i: n for i, n in sorted(intent_counts.items()) if n != isp.EXAM_ROWS_PER_INTENT}
    led.check("intent_distribution", not off_quota,
              f"off quota: {off_quota}" if off_quota
              else f"{isp.EXAM_ROWS_PER_INTENT} rows for each of {len(isp.INTENTS)} intents")

    # Languages and the designed 15 x 3 grid
    lang_counts = dict(collections.Counter((r.get("lang") or "").strip() for r in rows))
    unknown_langs = sorted(set(lang_counts) - set(isp.LANGS))
    led.check("langs_in_contract", not unknown_langs,
              f"unknown: {unknown_langs}" if unknown_langs else f"subset of {list(isp.LANGS)}")
    want_langs = {lang: n * len(isp.INTENTS) for lang, n in isp.EXAM_LANG_QUOTA.items()}
    led.check("lang_distribution", lang_counts == want_langs,
              f"{lang_counts}" if lang_counts == want_langs else f"{lang_counts} != {want_langs}")

    grid = collections.Counter(
        ((r.get("intent") or "").strip(), (r.get("lang") or "").strip()) for r in rows
    )
    drift = {
        f"{intent}/{lang}": grid.get((intent, lang), 0)
        for intent in isp.INTENTS for lang in isp.LANGS
        if grid.get((intent, lang), 0) != isp.EXAM_LANG_QUOTA[lang]
    }
    led.check("intent_lang_grid", not drift,
              f"{len(drift)} cell(s) off: {dict(list(drift.items())[:6])}" if drift
              else f"{len(isp.INTENTS)}x{len(isp.LANGS)} cells at "
                   + ", ".join(f"{lang} {n}" for lang, n in isp.EXAM_LANG_QUOTA.items()))

    # Contract compatibility: the frozen judge, row by row
    # text_problems() is the judge for hand-written rows (tidy() is the repairer
    # for generated ones, and is deliberately not used here -- an exam row must be
    # correct as written, not quietly rewritten into correctness).
    problems: list[str] = []
    for row_id, row in zip(ids, rows):
        for problem in isp.text_problems(row.get("text") or ""):
            problems.append(f"{row_id}: {problem}")
    led.check("text_clean", not problems,
              f"{len(problems)} problem(s); first: {problems[:3]}" if problems
              else f"all {len(rows)} rows pass text_problems()")

    lengths = [len((r.get("text") or "")) for r in rows]
    led.check("length_bounds",
              bool(lengths) and min(lengths) >= isp.MIN_TEXT_CHARS
              and max(lengths) <= isp.MAX_TEXT_CHARS,
              f"{min(lengths)}..{max(lengths)} chars, mean {sum(lengths) / len(lengths):.1f} "
              f"(bounds [{isp.MIN_TEXT_CHARS},{isp.MAX_TEXT_CHARS}])")

    # Phenomena
    phen_counter: collections.Counter[str] = collections.Counter()
    unknown_tags: set[str] = set()
    for row in rows:
        tags = _tags(row)
        unknown_tags |= set(tags) - set(isp.PHENOMENA)
        phen_counter.update(tags)
    untagged = [i for i, r in zip(ids, rows) if not _tags(r)]
    led.check("phenomena_in_contract", not unknown_tags,
              f"unknown: {sorted(unknown_tags)}" if unknown_tags
              else f"{len(phen_counter)} of {len(isp.PHENOMENA)} contract tags used")
    led.check("every_row_tagged", not untagged,
              f"untagged: {untagged[:5]}" if untagged else "every row declares what it tests")

    short_phen = {
        name: f"{phen_counter.get(name, 0)}<{need}"
        for name, need in REQUIRED_PHENOMENA.items() if phen_counter.get(name, 0) < need
    }
    led.check("phenomena_coverage", not short_phen,
              f"short: {short_phen}" if short_phen
              else ", ".join(f"{k}={phen_counter.get(k, 0)}" for k in REQUIRED_PHENOMENA))
    led.check("phenomena_breadth", len(phen_counter) >= MIN_PHENOMENA_TAGS,
              f"{len(phen_counter)} distinct tags (want >= {MIN_PHENOMENA_TAGS})")

    boundary_per_intent = collections.Counter(
        (r.get("intent") or "").strip() for r in rows if "boundary" in _tags(r)
    )
    no_hard_row = [i for i in isp.INTENTS
                   if boundary_per_intent.get(i, 0) < MIN_BOUNDARY_PER_INTENT]
    led.check("boundary_per_intent", not no_hard_row,
              f"no boundary row: {no_hard_row}" if no_hard_row
              else f"every intent has >= {MIN_BOUNDARY_PER_INTENT} "
                   f"(min {min(boundary_per_intent.values())}, "
                   f"max {max(boundary_per_intent.values())})")

    # Exact duplicates, and the worse case: one text, two labels
    keys = [isp.dedup_key(r.get("text") or "") for r in rows]
    by_key: dict[str, list[int]] = {}
    for index, key in enumerate(keys):
        by_key.setdefault(key, []).append(index)
    exact_dups = {k: [ids[i] for i in idx] for k, idx in by_key.items() if len(idx) > 1}
    contradictions = {
        k: sorted({(rows[i].get("intent") or "").strip() for i in idx})
        for k, idx in by_key.items()
        if len({(rows[i].get("intent") or "").strip() for i in idx}) > 1
    }
    led.check("no_exact_duplicates", not exact_dups,
              f"{len(exact_dups)} repeated: {list(exact_dups.values())[:3]}" if exact_dups
              else f"{len(by_key)} distinct utterances")
    led.check("no_label_contradiction", not contradictions,
              f"{len(contradictions)} text(s) under two intents: {list(contradictions.items())[:2]}"
              if contradictions else "no utterance is graded against two intents")

    # Near-duplicates inside the exam (O(n^2) over 150 rows)
    # Curated look-alikes are the point of a boundary row, so the soft threshold
    # only reports. Only a near-copy (>= NEAR_DUP_FATAL) is fatal: it would give
    # one phrasing two votes in the confusion matrix.
    worst = 0.0
    worst_pair = ("", "", "")
    warn_pairs: list[tuple[str, str, float, str]] = []
    fatal_pairs: list[tuple[str, str, float, str]] = []
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            score, metric = isp.near_dup_score(rows[i].get("text") or "",
                                               rows[j].get("text") or "")
            if score > worst:
                worst, worst_pair = score, (ids[i], ids[j], metric)
            if score >= isp.NEAR_DUP_FATAL:
                fatal_pairs.append((ids[i], ids[j], round(score, 3), metric))
            elif score >= isp.NEAR_DUP_WARN:
                warn_pairs.append((ids[i], ids[j], round(score, 3), metric))
    led.check("no_near_duplicates", not fatal_pairs,
              f"FATAL {fatal_pairs[:3]}" if fatal_pairs
              else f"max={worst:.3f} {worst_pair[0]}~{worst_pair[1]} ({worst_pair[2]}), "
                   f"{len(warn_pairs)} soft warn(s) >= {isp.NEAR_DUP_WARN}")

    # Disjoint from the hand-written training rows
    # gen_intents.py already drops any corpus row that restates an exam row, so the
    # corpus is safe either way. This check is here because certifying the
    # instrument is this script's job: the likeliest leak is an author copying a
    # good line from one hand-written file into the other, and that is cheap to
    # rule out (236 x 150 pairs) and expensive to discover from a suspiciously
    # high score later.
    overlap: list[tuple[str, str, float, str]] = []
    authored_rows: list[dict[str, str]] = []
    if AUTHORED_PATH.is_file():
        authored_rows = _read_rows(AUTHORED_PATH)
        for author_row in authored_rows:
            for row_id, row in zip(ids, rows):
                score, metric = isp.near_dup_score(author_row.get("text") or "",
                                                  row.get("text") or "")
                if score >= NEAR_DUP_AUTHORED:
                    overlap.append((author_row.get("id", "?"), row_id, round(score, 3), metric))
        led.check("disjoint_from_authored", not overlap,
                  f"{len(overlap)} overlap(s) >= {NEAR_DUP_AUTHORED}: {overlap[:3]}" if overlap
                  else f"{len(authored_rows)} authored training rows, none within "
                       f"{NEAR_DUP_AUTHORED} of an exam row")
    else:
        led.check("disjoint_from_authored", True,
                  f"{AUTHORED_PATH.name} not present -- nothing to compare")

    # Every row says why it is in the exam
    # `notes` is not decoration: an exam row whose purpose nobody wrote down is a
    # row nobody can defend when the model gets it wrong.
    undocumented = [i for i, r in zip(ids, rows) if not (r.get("notes") or "").strip()]
    led.check("every_row_documented", not undocumented,
              f"{len(undocumented)} without notes: {undocumented[:5]}" if undocumented
              else "every row records what it is testing")

    # Provenance
    digest = _sha256(exam_path)

    # Report
    if not quiet:
        print(f"Exam:        {exam_path}")
        print(f"Labels:      {isp.INTENT_SPEC_VERSION} / {isp.intent_spec_fingerprint()}")
        print(f"Dataset:     {isp.DATASET_SPEC_VERSION} / {isp.dataset_spec_fingerprint()}")
        print(f"sha256:      {digest}")
        print()
        header = f"  {'intent':20} {'rows':>5}" + "".join(f" {lang:>4}" for lang in isp.LANGS)
        print(header)
        print("  " + "-" * (len(header) - 2))
        for intent in isp.INTENTS:
            cells = "".join(f" {grid.get((intent, lang), 0):4d}" for lang in isp.LANGS)
            print(f"  {intent:20} {intent_counts.get(intent, 0):5d}{cells}")
        print()
        print(led.render())
        if warn_pairs:
            print(f"\n  note: {len(warn_pairs)} pair(s) in "
                  f"[{isp.NEAR_DUP_WARN}, {isp.NEAR_DUP_FATAL}) -- deliberate look-alikes, "
                  f"non-fatal. Highest: {warn_pairs[:3]}")

    meta = {
        "generated_by": "validate_intent_test.py",
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "wave": "S.6 Wave A",
        "model": "#4 assistant intent classifier",
        "role": "held-out exam -- never trained on, never generated, never repaired",
        "source_file": exam_path.name,
        "sha256": digest,
        "intent_spec_version": isp.INTENT_SPEC_VERSION,
        "intent_spec_fingerprint": isp.intent_spec_fingerprint(),
        "dataset_spec_version": isp.DATASET_SPEC_VERSION,
        "dataset_spec_fingerprint": isp.dataset_spec_fingerprint(),
        "rows": len(rows),
        "columns": columns,
        "design": {
            "rows_per_intent": isp.EXAM_ROWS_PER_INTENT,
            "lang_quota_per_intent": dict(isp.EXAM_LANG_QUOTA),
        },
        "intents": dict(sorted(intent_counts.items())),
        "langs": dict(sorted(lang_counts.items())),
        "intent_x_lang": {
            f"{intent}|{lang}": grid.get((intent, lang), 0)
            for intent in isp.INTENTS for lang in isp.LANGS
        },
        "phenomena": dict(sorted(phen_counter.items(), key=lambda kv: (-kv[1], kv[0]))),
        "boundary_per_intent": {i: boundary_per_intent.get(i, 0) for i in isp.INTENTS},
        "text_length": {
            "min": min(lengths), "max": max(lengths),
            "mean": round(sum(lengths) / len(lengths), 2),
            "bounds": [isp.MIN_TEXT_CHARS, isp.MAX_TEXT_CHARS],
        },
        "near_duplicate": {
            "metric": "max(char-4-shingle, word-set) Jaccard over dedup_key text",
            "max_score": round(worst, 4),
            "max_pair": list(worst_pair),
            "warn_threshold": isp.NEAR_DUP_WARN,
            "fatal_threshold": isp.NEAR_DUP_FATAL,
            "warn_pairs": warn_pairs,
            "fatal_pairs": fatal_pairs,
        },
        "authored_overlap": {
            "file": AUTHORED_PATH.name,
            "rows_compared": len(authored_rows),
            "threshold": NEAR_DUP_AUTHORED,
            "overlaps": overlap,
        },
        "checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in led.rows],
        "all_passed": led.passed,
    }

    if write:
        meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
                             encoding="utf-8")
        if not quiet:
            print(f"\nWrote {meta_path.relative_to(ROOT)}")

    if led.passed:
        if not quiet:
            print("\nRESULT: PASS -- exam is intact, balanced as designed, clean, "
                  "disjoint from training, and fingerprinted.")
        return 0
    print("\nRESULT: FAIL -- exam did not pass validation. See failed checks above.")
    print("If you changed the exam on purpose, update the EXPECTED_*/REQUIRED_* constants")
    print("in this file in the same commit, so the change is explicit and reviewable --")
    print("and never change an exam row because the model got it wrong.")
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate and fingerprint assistant_test.csv (the intent exam)")
    parser.add_argument("--quiet", action="store_true", help="only print the final RESULT line")
    parser.add_argument("--no-write", action="store_true",
                        help="do not write assistant_test_meta.json")
    parser.add_argument("--exam", type=Path, default=EXAM_PATH, help="path to the exam CSV")
    parser.add_argument("--meta", type=Path, default=META_PATH, help="path to write the meta JSON")
    args = parser.parse_args(argv)
    return validate(args.exam, args.meta, write=not args.no_write, quiet=args.quiet)


if __name__ == "__main__":
    raise SystemExit(main())
