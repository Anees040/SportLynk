"""Validate and fingerprint the REL-8 domain exam set (domain_test_200.csv).

WHY THIS EXISTS
---------------
`data/sentiment/domain_test_200.csv` is the *exam*. It is the untouched, held-out
set that the >=80% acceptance gate for Model #2 (sentiment) is measured against.
Every headline number in the model card is only as trustworthy as this file.

So before any training run reports "82% on the domain set", we must be able to
prove -- mechanically, every time -- that the exam itself is:

  * structurally intact   (200 rows, the exact 7 columns, unique ids),
  * label/lang balanced   (the designed 3x3 grid, not silently re-weighted),
  * contract-compatible   (no row is destroyed by the frozen normalizer, so
                           every row is actually scoreable),
  * internally clean       (no exact- or near-duplicate rows inflating a metric),
  * pinned by sha256       (so the exam cannot drift between runs without the
                           provenance gate in train_sentiment.py catching it).

This script is the mirror image of `generate_bookings.py`'s provenance discipline
for Model #1: it emits `domain_test_meta.json` (sha256 + full census) which the
trainer reads and refuses to proceed if the live file no longer matches.

It NEVER writes to, samples from, or otherwise mutates the exam. Read-only.

Run:
    ./.venv/Scripts/python.exe training/validate_domain_test.py
    ./.venv/Scripts/python.exe training/validate_domain_test.py --quiet
    ./.venv/Scripts/python.exe training/validate_domain_test.py --no-write

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

# Windows consoles default to cp1252; exam text and detail strings may carry
# characters outside it. Never let rendering crash a validation run.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

# Contract linkage
# Import the same frozen normalizer the model trains and serves on. If this
# import ever fails, the exam cannot be validated against the real contract and
# the run must stop -- there is no silent fallback.
ROOT = Path(__file__).resolve().parents[1]  # ml-service/
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from app.core import text_norm  # noqa: E402

# Paths
EXAM_PATH = ROOT / "data" / "sentiment" / "domain_test_200.csv"
META_PATH = ROOT / "data" / "sentiment" / "domain_test_meta.json"

# Pinned expectations
# These are the as-designed counts, verified by direct census of the committed
# file on 2026-08-26. They are intentionally hard-coded: this script's job is to
# scream if the exam is ever edited, re-balanced, or truncated. Changing the
# exam on purpose means updating these constants in the same commit -- which is
# exactly the reviewable, deliberate act it should be.
EXPECTED_COLUMNS = ["id", "text", "label", "lang", "aspect", "phenomena", "notes"]
EXPECTED_TOTAL = 200
EXPECTED_LABELS = {"negative": 68, "neutral": 67, "positive": 65}
EXPECTED_LANGS = {"ru": 80, "mixed": 70, "en": 50}
EXPECTED_GRID = {
    ("ru", "negative"): 27, ("ru", "neutral"): 27, ("ru", "positive"): 26,
    ("mixed", "negative"): 24, ("mixed", "neutral"): 23, ("mixed", "positive"): 23,
    ("en", "negative"): 17, ("en", "neutral"): 17, ("en", "positive"): 16,
}
ID_PATTERN = re.compile(r"^dt-\d{3,}$")

# Phenomena the exam is *required* to exercise -- these are the hard cases the
# model is graded on. Counts are minimums (tags are semicolon-multi-valued).
REQUIRED_PHENOMENA = {"negation": 10, "code_switch": 20}

# Near-duplicate policy over char-4-gram Jaccard of normalized text.
NEAR_DUP_FAIL = 0.97   # >= this ~= an accidental copy -> hard failure
NEAR_DUP_WARN = 0.85   # >= this -> reported, not fatal (curated look-alikes)


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
            mark = "PASS" if ok else "FAIL"
            line = f"  [{mark}] {name.ljust(width)}"
            if detail:
                line += f"  {detail}"
            lines.append(line)
        return "\n".join(lines)


def _shingles(text: str, n: int = 4) -> set[str]:
    if len(text) < n:
        return {text} if text else set()
    return {text[i:i + n] for i in range(len(text) - n + 1)}


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_rows(path: Path) -> list[dict[str, str]]:
    # utf-8-sig strips a BOM if present; the exam is authored in UTF-8.
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


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
    led.check(
        "columns",
        columns == EXPECTED_COLUMNS,
        f"got {columns}" if columns != EXPECTED_COLUMNS else "id,text,label,lang,aspect,phenomena,notes",
    )
    led.check("row_count", len(rows) == EXPECTED_TOTAL, f"{len(rows)} (want {EXPECTED_TOTAL})")

    # Ids
    ids = [(r.get("id") or "").strip() for r in rows]
    bad_ids = [i for i in ids if not ID_PATTERN.match(i)]
    dup_ids = [i for i, c in collections.Counter(ids).items() if c > 1]
    led.check("ids_well_formed", not bad_ids, f"{len(bad_ids)} malformed" if bad_ids else "all match dt-NNN")
    led.check("ids_unique", not dup_ids, f"dups: {dup_ids[:5]}" if dup_ids else "all unique")

    # Labels & langs
    label_counts = dict(collections.Counter((r.get("label") or "").strip() for r in rows))
    lang_counts = dict(collections.Counter((r.get("lang") or "").strip() for r in rows))

    unknown_labels = sorted(set(label_counts) - set(text_norm.LABELS))
    led.check(
        "labels_in_contract",
        not unknown_labels,
        f"unknown: {unknown_labels}" if unknown_labels else f"subset of {text_norm.LABELS}",
    )
    led.check("label_distribution", label_counts == EXPECTED_LABELS, f"{label_counts}")

    unknown_langs = sorted(set(lang_counts) - set(EXPECTED_LANGS))
    led.check("langs_known", not unknown_langs, f"unknown: {unknown_langs}" if unknown_langs else "subset of {ru,mixed,en}")
    led.check("lang_distribution", lang_counts == EXPECTED_LANGS, f"{lang_counts}")

    # The designed 3x3 grid
    grid = dict(collections.Counter(
        ((r.get("lang") or "").strip(), (r.get("label") or "").strip()) for r in rows
    ))
    grid_ok = grid == EXPECTED_GRID
    grid_detail = "9 cells as designed" if grid_ok else f"drift: {sorted((k, grid.get(k, 0)) for k in set(grid) | set(EXPECTED_GRID))}"
    led.check("lang_label_grid", grid_ok, grid_detail)

    # Contract compatibility: every row survives normalization
    normalized: list[str] = []
    empty_after_norm: list[str] = []
    empty_raw: list[str] = []
    for r in rows:
        raw = (r.get("text") or "")
        if not raw.strip():
            empty_raw.append(r.get("id", "?"))
        norm = text_norm.normalize_text(raw)
        normalized.append(norm)
        if not norm.strip():
            empty_after_norm.append(r.get("id", "?"))
    led.check("no_empty_raw_text", not empty_raw, f"empty: {empty_raw[:5]}" if empty_raw else "all non-empty")
    led.check(
        "scoreable_after_normalize",
        not empty_after_norm,
        f"normalize -> empty: {empty_after_norm[:5]}" if empty_after_norm else "no row destroyed by normalizer",
    )

    # Exact duplicates (on normalized text)
    norm_counts = collections.Counter(t for t in normalized if t.strip())
    exact_dups = [(t, c) for t, c in norm_counts.items() if c > 1]
    led.check(
        "no_exact_duplicates",
        not exact_dups,
        f"{len(exact_dups)} repeated texts" if exact_dups else "all distinct after normalize",
    )

    # Near-duplicates (char-4-gram Jaccard, O(n^2) over 200 rows)
    shings = [_shingles(t) for t in normalized]
    worst = 0.0
    worst_pair = ("", "")
    warn_pairs: list[tuple[str, str, float]] = []
    fatal_pairs: list[tuple[str, str, float]] = []
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            sim = _jaccard(shings[i], shings[j])
            if sim > worst:
                worst = sim
                worst_pair = (ids[i], ids[j])
            if sim >= NEAR_DUP_FAIL:
                fatal_pairs.append((ids[i], ids[j], round(sim, 3)))
            elif sim >= NEAR_DUP_WARN:
                warn_pairs.append((ids[i], ids[j], round(sim, 3)))
    led.check(
        "no_near_duplicates",
        not fatal_pairs,
        f"max={worst:.3f} {worst_pair}" + (f"  FATAL:{fatal_pairs[:3]}" if fatal_pairs else f" ({len(warn_pairs)} soft warns)"),
    )

    # Phenomena & aspect coverage
    phen_counter: collections.Counter[str] = collections.Counter()
    for r in rows:
        for tag in (r.get("phenomena") or "").split(";"):
            tag = tag.strip()
            if tag:
                phen_counter[tag] += 1
    missing_phen = {
        name: need for name, need in REQUIRED_PHENOMENA.items()
        if phen_counter.get(name, 0) < need
    }
    led.check(
        "phenomena_coverage",
        not missing_phen,
        f"short: {missing_phen}" if missing_phen else f"{len(phen_counter)} tags; neg={phen_counter.get('negation',0)}, cs={phen_counter.get('code_switch',0)}",
    )

    aspect_counter = dict(collections.Counter((r.get("aspect") or "").strip() for r in rows))
    led.check("aspect_coverage", len(aspect_counter) >= 8, f"{len(aspect_counter)} distinct aspects")

    # Provenance
    digest = _sha256(exam_path)

    # Report
    if not quiet:
        print(f"Exam:        {exam_path}")
        print(f"Normalizer:  {text_norm.NORM_SPEC_VERSION} / {text_norm.norm_spec_fingerprint()}")
        print(f"sha256:      {digest}")
        print()
        print(led.render())
        if warn_pairs and not quiet:
            print(f"\n  note: {len(warn_pairs)} row pair(s) with Jaccard in [{NEAR_DUP_WARN}, {NEAR_DUP_FAIL}) "
                  f"(curated look-alikes, non-fatal). Highest below threshold: {warn_pairs[:3]}")

    meta = {
        "generated_by": "validate_domain_test.py",
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "source_file": exam_path.name,
        "sha256": digest,
        "norm_spec_version": text_norm.NORM_SPEC_VERSION,
        "norm_spec_fingerprint": text_norm.norm_spec_fingerprint(),
        "rows": len(rows),
        "columns": columns,
        "labels": label_counts,
        "langs": lang_counts,
        "grid": {f"{lang}|{label}": n for (lang, label), n in sorted(grid.items())},
        "phenomena": dict(sorted(phen_counter.items(), key=lambda kv: (-kv[1], kv[0]))),
        "aspects": dict(sorted(aspect_counter.items(), key=lambda kv: (-kv[1], kv[0]))),
        "near_duplicate": {
            "max_jaccard": round(worst, 4),
            "max_pair": list(worst_pair),
            "warn_threshold": NEAR_DUP_WARN,
            "fail_threshold": NEAR_DUP_FAIL,
            "warn_pairs": warn_pairs,
            "fatal_pairs": fatal_pairs,
        },
        "checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in led.rows],
        "all_passed": led.passed,
    }

    if write:
        meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        if not quiet:
            print(f"\nWrote {meta_path.relative_to(ROOT)}")

    if led.passed:
        if not quiet:
            print("\nRESULT: PASS -- exam is intact, balanced, scoreable, and fingerprinted.")
        return 0
    print("\nRESULT: FAIL -- exam did not pass validation. See failed checks above.")
    print("If you changed the exam on purpose, update the EXPECTED_* constants in this")
    print("file in the same commit so the change is explicit and reviewable.")
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate and fingerprint domain_test_200.csv")
    parser.add_argument("--quiet", action="store_true", help="only print the final RESULT line")
    parser.add_argument("--no-write", action="store_true", help="do not write domain_test_meta.json")
    parser.add_argument("--exam", type=Path, default=EXAM_PATH, help="path to the exam CSV")
    parser.add_argument("--meta", type=Path, default=META_PATH, help="path to write the meta JSON")
    args = parser.parse_args(argv)
    return validate(args.exam, args.meta, write=not args.no_write, quiet=args.quiet)


if __name__ == "__main__":
    raise SystemExit(main())
