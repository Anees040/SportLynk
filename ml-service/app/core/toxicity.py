"""
Abuse / profanity guard  —  S.4 Wave B  (FR9.10)

WHAT THIS IS, AND WHAT IT IS DELIBERATELY NOT
This flags ABUSIVE LANGUAGE — profanity and slurs — in a review. It is NOT a
negative-sentiment detector, and the two must not be confused:

    "worst turf in the city, the booking staff ignored us for an hour"
        -> strongly NEGATIVE, contains no abuse -> NOT toxic

    "chutiya management, complete bakwas"
        -> abusive -> toxic, regardless of the sentiment score

The earlier version conflated them: it OR-ed the lexicon with `P(negative) > 0.90`,
which would have flagged every angry-but-clean one-star review as "toxic" and
buried real moderation cases in noise. Sentiment and abuse are orthogonal signals
and are kept orthogonal here — the model answers "how negative", this module
answers "is it abusive", and the router reports both without merging them. The
strong-negative escalation (P(negative) over a threshold) is the router's policy,
not this module's concern.

WHY A LEXICON (and not the classifier)
Moderation must be EXPLAINABLE and STABLE: a review is flagged because a specific
term appears, and we can name that term. A learned toxicity head on ~21k rows would
be neither — it would drift with retraining and could not justify a takedown. A
curated term list is auditable, deterministic, and cheap, which is the right
trade-off for an FYP moderation guard. Its cost is coverage (no obfuscation
handling, e.g. "f*ck"); that limitation is stated in the model card.

MATCHING
Word-token matching on the lowercased text, never substring: substring matching
flags "class" for containing "ass" and "grass" for "ass" — the classic scunthorpe
problem. Tokenising first means only whole tokens count. A token also matches under
a light plural fold ("idiots"→"idiot", "bitches"→"bitch") so the obvious inflection
does not slip through; folding only ever SHORTENS a token to a listed term, so it
cannot invent a hit from an innocent word. It does not handle obfuscation ("f*ck")
or spacing ("bhen chod") — stated as a limitation in the model card.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

#: The lexicon lives with the data, not the code, so it can be reviewed and its
#: sha256 recorded in the model-metrics record (the trainer stamps it) without a
#: code change. Same path resolution the trainer uses.
LEXICON_PATH = Path(__file__).resolve().parents[2] / "data" / "abuse_lexicon.txt"

#: Token = run of letters/digits/apostrophes. Roman Urdu abuse is ASCII, so this
#: covers both English and Roman Urdu; it is intentionally NOT unicode-word (\w)
#: because we match against an ASCII lexicon and want no surprises from scripts.
_TOKEN_RE = re.compile(r"[a-z0-9']+")


def _lemmas(token: str):
    """Yield the token and its light singular folds, longest-first.

    Only strips a trailing plural `s` / `es`; both merely shorten the token, so a
    fold can only ever land on a SHORTER listed term, never manufacture a match
    from an unrelated word ("dumps"→"dump" is not in the lexicon; "idiots"→"idiot"
    is). Irregular plurals are out of scope by design — see the module docstring.
    """
    yield token
    if len(token) >= 5 and token.endswith("es"):
        yield token[:-2]
    if len(token) >= 4 and token.endswith("s"):
        yield token[:-1]


def _load_terms(path: Path) -> frozenset[str]:
    """Read the lexicon: one term per line, `#` comments and blanks ignored."""
    if not path.exists():
        return frozenset()
    out: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        term = line.strip().lower()
        if term and not term.startswith("#"):
            out.add(term)
    return frozenset(out)


#: Loaded once at import. Small (tens of terms); a set lookup per token is trivial.
TERMS: frozenset[str] = _load_terms(LEXICON_PATH)


@dataclass(frozen=True)
class ToxicityResult:
    """The verdict plus its evidence.

    `matched` is the whole point: a moderation flag a human can act on says WHICH
    terms fired, so the review can be triaged (or the flag disputed) without
    re-running anything. Empty tuple ⇔ not flagged.
    """

    flagged: bool
    matched: tuple[str, ...] = field(default_factory=tuple)

    def as_dict(self) -> dict:
        # camelCase-free here on purpose: the router shapes the wire format; this
        # is the internal view. `matched` is a list for JSON-friendliness upstream.
        return {"flagged": self.flagged, "matched": list(self.matched)}


def check(text: str) -> ToxicityResult:
    """Return the abuse verdict for `text` and the exact terms that triggered it.

    Deterministic and side-effect free. Unknown/empty input is simply not flagged.
    """
    if not text:
        return ToxicityResult(flagged=False)
    hits: set[str] = set()
    for token in _TOKEN_RE.findall(text.lower()):
        for lemma in _lemmas(token):
            if lemma in TERMS:
                hits.add(lemma)  # record the LISTED term, not the inflected token
                break
    return ToxicityResult(flagged=bool(hits), matched=tuple(sorted(hits)))


def is_abusive(text: str) -> bool:
    """Boolean convenience wrapper around :func:`check`."""
    return check(text).flagged


__all__ = ("ToxicityResult", "TERMS", "LEXICON_PATH", "check", "is_abusive")
