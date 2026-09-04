"""
Frozen text contract for the intent classifier

WHY THIS EXISTS, AND WHY IT IS NOT `text_norm.py`
`core/text_norm.py` is the sentiment normaliser and it is very good at its job:
it scopes negation onto the following words (`acha nahi tha` -> `acha_neg`), maps
emoji to POLARITY tokens, and collapses money and numbers so a price cannot
become a sentiment feature. Every one of those choices is wrong here.

  * Intent lives in the SHAPE of the utterance, not its polarity. "book nahi
    karna" and "book karna hai" are different INTENTS (cancel vs book), and the
    word that decides it is `nahi` itself -- so `nahi` must survive as a token
    rather than be absorbed into a `_neg` suffix on its neighbour.
  * A 🎉 and a 😡 are the same evidence for intent purposes (both say "this is a
    human being chatting"), so three polarity tokens buy nothing and split the
    feature.
  * Reusing text_norm would bind model #4's retrain cycle to `sentiment-norm-v1`:
    edit the sentiment normaliser to catch a new slang word and the intent model
    is instantly `incompatible` at load. Two models, one file, one shared reason
    to retrain -- a coupling with no upside, since neither model wants the other's
    tokenisation.

So this module is a SEPARATE frozen contract with its own version and its own
fingerprint, gated at load time exactly the way text_norm is for sentiment.

WHAT IT DOES DO
1. Casefold, strip zero-width junk, collapse whitespace.
2. Collapse elongation: `kalllll` -> `kall` (two, not one -- `kal`/`kall` are both
   real spellings and the fold table below decides which is canonical).
3. Fold Roman Urdu spelling variants onto ONE canonical form. `nhi`, `nahin`,
   `nai` and `nahi` are the same word typed by four people; without this they are
   four features and the model has to learn each from ~1/4 of the rows. This is
   the single highest-value transform in the file, because Roman Urdu has no
   orthography to be wrong about.
4. Keep short digit runs, collapse long ones. `F-11`, `5v5` and `2 hours` carry
   intent signal; `3000` and `2500` are a budget the ENTITY EXTRACTOR reads off
   the raw text, and as features they would be 200 hapax terms. Runs of three or
   more digits standing alone become `<num>`.
5. Keep punctuation that changes the reading: `?` -> `<qm>` (question vs
   imperative is a labelled phenomenon in the corpus) and `!` -> `<exc>`. Drop
   the rest.

WHY ONE `prep` AND NOT prep_word/prep_char
The sentiment model needs two views because its negation scoping is meaningful to
the word branch and meaningless to the char branch. Nothing here is view-specific,
so both TF-IDF branches consume the same string. One function, one thing to keep
frozen.

WHY IT LIVES IN core/
A fitted Pipeline pickles `FunctionTransformer(nlu_text.prep)` BY REFERENCE. The
dotted path that existed at fit time must resolve at load time, in the serving
process, or `joblib.load` fails. Training does `from app.core import nlu_text`;
serving loads `app.core.nlu_text.prep`. Same module, same path, no skew.

WHAT IT IS NOT
Not a translator, and not the entity extractor. `kal` stays `kal` here; turning
it into tomorrow's date in Asia/Karachi is `core/entities.py`, which reads the
RAW text (this normaliser has thrown away the digits it needs). The fold table is
exported precisely so entities.py can match one spelling instead of five.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from typing import Iterable, Sequence

#: Bump when any table or regex below changes meaning. The fingerprint catches the
#: edits that forget to.
NLU_TEXT_SPEC_VERSION = "nlu-text-v1"

# Placeholders
#: Standalone digit runs of this length or more collapse to NUM_TOKEN.
LONG_DIGITS = 3

NUM_TOKEN = "<num>"
QM_TOKEN = "<qm>"
EXC_TOKEN = "<exc>"
EMOJI_TOKEN = "<emo>"
URL_TOKEN = "<url>"

#: Every token this module can emit that was not typed by the user. Exported so a
#: caller can tell "the user wrote nothing but placeholders" from real content.
PLACEHOLDERS: tuple[str, ...] = (NUM_TOKEN, QM_TOKEN, EXC_TOKEN, EMOJI_TOKEN, URL_TOKEN)

#: Token pattern for the word branch: whitespace-delimited, so `<num>` and `<qm>`
#: survive as single features instead of being split on their angle brackets.
WORD_TOKEN_PATTERN = r"\S+"

# Regexes
_ZERO_WIDTH = re.compile(
    "[\u200b-\u200f\u2060\ufeff]"  # ZWSP..RLM, word joiner, BOM -- written as
)                                     # escapes because the literals are invisible
_URL = re.compile(r"\b(?:https?://|www\.)\S+", re.IGNORECASE)
#: Three or more of the same letter -> two. Two, not one: `hii` and `hi` are both
#: real, `book` must not become `bok`, and doubling is a normal Roman Urdu
#: lengthening device (`achha`).
_ELONGATION = re.compile(r"(.)\1{2,}", re.UNICODE)
#: A digit run that is not glued to a letter or a hyphen-letter pair. `F-11` and
#: `5v5` are left alone; a bare `3000` is not.
_LONG_DIGITS = re.compile(rf"(?<![0-9A-Za-z-])[0-9]{{{LONG_DIGITS},}}(?![0-9A-Za-z])")
_SPACE = re.compile(r"\s+")
#: Kept out of the drop set below because each one changes how a sentence reads.
_PUNCT_KEEP = {"?": QM_TOKEN, "!": EXC_TOKEN}

# Roman Urdu spelling folds
#
# Roman Urdu is transliteration, so there is no correct spelling to be wrong
# about: `nahi` / `nhi` / `nahin` / `nai` are one word typed by four people. Left
# alone they are four features, each learned from a quarter of the rows that
# should support it. Folded, the model sees one.
#
# The rule for adding to this table: only spellings of the same word. Never fold
# two words that could carry different intents. `karna` (to do) and `karwana` (to
# get done) stay apart; `cancel`/`kensal` fold, `cancel`/`refund` never do. When in
# doubt, leave it out -- a missed variant costs a few features, a wrong fold
# teaches the model that two intents are one.
#
# Canonical form is the spelling that appears most often in
# data/assistant/templates.csv, so the fold is mostly a no-op on the corpus and
# does its work on what a real user types.
_FOLD_GROUPS: dict[str, tuple[str, ...]] = {
    # negation and questions -- the highest-stakes group. `nahi` decides
    # book_venue vs cancel_booking, and it is the most variably spelled word here.
    "nahi": ("nhi", "nahin", "nai", "nahe", "nah", "nhin"),
    "kya": ("kia", "kiya", "kyaa", "kya"),
    "kaise": ("kese", "kaisay", "kese", "kaisa", "kaisi", "kesay"),
    "kahan": ("kahaan", "khn", "kaha", "kdhr", "kidhar", "kithay"),
    "kitna": ("ktna", "kitnaa", "kitne", "kitni", "kitnay", "kitna"),
    "kab": ("kb", "kabh"),
    "kaun": ("kon", "koun", "kaunsa", "konsa", "kaunsi"),
    # verbs of asking / showing / doing
    "dikhao": ("dikhaao", "dekhao", "dikha", "dikhado", "dikhaiye", "dikhayen", "dkhao"),
    "batao": ("btao", "batado", "bta", "btaao", "bataye", "bataiye", "batadein"),
    # One verb, three genders and a plural: karna / karni / karne. Folded
    # together because Urdu agreement carries no intent signal -- "booking
    # karni hai" and "booking karna hai" are the same request.
    "karna": ("krna", "karnaa", "karni", "krni", "karne", "krne", "karnay"),
    "karo": ("kro", "karou", "kardo", "krdo", "kar", "kre", "karen", "kren"),
    "chahiye": ("chahye", "chaiye", "chahiy", "chahie", "chaheye", "chahta", "chahti"),
    "milega": ("milay", "milega", "milge", "mily", "milegi", "mlega"),
    "hai": ("hy", "h", "hai", "he", "hei"),
    "hoga": ("hoga", "hogi", "hoge", "hga"),
    "lena": ("lena", "lenaa", "lna"),
    # time words -- folded to one Roman spelling, not to English. Turning `kal`
    # into a date is entities.py's job and it needs the raw text anyway.
    "aaj": ("aj", "aaj", "ajj"),
    "kal": ("kl", "kall", "kaal"),
    "parso": ("parsun", "parson", "parsoon"),
    "subah": ("subha", "sbh", "sub", "subah", "savera", "sawera"),
    "shaam": ("sham", "shm", "shaam", "shyam"),
    "raat": ("rat", "raat", "rt"),
    "dopahar": ("dopeher", "dopahr", "dupahar", "dophar"),
    "baje": ("bajay", "bje", "bajey", "baj"),
    "waqt": ("wakt", "waqat", "wqt"),
    "din": ("dn", "dinn"),
    "hafta": ("hafte", "haftay", "hafta", "hfta"),
    # the domain nouns. A misspelled venue word is a labelled phenomenon in the
    # corpus (`misspelled_venue`), so these folds are directly exercised.
    "ground": ("grond", "grownd", "graund", "grund", "gorund", "gournd"),
    "maidan": ("medan", "maidaan", "mydan", "medaan"),
    "futsal": ("futsaal", "fusal", "footsal", "futsl"),
    "football": ("futball", "futbal", "footbal", "fotball"),
    "cricket": ("crickit", "krikat", "cricit", "kricket", "cricke"),
    "badminton": ("badmintan", "badmiton", "badminten", "batminton"),
    "booking": ("buking", "bookng", "bkng", "bukking"),
    "wallet": ("walet", "wallett", "waalet"),
    "paisa": ("pesa", "paise", "pese", "paisay", "pesay"),
    "team": ("teem", "tem", "tim"),
    "match": ("mach", "matchh", "mtch"),
    "cancel": ("kensal", "cancle", "canel", "cancal", "kansal"),
    "refund": ("rifund", "refnd", "riffund", "refund"),
    "tournament": ("tornament", "tournment", "turnament", "tournamnt"),
    "khelna": ("khailna", "khelnaa", "khelne", "kheln"),
    "jagah": ("jaga", "jgah", "jagha"),
    "sasta": ("sastaa", "sasti", "sastay", "sst"),
    "khali": ("khaali", "khali", "khli"),
    # pronouns and particles that appear in every second utterance
    "mujhe": ("mjhe", "muje", "mujy", "mujhy", "mje"),
    "mera": ("mra", "meraa", "meri", "mere"),
    "apna": ("apnaa", "apni", "apne", "apn"),
    "ke": ("k", "ky", "ke"),
    "se": ("sy", "se"),
    "tak": ("tk", "tak"),
    "wala": ("wla", "walaa", "wali", "wale", "waly"),
    "please": ("pls", "plz", "plez", "pleas"),
    "thanks": ("thanx", "thnx", "thankyou", "thnks", "tnx"),
}

#: Different words, identical evidence for intent. Kept apart from _FOLD_GROUPS
#: because the rule there is "spellings of the same word", and these are not that
#: -- "soccer" and "football" are two languages agreeing, and folding them is a
#: modelling choice rather than a spelling repair. Worth making anyway: the corpus
#: is bilingual by design, so the alternative is learning "show me a soccer pitch"
#: and "football ground dikhao" as unrelated evidence for one intent.
#:
#: Sport names are not normalised away here. `futsal` does not fold to `football`
#: even though a careless reader might call them the same game: the entity
#: extractor has to tell them apart to filter a catalogue, and a classifier that
#: never saw the difference cannot help it.
SYNONYM: dict[str, str] = {
    "soccer": "football",
    "shukriya": "thanks",
    "shukria": "thanks",
    "mehrbani": "thanks",
    "ta": "thanks",
    "salam": "hello",
    "salaam": "hello",
    "assalamualaikum": "hello",
    "aoa": "hello",
    "hi": "hello",
    "hey": "hello",
    "hii": "hello",
    "yo": "hello",
    "hallo": "hello",
    "helo": "hello",
    "ground": "ground",
    "turf": "ground",
    "pitch": "ground",
    "field": "ground",
    "arena": "ground",
    "maidan": "ground",
    "venue": "ground",
}

#: token -> canonical, flattened from _FOLD_GROUPS at import.
FOLD: dict[str, str] = {
    variant: canon
    for canon, variants in _FOLD_GROUPS.items()
    for variant in (canon, *variants)
}

#: Multi-word variants, folded before tokenisation because no per-token rule can
#: see across the space. Deliberately tiny: each entry is a phrase whose parts
#: would otherwise fold to something misleading on their own.
PHRASE_FOLD: tuple[tuple[str, str], ...] = (
    ("day after tomorrow", "parso"),
    ("din baad", "din baad"),
    ("kar do", "karo"),
    ("kar dain", "karo"),
    ("dikha do", "dikhao"),
    ("dikha dain", "dikhao"),
    ("bata do", "batao"),
    ("bata dain", "batao"),
    ("tape ball", "tapeball"),
    ("hard ball", "hardball"),
    ("five a side", "5v5"),
    ("thank you", "thanks"),
    ("sports complex", "sportscomplex"),
)


# The normaliser
def fold_token(token: str) -> str:
    """One token through the spelling folds, then the synonym map.

    Order matters: `nhi` -> `nahi` is a spelling repair and `soccer` -> `football`
    is a synonym, so a variant spelling of a synonym (`futbal`) has to become the
    canonical word before the synonym map can recognise it.
    """
    token = FOLD.get(token, token)
    return SYNONYM.get(token, token)


def normalize(text: str) -> str:
    """Raw user text -> the string the classifier is fitted on.

    Order is deliberate and each step is here because a later one depends on it:
    strip invisibles (a zero-width joiner inside a word defeats every table
    below), URLs before punctuation (`?` inside a query string is not a question),
    elongation before the fold table (`nhiii` has to become `nhii` -> `nhi` before
    it can be looked up), digits before punctuation (so `3,000` is one run, not
    two), and the fold last, on whole tokens only.
    """
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", str(text))
    text = _ZERO_WIDTH.sub("", text)
    text = text.casefold()
    text = _URL.sub(f" {URL_TOKEN} ", text)
    for phrase, replacement in PHRASE_FOLD:
        if phrase in text:
            text = text.replace(phrase, replacement)
    text = _ELONGATION.sub(r"\1\1", text)
    # Thousands separators first: `3,000` and `3 000` are one number to a reader
    # and two tokens to a tokeniser.
    text = re.sub(r"(?<=[0-9])[,٬](?=[0-9]{3})", "", text)
    text = _LONG_DIGITS.sub(f" {NUM_TOKEN} ", text)
    out: list[str] = []
    for ch in text:
        if ch in _PUNCT_KEEP:
            out.append(f" {_PUNCT_KEEP[ch]} ")
        elif ch.isalnum() or ch.isspace() or ch in "-<>":
            out.append(ch)
        elif _is_emoji(ch):
            out.append(f" {EMOJI_TOKEN} ")
        else:
            # Everything else -- commas, full stops, quotes, brackets -- becomes a
            # space rather than vanishing, so `f-11,football` cannot weld into one
            # token that appears nowhere else in the corpus.
            out.append(" ")
    text = _SPACE.sub(" ", "".join(out)).strip()
    return " ".join(fold_token(tok) for tok in text.split(" ") if tok)


def _is_emoji(ch: str) -> bool:
    """True for pictographic characters, by Unicode category and block.

    `unicodedata.category(ch) == "So"` catches most of it. The ranges add the
    pieces that are not `So` -- regional indicators, the emoji presentation
    selectors -- without pulling in a dependency for five lines of table.
    """
    if unicodedata.category(ch) == "So":
        return True
    code = ord(ch)
    return (
        0x1F000 <= code <= 0x1FAFF
        or 0x2600 <= code <= 0x27BF
        or 0xFE00 <= code <= 0xFE0F
        or 0x1F1E6 <= code <= 0x1F1FF
    )


def prep(texts: Iterable[str]) -> list[str]:
    """`FunctionTransformer` entry point: a sequence of raw texts -> normalised.

    Both TF-IDF branches call this same function -- see the module docstring for
    why the intent model needs one view of the text and not two.
    """
    return [normalize(t) for t in texts]


def tokens(text: str) -> list[str]:
    """The word-branch tokens for `text`. Handy in tests and in error messages."""
    return normalize(text).split()


def content_tokens(text: str) -> list[str]:
    """Tokens with the placeholders removed -- what the user actually typed.

    An utterance that normalises to nothing but `<num> <qm>` carries no lexical
    evidence at all, and the router would rather answer "I didn't catch that" than
    hand a classifier two placeholders and publish whatever comes back.
    """
    return [t for t in tokens(text) if t not in PLACEHOLDERS]


# The fingerprint
def nlu_text_fingerprint() -> str:
    """sha256 (16 hex chars) over every table and regex that changes the output.

    The version string is a promise a human makes; this is the mechanism that
    catches the day someone adds a fold and forgets to keep the promise. A model
    fitted on `nhi -> nahi` and served by a process that no longer folds it will
    predict confidently and wrongly, which is the failure mode the registry gate
    exists to make impossible.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", NLU_TEXT_SPEC_VERSION)
    feed("placeholders", "|".join(PLACEHOLDERS))
    feed("long_digits", LONG_DIGITS)
    feed("word_token_pattern", WORD_TOKEN_PATTERN)
    for canon in sorted(_FOLD_GROUPS):
        feed(f"fold:{canon}", "|".join(sorted(_FOLD_GROUPS[canon])))
    for variant in sorted(SYNONYM):
        feed(f"syn:{variant}", SYNONYM[variant])
    feed("phrases", "|".join(f"{a}>{b}" for a, b in PHRASE_FOLD))
    feed("punct_keep", "|".join(f"{k}>{v}" for k, v in sorted(_PUNCT_KEEP.items())))
    for name, pattern in (
        ("zero_width", _ZERO_WIDTH),
        ("url", _URL),
        ("elongation", _ELONGATION),
        ("long_digits_re", _LONG_DIGITS),
        ("space", _SPACE),
    ):
        feed(f"re:{name}", pattern.pattern)
    return digest.hexdigest()[:16]


def describe() -> dict[str, object]:
    """What `GET /nlu/spec` publishes about this contract."""
    return {
        "specVersion": NLU_TEXT_SPEC_VERSION,
        "fingerprint": nlu_text_fingerprint(),
        "placeholders": list(PLACEHOLDERS),
        "foldGroups": len(_FOLD_GROUPS),
        "foldEntries": len(FOLD),
        "synonyms": len(SYNONYM),
        "phraseFolds": len(PHRASE_FOLD),
        "longDigits": LONG_DIGITS,
    }


# Self-check
#: (raw, expected) pairs. Pinned, so a fold added tomorrow that changes one of
#: these fails loudly here instead of quietly in the next training run.
_CASES: tuple[tuple[str, str], ...] = (
    ("Kal shaam Islamabad me football ground dikhao",
     "kal shaam islamabad me football ground dikhao"),
    ("KAL SHAAAAM F-11 me futbal grownd dikha do",
     "kal shaam f-11 me football ground dikhao"),
    ("mujhe 3000 se kam wala turf chahiye",
     "mujhe <num> se kam wala ground chahiye"),
    ("kya aaj koi ground khali hai??", "kya aaj koi ground khali hai <qm> <qm>"),
    ("booking cancel krni hai!!!", "booking cancel karna hai <exc> <exc>"),
    ("5v5 futsal 2 hours", "5v5 futsal 2 hours"),
    ("Rs 2,500 tak", "rs <num> tak"),
    ("assalamualaikum", "hello"),
    ("check https://x.com/a?b=1 now", "check <url> now"),
    ("", ""),
    ("😡", EMOJI_TOKEN),
    ("nhi   nahin  nai", "nahi nahi nahi"),
)


def self_check() -> int:
    """Assert the pinned cases and the invariants. Returns the number of checks."""
    checks = 0
    for raw, expected in _CASES:
        got = normalize(raw)
        assert got == expected, f"normalize({raw!r}) -> {got!r}, expected {expected!r}"
        checks += 1

    # Idempotence: normalising twice must not move. A fold table with a cycle
    # (`a -> b`, `b -> a`) would break this and nothing else would notice.
    for raw, _ in _CASES:
        once = normalize(raw)
        assert normalize(once) == once, f"not idempotent: {raw!r} -> {once!r}"
    checks += 1

    # No fold target is itself a variant of something else -- that would make the
    # result depend on dict iteration order.
    for canon in _FOLD_GROUPS:
        target = SYNONYM.get(canon, canon)
        assert FOLD.get(target, target) == target, f"chained fold via {canon!r}"
    checks += 1

    # A variant may not appear in two groups: one spelling, one canonical form.
    seen: dict[str, str] = {}
    for canon, variants in _FOLD_GROUPS.items():
        for variant in variants:
            assert variant not in seen or seen[variant] == canon, (
                f"{variant!r} folds to both {seen[variant]!r} and {canon!r}"
            )
            seen[variant] = canon
    checks += 1

    # Placeholders survive tokenisation as single tokens.
    for token in PLACEHOLDERS:
        assert re.fullmatch(WORD_TOKEN_PATTERN, token), token
    checks += 1

    assert len(nlu_text_fingerprint()) == 16
    checks += 1
    return checks


def main(argv: Sequence[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Self-check the NLU text contract.")
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--normalize", metavar="TEXT", help="print the normalised form and exit")
    args = ap.parse_args(list(argv) if argv is not None else None)
    if args.normalize is not None:
        print(normalize(args.normalize))
        return 0
    checks = self_check()
    print(f"PASS  {checks} checks, {NLU_TEXT_SPEC_VERSION} / {nlu_text_fingerprint()}")
    print(f"      {len(FOLD)} fold entries over {len(_FOLD_GROUPS)} groups, "
          f"{len(SYNONYM)} synonyms, {len(PHRASE_FOLD)} phrase folds")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())


__all__ = (
    "NLU_TEXT_SPEC_VERSION", "PLACEHOLDERS", "WORD_TOKEN_PATTERN", "FOLD", "SYNONYM",
    "PHRASE_FOLD", "NUM_TOKEN", "QM_TOKEN", "EXC_TOKEN", "EMOJI_TOKEN", "URL_TOKEN",
    "normalize", "prep", "tokens", "content_tokens", "fold_token",
    "nlu_text_fingerprint", "describe", "self_check",
)
