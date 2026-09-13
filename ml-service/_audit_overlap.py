"""Read-only contamination probe: does the sentiment TRAINING corpus overlap the
locked exam (domain_test_200)? Sentiment's gate list has no corpus<->exam near-dup
gate, so this checks by hand. Prints exact matches and top Jaccard pairs, broken
down by corpus source. Writes nothing. Delete after use."""
import csv, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data" / "sentiment"

def norm_str(s: str) -> str:
    s = s.lower()
    s = re.sub(r"[^\w\s]", " ", s, flags=re.UNICODE)
    return " ".join(s.split())

def toks(s: str) -> set:
    return set(norm_str(s).split())

def load(path: Path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))

def col(d, *names):
    for n in names:
        if n in d and d[n]:
            return d[n]
    return ""

exam = load(DATA / "domain_test_200.csv")
exam_rows = [(d.get("id", "?"), d["text"], toks(d["text"])) for d in exam]

train_path = DATA / "train.csv"
if not train_path.exists():
    cands = list((ROOT / "data").rglob("train.csv"))
    train_path = cands[0] if cands else train_path
train = load(train_path)
print("train.csv:", train_path)
print("train columns:", list(train[0].keys()))
train_rows = [(col(d, "text", "review", "sentence"),
               col(d, "source", "src") or "?",
               toks(col(d, "text", "review", "sentence"))) for d in train]

# exact normalized-text match
train_norm = {}
for txt, src, _ in train_rows:
    train_norm.setdefault(norm_str(txt), src)
exact = [(eid, etext, train_norm[norm_str(etext)])
         for eid, etext, _ in exam_rows if norm_str(etext) in train_norm]

def jacc(a, b):
    if not a or not b:
        return 0.0
    u = len(a | b)
    return len(a & b) / u if u else 0.0

results = []
for eid, etext, etok in exam_rows:
    best, bsrc, btxt = 0.0, "", ""
    for txt, src, ttok in train_rows:
        j = jacc(etok, ttok)
        if j > best:
            best, bsrc, btxt = j, src, txt
    results.append((best, eid, etext, bsrc, btxt))
results.sort(reverse=True)

def cnt(thr):
    return sum(1 for r in results if r[0] >= thr)

print(f"\nEXAM rows: {len(exam_rows)}   TRAIN rows: {len(train_rows)}")
print(f"EXACT normalized matches (exam text present verbatim in training): {len(exact)}")
for eid, etext, src in exact[:25]:
    print(f"   EXACT [{eid}] src={src} | {etext[:70]!r}")
print(f"\nnear-dup counts:  >=0.95: {cnt(0.95)}   >=0.90: {cnt(0.90)}   "
      f">=0.85: {cnt(0.85)}   >=0.80: {cnt(0.80)}   >=0.70: {cnt(0.70)}")
print("\nTOP 20 exam<->train Jaccard (by source of the matched training row):")
for best, eid, etext, bsrc, btxt in results[:20]:
    print(f"  j={best:.3f} src={bsrc:9s} exam[{eid}]={etext[:52]!r} <-> train={btxt[:52]!r}")

# where do the high-similarity matches concentrate by source?
from collections import Counter
hi = Counter(r[3] for r in results if r[0] >= 0.80)
print("\nsource of matched training row for exam rows with max-Jaccard >=0.80:", dict(hi))
