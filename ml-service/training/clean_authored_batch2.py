"""Remove normalized duplicates from authored_batch2 without reading the exam."""
import csv, sys
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; sys.path.insert(0,str(ROOT))
from app.core.text_norm import normalize_text
path=ROOT/'data/sentiment/authored_batch2.csv'
rows=list(csv.DictReader(path.open(encoding='utf-8-sig',newline='')))
seen=set(); kept=[]
for row in rows:
    key=' '.join(normalize_text(row['text']).split())
    if key and key not in seen:
        seen.add(key); kept.append(row)
with path.open('w',encoding='utf-8',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['text','label','lang']); w.writeheader(); w.writerows(kept)
print(f'cleaned {len(rows)} -> {len(kept)}; '+str(dict(Counter((r['lang'],r['label']) for r in kept))))
