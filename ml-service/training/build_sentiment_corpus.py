"""Assemble the Model #2 (sentiment) training corpus from REAL, cited sources.

WHAT THIS REPLACES
------------------
The previous version stored *normalized* text (throwing away the raw the frozen
pipeline needs), had a fake "independence gate" (a mere presence check), did no
deduplication, and its `--per-class 5000` knob is exactly what let 15 unique
sentences explode into 6,000 fabricated rows. None of that survives here.

SOURCES (all real, all cited in data/sentiment/README.md)
  * rusa      Roman Urdu Sentiment corpus  (data/sentiment/Roman Urdu DataSet.csv)
              ~12k human-written Roman-Urdu lines. Supplies orthography, negation
              syntax, and generic polarity vocab -- NOT venue/booking content.
  * tweeteval English 3-class tweets (SemEval-2017 T4A), optional, capped so it
              cannot drown the Roman-Urdu signal. Supplies English + neutral.
  * authored  Hand-written in-domain booking rows (data/sentiment/authored*.csv;
              every matching file is loaded and merged), optional. Supplies the
              venue register the other two lack. This is the sanctioned
              augmentation ("300-500 self-labeled sports sentences, NOT from the
              test set").

INVARIANTS THIS ENFORCES
  1. RAW text is stored; normalization happens inside the model pipeline only.
  2. Exact-duplicate rows (by normalized key) are collapsed -- no template padding.
  3. CONTAMINATION GATE: any corpus row that exact-matches an exam row (after
     normalization) is dropped; authored rows are additionally near-dup checked
     against the exam. The exam is read ONLY to exclude overlap, never mixed in.
  4. A real language-vs-label independence statistic (chi-square + Cramer's V +
     per-source TVD) is computed and recorded, so a "language => label" shortcut
     is visible instead of hidden.
  5. Full provenance meta (sha256 of corpus + exam, per-source census, dedup and
     contamination counts, normalizer fingerprint) is written next to the corpus.

Run:
    ./.venv/Scripts/python.exe training/build_sentiment_corpus.py
    ./.venv/Scripts/python.exe training/build_sentiment_corpus.py --tweeteval-per-label 3000

Exit 0 = corpus written; non-zero = a hard gate failed (e.g. a source had no
usable rows, or contamination could not be excluded).
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import hashlib
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # ml-service/
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from app.core import text_norm  # noqa: E402

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

csv.field_size_limit(10_000_000)  # RUSA has multi-KB runaway-quote rows

# Paths
DATA = ROOT / "data" / "sentiment"
RUSA_PATH = DATA / "Roman Urdu DataSet.csv"
TWEETEVAL_DIR = DATA / "raw" / "tweeteval"
AUTHORED_GLOB = "authored*.csv"  # every match under DATA is loaded and merged
EXAM_PATH = DATA / "domain_test_200.csv"
OUT_CSV = DATA / "train.csv"
OUT_META = DATA / "train.meta.json"

LABELS = text_norm.LABELS  # ("negative","neutral","positive")

# Map every label spelling any source might use onto the contract's 3 classes.
# Includes the RUSA "Neative" typo and TweetEval's numeric codes.
LABEL_MAP = {
    "positive": "positive", "pos": "positive", "2": "positive",
    "negative": "negative", "neg": "negative", "0": "negative",
    "neutral": "neutral", "neu": "neutral", "1": "neutral",
    "neative": "neutral",  # RUSA typo, seen in the real file
}

# TweetEval numeric label -> class (per its mapping.txt: 0 neg / 1 neu / 2 pos)
TWEETEVAL_MAP = {"0": "negative", "1": "neutral", "2": "positive"}

NEAR_DUP_CONTAM = 0.80  # authored row this close to an exam row (Jaccard) is dropped


# Helpers
def _norm_key(text: str) -> str:
    """Dedup / contamination key: the frozen-normalizer output, whitespace-folded."""
    return " ".join(text_norm.normalize_text(text).split())


def _shingles(text: str, n: int = 4) -> set[str]:
    if len(text) < n:
        return {text} if text else set()
    return {text[i:i + n] for i in range(len(text) - n + 1)}


def _words(text: str) -> set[str]:
    """Token set for the ORDER-INSENSITIVE half of the contamination check.

    Character shingles and word sets fail on opposite things, which is why the gate
    below needs both. Shingles are order-SENSITIVE: reordering a clause shreds every
    4-gram that spanned the moved boundary, even though not a single word changed.
    This pair is the case that motivated adding a second metric --

        authored  lights aadhi band thin, ball raat ko nazar hi nahi aati thi
        exam      lights aadhi band thin, raat ko ball nazar hi nahi ati thi

    -- a near-verbatim copy with "ball" moved three words and one vowel dropped.
    Shingle Jaccard is 0.73, safely under the 0.80 gate; word Jaccard is 0.85, well
    over it. Taking the MAX of the two catches reordering and rewording alike, and
    the cost of the extra check is a set intersection per pair.

    Conversely, words alone would miss a spelling-drift copy that keeps word order
    ("aati"/"ati" splits a token but preserves the surrounding shingles), so neither
    metric replaces the other.
    """
    return set(text.split())


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    u = len(a | b)
    return len(a & b) / u if u else 0.0


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    return _sha256_bytes(path.read_bytes()) if path.is_file() else ""


# Source adapters
class LoadReport:
    def __init__(self, source: str) -> None:
        self.source = source
        self.seen = 0
        self.kept = 0
        self.bad_label = 0
        self.empty = 0
        self.note = ""

    def line(self) -> str:
        base = (f"  {self.source:<10} seen={self.seen:<6} kept={self.kept:<6} "
                f"bad_label={self.bad_label:<5} empty={self.empty}")
        return base + (f"   [{self.note}]" if self.note else "")


def _looks_like_html(sample: str) -> bool:
    head = sample.lstrip()[:200].lower()
    return head.startswith(("<", "<?xml")) or "<html" in head or "doctype html" in head


def load_rusa(path: Path) -> tuple[list[dict], LoadReport]:
    """RUSA is headerless: [text, Label, <empty third col>]. Repairs 'Neative'."""
    rep = LoadReport("rusa")
    out: list[dict] = []
    if not path.is_file():
        return out, rep
    with path.open("r", encoding="utf-8", errors="replace", newline="") as fh:
        for row in csv.reader(fh):
            rep.seen += 1
            if len(row) < 2:
                rep.empty += 1
                continue
            text = (row[0] or "").strip()
            label = LABEL_MAP.get((row[1] or "").strip().lower())
            if not text:
                rep.empty += 1
                continue
            if label is None:
                rep.bad_label += 1
                continue
            out.append({"text": text, "label": label, "lang": "ru", "source": "rusa"})
            rep.kept += 1
    return out, rep


def load_tweeteval(dir_: Path, per_label: int) -> tuple[list[dict], LoadReport]:
    """Optional. Parallel train_text.txt / train_labels.txt; per-label cap keeps
    the 3 classes balanced and stops English from swamping Roman Urdu."""
    rep = LoadReport("tweeteval")
    out: list[dict] = []
    text_file = dir_ / "train_text.txt"
    label_file = dir_ / "train_labels.txt"
    if not (text_file.is_file() and label_file.is_file()):
        return out, rep
    text_raw = text_file.read_text(encoding="utf-8", errors="replace")
    label_raw = label_file.read_text(encoding="utf-8", errors="replace")
    # A transient CDN 503 leaves an HTML error page in place of the data.
    if _looks_like_html(text_raw) or _looks_like_html(label_raw):
        rep.note = "SKIPPED: file is an HTML error page (503?) -- re-download"
        return out, rep
    texts = text_raw.splitlines()
    labels = label_raw.splitlines()
    if len(texts) != len(labels):
        # Optional source: never hard-fail the whole corpus over a bad download.
        rep.note = f"SKIPPED: {len(texts)} texts vs {len(labels)} labels not aligned -- re-download"
        return out, rep
    per_label_kept: Counter[str] = Counter()
    for text, code in zip(texts, labels):
        rep.seen += 1
        text = text.strip()
        label = TWEETEVAL_MAP.get(code.strip())
        if not text:
            rep.empty += 1
            continue
        if label is None:
            rep.bad_label += 1
            continue
        if per_label and per_label_kept[label] >= per_label:
            continue
        out.append({"text": text, "label": label, "lang": "en", "source": "tweeteval"})
        per_label_kept[label] += 1
        rep.kept += 1
    return out, rep


def load_authored(path: Path) -> tuple[list[dict], LoadReport]:
    """Optional hand-written in-domain rows. Header: text,label,lang[,aspect]."""
    rep = LoadReport("authored")
    out: list[dict] = []
    if not path.is_file():
        return out, rep
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            rep.seen += 1
            text = (row.get("text") or "").strip()
            label = LABEL_MAP.get((row.get("label") or "").strip().lower())
            lang = (row.get("lang") or "mixed").strip().lower() or "mixed"
            if not text:
                rep.empty += 1
                continue
            if label is None:
                rep.bad_label += 1
                continue
            out.append({"text": text, "label": label, "lang": lang, "source": "authored"})
            rep.kept += 1
    return out, rep


def load_all_authored(paths: list[Path]) -> tuple[list[dict], LoadReport]:
    """Load and concatenate every authored*.csv file into one merged report.

    In-domain venue rows are hand-authored across several files (a base set plus
    incrementally added batches). We read them all rather than a single fixed
    file so new labelled data can be dropped in without touching this script.
    Exact-dedup downstream removes any accidental cross-file repeats.
    """
    rep = LoadReport("authored")
    out: list[dict] = []
    used: list[str] = []
    for path in paths:
        rows, r = load_authored(path)
        out.extend(rows)
        rep.seen += r.seen
        rep.kept += r.kept
        rep.bad_label += r.bad_label
        rep.empty += r.empty
        if r.seen:
            used.append(f"{path.name}({r.kept})")
    if used:
        rep.note = "files: " + ", ".join(used)
    return out, rep


# Statistics
def chi_square(table: dict[tuple[str, str], int], rows: list[str], cols: list[str]) -> dict:
    """Pearson chi-square + Cramer's V for an r x c contingency table.

    Hand-rolled in stdlib: scipy is not a DECLARED dependency (it arrives only as a
    transitive of scikit-learn), and a corpus builder that runs before any model is
    fit should not acquire a numerics dependency to divide two sums.

    Reports the statistic and the effect size, deliberately NOT a p-value. At
    n = 21,405 the null is rejected by associations far too weak to matter, so a
    p-value would read as evidence while carrying none; Cramer's V is the number that
    answers the actual question -- how STRONG is the language/source => label shortcut."""
    n = sum(table.values())
    if n == 0:
        return {"n": 0, "chi2": 0.0, "dof": 0, "cramers_v": 0.0}
    row_tot = {r: sum(table.get((r, c), 0) for c in cols) for r in rows}
    col_tot = {c: sum(table.get((r, c), 0) for r in rows) for c in cols}
    chi2 = 0.0
    for r in rows:
        for c in cols:
            exp = row_tot[r] * col_tot[c] / n
            if exp > 0:
                obs = table.get((r, c), 0)
                chi2 += (obs - exp) ** 2 / exp
    k = min(len(rows) - 1, len(cols) - 1)
    v = math.sqrt(chi2 / (n * k)) if (n > 0 and k > 0) else 0.0
    return {"n": n, "chi2": round(chi2, 3), "dof": (len(rows) - 1) * (len(cols) - 1),
            "cramers_v": round(v, 4)}


def tvd_by_source(records: list[dict]) -> dict[str, float]:
    """Total-variation distance of each source's label distribution vs the global one.
    High TVD => that source carries a distinct label profile (a shortcut risk)."""
    global_counts = Counter(r["label"] for r in records)
    total = sum(global_counts.values()) or 1
    global_p = {l: global_counts.get(l, 0) / total for l in LABELS}
    out: dict[str, float] = {}
    by_source: dict[str, Counter] = defaultdict(Counter)
    for r in records:
        by_source[r["source"]][r["label"]] += 1
    for src, cnt in by_source.items():
        s = sum(cnt.values()) or 1
        tvd = 0.5 * sum(abs(cnt.get(l, 0) / s - global_p[l]) for l in LABELS)
        out[src] = round(tvd, 4)
    return out


# Build
def build(args: argparse.Namespace) -> int:
    print("Assembling sentiment corpus from real sources")
    print(f"Normalizer: {text_norm.NORM_SPEC_VERSION} / {text_norm.norm_spec_fingerprint()}\n")

    rusa, r_rep = load_rusa(args.rusa)
    tweet, t_rep = load_tweeteval(args.tweeteval_dir, args.tweeteval_per_label)
    authored_files = sorted(DATA.glob(args.authored_glob))
    authored, a_rep = load_all_authored(authored_files)

    print("Loaded per source:")
    for rep in (r_rep, t_rep, a_rep):
        print(rep.line())
    if t_rep.kept == 0:
        print("  (tweeteval absent -> English/neutral signal is thinner; "
              "run the download command to strengthen it)")
    if a_rep.kept == 0:
        print(f"  (no authored*.csv found under {DATA} -> no in-domain venue rows yet)")

    # Load order sets dedup priority: authored & tweeteval kept over a rusa dup.
    records = authored + tweet + rusa
    if not records:
        raise SystemExit("No usable rows from any source. Is 'Roman Urdu DataSet.csv' present?")

    # Exact dedup on normalized key
    seen_keys: set[str] = set()
    deduped: list[dict] = []
    dup_dropped = 0
    empty_norm = 0
    for r in records:
        key = _norm_key(r["text"])
        if not key:
            empty_norm += 1
            continue
        if key in seen_keys:
            dup_dropped += 1
            continue
        seen_keys.add(key)
        r["_key"] = key
        deduped.append(r)

    # Contamination gate vs the exam
    if not EXAM_PATH.is_file():
        raise SystemExit(f"Exam not found at {EXAM_PATH}; cannot run contamination gate.")
    with EXAM_PATH.open("r", encoding="utf-8-sig", newline="") as fh:
        exam_rows = list(csv.DictReader(fh))
    exam_keys = {_norm_key(r.get("text", "")) for r in exam_rows}
    exam_keys.discard("")
    exam_shingles = [_shingles(k) for k in exam_keys]
    exam_words = [_words(k) for k in exam_keys]

    clean: list[dict] = []
    exact_contam = 0
    near_contam = 0
    near_by_metric = Counter()  # which metric caught it -- reported, not just counted
    for r in deduped:
        if r["_key"] in exam_keys:
            exact_contam += 1
            continue
        if r["source"] == "authored":
            sh = _shingles(r["_key"])
            wd = _words(r["_key"])
            char_sim = max((_jaccard(sh, es) for es in exam_shingles), default=0.0)
            word_sim = max((_jaccard(wd, ew) for ew in exam_words), default=0.0)
            if max(char_sim, word_sim) >= NEAR_DUP_CONTAM:
                near_contam += 1
                near_by_metric["char_shingle" if char_sim >= NEAR_DUP_CONTAM else "word_set"] += 1
                print(
                    f"  [contam] dropped authored row "
                    f"(char={char_sim:.2f} word={word_sim:.2f}): {r['text'][:60]}"
                )
                continue
        clean.append(r)

    if not clean:
        raise SystemExit("Every row was dropped by dedup/contamination gates -- nothing to write.")

    # Census & statistics
    label_counts = Counter(r["label"] for r in clean)
    lang_counts = Counter(r["lang"] for r in clean)
    source_counts = Counter(r["source"] for r in clean)
    src_label = Counter((r["source"], r["label"]) for r in clean)
    lang_label = Counter((r["lang"], r["label"]) for r in clean)

    sources_present = [s for s in ("authored", "tweeteval", "rusa") if source_counts.get(s)]
    langs_present = sorted(lang_counts)
    chi_src = chi_square(src_label, sources_present, list(LABELS))
    chi_lang = chi_square(lang_label, langs_present, list(LABELS))
    tvd = tvd_by_source(clean)

    # Write corpus (RAW text)
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_CSV.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["text", "label", "lang", "source"])
        w.writeheader()
        for r in clean:
            w.writerow({"text": r["text"], "label": r["label"], "lang": r["lang"], "source": r["source"]})

    corpus_sha = _sha256_file(OUT_CSV)

    meta = {
        "generated_by": "build_sentiment_corpus.py",
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "norm_spec_version": text_norm.NORM_SPEC_VERSION,
        "norm_spec_fingerprint": text_norm.norm_spec_fingerprint(),
        "rows": len(clean),
        "labels": {l: label_counts.get(l, 0) for l in LABELS},
        "langs": dict(sorted(lang_counts.items())),
        "sources": dict(sorted(source_counts.items())),
        "source_x_label": {f"{s}|{l}": src_label.get((s, l), 0)
                            for s in sources_present for l in LABELS},
        "lang_x_label": {f"{lg}|{l}": lang_label.get((lg, l), 0)
                         for lg in langs_present for l in LABELS},
        "independence": {
            "source_vs_label": chi_src,
            "lang_vs_label": chi_lang,
            "tvd_by_source": tvd,
            "note": "chi2 statistic + Cramer's V, deliberately not a p-value: at this n "
                    "the null is rejected by associations too weak to matter, so effect "
                    "size is the informative number. High Cramer's V / TVD flags a "
                    "language-or-source => label shortcut.",
        },
        "dedup": {
            "loaded": len(records),
            "exact_dup_dropped": dup_dropped,
            "empty_after_normalize": empty_norm,
        },
        "contamination_gate": {
            "exam_file": EXAM_PATH.name,
            "exam_sha256": _sha256_file(EXAM_PATH),
            "exact_matches_removed": exact_contam,
            "authored_near_dup_removed": near_contam,
            "authored_near_dup_by_metric": dict(near_by_metric),
            "near_dup_threshold": NEAR_DUP_CONTAM,
            "near_dup_metrics": "max(char 4-shingle Jaccard, word-set Jaccard) -- "
                                "shingles miss reordering, word sets miss spelling drift",
            "limitation": "Exhaustive near-dup vs exam is applied to authored rows only; "
                          "rusa/tweeteval get exact-match removal (pairwise near-dup is "
                          "infeasible at corpus scale in stdlib). Domain overlap of those "
                          "sources with the exam is low, so residual risk is small.",
        },
        "per_source_load": {rep.source: {"seen": rep.seen, "kept": rep.kept,
                                          "bad_label": rep.bad_label, "empty": rep.empty}
                            for rep in (r_rep, t_rep, a_rep)},
        "sha256": corpus_sha,
        "output": OUT_CSV.name,
    }
    OUT_META.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # Report
    print("\nCorpus assembled:")
    print(f"  rows written : {len(clean)}")
    print(f"  labels       : {dict(label_counts)}")
    print(f"  langs        : {dict(lang_counts)}")
    print(f"  sources      : {dict(source_counts)}")
    print(f"  exact dups dropped        : {dup_dropped}")
    print(f"  empty after normalize     : {empty_norm}")
    print(f"  exam exact matches removed: {exact_contam}")
    print(f"  authored near-dup removed : {near_contam}")
    print(f"  independence lang~label   : chi2={chi_lang['chi2']} V={chi_lang['cramers_v']} (dof {chi_lang['dof']})")
    print(f"  tvd by source             : {tvd}")
    print(f"  corpus sha256             : {corpus_sha}")
    print(f"\nWrote {OUT_CSV.relative_to(ROOT)} and {OUT_META.relative_to(ROOT)}")

    # A gentle, non-fatal signal: a strong lang->label link means the model could
    # cheat on language. The check warns rather than blocks; the trainer's ablation is the
    # real proof, and RUSA's natural label skew makes some association expected.
    if chi_lang["cramers_v"] >= 0.5:
        print(f"\n  WARNING: lang~label Cramer's V = {chi_lang['cramers_v']} is high. "
              "Check the trainer's ablation table -- English rows may be doing the work.")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Build the sentiment training corpus from real sources.")
    p.add_argument("--rusa", type=Path, default=RUSA_PATH)
    p.add_argument("--tweeteval-dir", type=Path, default=TWEETEVAL_DIR)
    p.add_argument("--authored-glob", type=str, default=AUTHORED_GLOB,
                   help="glob (under data/sentiment/) for hand-authored in-domain files; "
                        "all matches are loaded and merged")
    p.add_argument("--tweeteval-per-label", type=int, default=3000,
                   help="cap tweeteval rows PER class (0 = no cap) so English cannot swamp Roman Urdu")
    return build(p.parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
