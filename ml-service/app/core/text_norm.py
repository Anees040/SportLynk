"""Shared text normalisation for the SportLynk review sentiment model (S.4).

THIS MODULE IS THE FEATURE CONTRACT FOR MODEL #2.
Training imports it, serving imports it, and neither is allowed its own copy of
any transformation below. The mirror of ``app/core/features.py`` for model #1.

Why the coupling is unusually tight here
────────────────────────────────────────
The sentiment pipeline is a single ``sklearn`` object that starts with
``FunctionTransformer(prep_word)`` and ``FunctionTransformer(prep_char)``.
``joblib`` pickles a ``FunctionTransformer``'s callable **by reference**
(``app.core.text_norm.prep_word``), not by value. So the artifact does not carry
the normaliser -- it carries a *pointer* to whatever this file says at load
time. Edit the lexicon after training and the served model silently changes
behaviour with no version bump anywhere.

That is why this module publishes ``NORM_SPEC_VERSION`` **and**
``norm_spec_fingerprint()``. A bare version string was enough for
``features.py`` (a short, hand-edited list of derivations a reviewer reads in
full). It is not enough here: ``VARIANTS`` is a ~200-entry table that a future
contributor will extend without thinking about versioning. The fingerprint
hashes the actual tables, so a forgotten bump is caught mechanically at model
load instead of showing up as unexplained accuracy drift three weeks later.

Design decisions that are load-bearing (do not "simplify" these)
────────────────────────────────────────────────────────────────
1. Placeholder tokens are emitted as ``<num>``, ``<url>``, ``<posemo>`` ... and
   the characters ``<``, ``>`` and ``_`` are stripped from the *input* before
   any placeholder is inserted. A reviewer therefore cannot type ``<num>`` or
   ``acha_neg`` and forge a feature the model trusts. Consequence, stated
   plainly: ``normalize_text`` is idempotent only on placeholder-free output.
   Re-normalising ``"<money>"`` yields ``"money"``. Training and serving each
   normalise raw text exactly once, so this is a guard, not a bug -- but both
   halves of it are pinned by ``self_check()`` so nobody "fixes" it by accident.

2. Character runs collapse ``3+ -> 2``, never ``3+ -> 1``. ``3+ -> 1`` is the
   obvious implementation and it destroys English: ``good -> god``,
   ``cool -> col``, ``all -> al``. Collapsing to two leaves a doubled residue
   (``bohatttt -> bohatt``), so ``VARIANTS`` carries deliberate residue keys
   (``bohatt``, ``achaa``, ``nicee``, ``bestt``, ``soo``) to close the gap.
   Every key must be collapse-stable or it can never match -- ``self_check()``
   asserts this, because it is not obvious and it silently disables entries.

3. Negation is **direction-aware**. Roman Urdu negators scope LEFT
   ("acha nahi tha" = good-not-was); English negators scope RIGHT ("not good").
   A single direction-blind rule cannot serve a code-switched corpus, and
   negation was the single largest error class in the first attempt at this
   model: 12 of 20 recorded errors were negatives, 11 of them containing
   "nahi". ``mark_negation`` rewrites the offending token in the word stream
   (``acha`` -> ``acha_neg``) because a negated "acha" is genuinely not
   positive evidence.

4. The ``_neg`` suffix is applied to the WORD stream only. The character stream
   sees plain normalised text -- char n-grams exist to survive Roman Urdu
   spelling chaos, and a repeated four-character suffix would eat a large share
   of ``max_features`` to say nothing.

5. Urdu script is KEPT, not stripped. ``[^\\w<>\\s]`` is Unicode-aware, so
   Arabic-block base letters survive (optional harakat diacritics do not, which
   matches how Urdu is actually typed). We have no Urdu-script training data, so
   serving uses ``has_urdu_script()`` to flag such reviews as low confidence
   rather than scoring them as if they were in-distribution.

6. stdlib only (``re``, ``unicodedata``, ``hashlib``). Unlike ``features.py``
   this module is imported by corpus builders, annotation tools and a CLI, so it
   must not drag in pandas.

Data written as escapes, on purpose
───────────────────────────────────
Emoji, typographic punctuation and the Urdu test literal are written as
``\\uXXXX`` / ``\\UXXXXXXXX`` escapes rather than pasted characters. This file
will be opened by editors on Windows where a stray cp1252 round-trip would
mojibake pasted emoji into plausible-looking garbage that no test would catch,
and would turn the control-character class into an unreadable mess. Escapes
cannot mojibake.

WHAT THIS MODULE DELIBERATELY DOES NOT DO
─────────────────────────────────────────
* No stemming or lemmatising. Roman Urdu has no stable morphology to stem and
  the char n-gram branch already absorbs inflection.
* No stopword removal. "nahi", "na", "koi", "hi" look like stopwords and are
  the most important tokens in the corpus.
* No transliteration to Urdu script. That is a research project, not a feature.
* No spell correction beyond the closed ``VARIANTS`` table. An open-vocabulary
  corrector cannot be version-fingerprinted, so it cannot be part of a
  contract.
* No sentiment lexicon scoring. Polarity is learned, not asserted -- the
  committee requires a genuinely trained model, so nothing here may assign a
  sign to a word.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from typing import Iterable, Sequence

# 1. Contract identity

#: Bump this whenever any table, regex or step order below changes.
#: Stamped into the joblib payload as ``normSpecVersion`` and re-checked at
#: load; a mismatch makes the model ``incompatible`` rather than wrong.
NORM_SPEC_VERSION: str = "sentiment-norm-v1"

#: The label set, in the exact order used for every ``labels=`` argument, every
#: confusion-matrix axis and every ``predict_proba`` column.
#: Alphabetical on purpose: this is also scikit-learn's own default ordering for
#: string classes, so ``model.classes_`` lines up with this tuple without any
#: remapping. The spellings match the CHECK constraint in
#: ``backend/migrations/013_*.sql`` -- not the ``pos/neu/neg`` shorthand used in
#: the plan's prose.
LABELS: tuple[str, str, str] = ("negative", "neutral", "positive")

#: Maximum length of a run of one repeated character after collapsing.
#: 2, never 1 -- see design note 2 in the module docstring.
MAX_RUN: int = 2

#: Shortest allowed ``VARIANTS`` key. Two-character Roman Urdu tokens (``km``,
#: ``nh``, ``hy``, ``bt``, ``jo``) are too ambiguous to fold safely; each has at
#: least two common expansions with different polarity.
MIN_VARIANT_KEY_LEN: int = 3

#: How many *content* tokens one negator may mark.
NEG_WINDOW: int = 2

#: How many tokens a negator may walk over in total while looking for content
#: tokens. Bounds the cost of long skip chains ("baat karne ka tareeqa hi nahi").
NEG_MAX_WALK: int = 5

#: Suffix appended to a negated token in the word stream.
NEG_SUFFIX: str = "_neg"

#: ``token_pattern`` that must be handed to the word-branch ``TfidfVectorizer``.
#: scikit-learn's default (``(?u)\b\w\w+\b``) silently discards the angle
#: brackets, which would collapse the placeholder ``<num>`` and a reviewer
#: typing the word "num" into the same feature -- defeating the forgery guard in
#: design note 1. ``prep_word`` already emits clean space-separated tokens, so
#: splitting on whitespace is both correct and lossless. It is a plain string,
#: so it pickles safely.
WORD_TOKEN_PATTERN: str = r"\S+"


# 2. Placeholder vocabulary

URL_TOKEN = "<url>"
EMAIL_TOKEN = "<email>"
USER_TOKEN = "<user>"
PHONE_TOKEN = "<phone>"
MONEY_TOKEN = "<money>"
NUM_TOKEN = "<num>"
SEP_TOKEN = "<sep>"
EXC_TOKEN = "<exc>"
QM_TOKEN = "<qm>"
POS_EMOJI_TOKEN = "<posemo>"
NEG_EMOJI_TOKEN = "<negemo>"
NEU_EMOJI_TOKEN = "<neuemo>"
EMOJI_TOKEN = "<emo>"

#: Every token this module can synthesise. No underscores: the punctuation pass
#: strips ``_`` (reserved for ``NEG_SUFFIX``), so a placeholder containing one
#: would be torn into two tokens.
PLACEHOLDERS: tuple[str, ...] = (
    URL_TOKEN,
    EMAIL_TOKEN,
    USER_TOKEN,
    PHONE_TOKEN,
    MONEY_TOKEN,
    NUM_TOKEN,
    SEP_TOKEN,
    EXC_TOKEN,
    QM_TOKEN,
    POS_EMOJI_TOKEN,
    NEG_EMOJI_TOKEN,
    NEU_EMOJI_TOKEN,
    EMOJI_TOKEN,
)


# 3. Compiled patterns

#: Control characters, zero-width joiners, bidi overrides, variation selectors,
#: emoji skin-tone modifiers and combining enclosing marks (keycap sequences).
#: Tab / newline / carriage-return are deliberately not here -- they are clause
#: boundaries and are handled by ``_RE_SEP``.
#: The last range is "Combining Diacritical Marks for Symbols", which contains
#: nothing from any Arabic block, so Urdu text is untouched by it.
_RE_JUNK = re.compile(
    "["
    "---"  # C0 / C1 controls
    "­"                                               # soft hyphen
    "​-‏‪-‮"                           # zero-width, ZWJ, bidi
    "⁠-⁤⁪-⁯"                           # word joiner, deprecated
    "﻿"                                               # BOM
    "︀-️"                                        # variation selectors
    "\U0001f3fb-\U0001f3ff"                                # emoji skin tones
    "⃐-⃰"                                        # enclosing marks
    "]"
)

#: Typographic characters NFKC leaves alone but that break naive tokenising.
#: The right single quote is the one that matters: phone keyboards insert it
#: instead of the ASCII apostrophe, so without this the contraction rules below
#: would miss every "don't" typed on a real device.
_QUOTE_MAP = {
    "‘": "'",    # left single quote
    "’": "'",    # right single quote -- what phone keyboards insert
    "‚": "'",    # single low-9 quote
    "‛": "'",    # single high-reversed-9 quote
    "′": "'",    # prime
    "“": '"',    # left double quote
    "”": '"',    # right double quote
    "„": '"',    # double low-9 quote
    "″": '"',    # double prime
    "–": "-",    # en dash
    "—": "-",    # em dash
    "―": "-",    # horizontal bar
    "−": "-",    # minus sign
    " ": " ",    # no-break space
    " ": " ",    # figure space
    " ": " ",    # narrow no-break space
    " ": "\n",   # line separator
    " ": "\n",   # paragraph separator
}
_QUOTE_TABLE = str.maketrans(_QUOTE_MAP)

#: Contractions are expanded before punctuation is stripped, because afterwards
#: "don't" and "dont" are indistinguishable from "do" + "nt".
#:
#: The apostrophe is optional only for the ``n't`` family, where the
#: apostrophe-less spelling is ubiquitous and near-unambiguous. It is required
#: for ``'ll`` / ``'d`` / ``'ve`` / ``'re`` / ``'s``, because making it optional
#: there rewrites ordinary English: ``well -> we will``, ``ill -> i will``,
#: ``shed -> she would``, ``hell -> he will``. "well maintained ground" is a
#: sentence this corpus contains.
#:
#: Known and accepted cost: "cant" (insincere talk) and "wont" (accustomed) are
#: real English words read here as can't / won't. In venue reviews that trade is
#: overwhelmingly correct.
_CONTRACTIONS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bwo?n'?t\b"), "will not"),
    (re.compile(r"\bca'?n'?t\b|\bcannot\b"), "cannot"),
    (re.compile(r"\bsha'?n'?t\b"), "shall not"),
    (re.compile(r"\bai'?n'?t\b"), "is not"),
    (
        re.compile(
            r"\b(do|does|did|is|was|are|were|has|have|had"
            r"|could|should|would|must|need|dare)n'?t\b"
        ),
        r"\1 not",
    ),
    (re.compile(r"\b(i|you|we|they)'ve\b"), r"\1 have"),
    (re.compile(r"\b(i|you|we|they|he|she|it)'ll\b"), r"\1 will"),
    (re.compile(r"\b(i|you|we|they|he|she|it)'d\b"), r"\1 would"),
    (re.compile(r"\b(you|we|they)'re\b"), r"\1 are"),
    (re.compile(r"\bi'?m\b"), "i am"),
    (re.compile(r"\b(it|that|there|he|she|what|who|here)'s\b"), r"\1 is"),
    (re.compile(r"\blet'?s\b"), "let us"),
)

_RE_URL = re.compile(r"(?:https?://|www\.)\S+", re.IGNORECASE)
_RE_EMAIL = re.compile(r"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}", re.IGNORECASE)
#: Bounded to one token on purpose. guard_placeholders strips '_' first, so a
#: handle like "@sportlynk_pk" arrives here as "@sportlynk pk"; this matches
#: "@sportlynk" and leaves a harmless "pk". Do not append a "(?: \w+)*" group to
#: swallow that "pk" -- it is greedy and eats the entire review after any
#: mid-sentence @mention ("@owner responded fast" -> "<user>").
_RE_MENTION = re.compile(r"@[a-z0-9_.]{2,}", re.IGNORECASE)

#: Pakistani mobile numbers only, kept deliberately narrow. A generic "run of
#: 10+ digits" rule would swallow prices, and a price is the most common numeric
#: token in a venue review.
_RE_PHONE = re.compile(r"(?<!\d)(?:\+?92|0)[\s\-]?3\d{2}[\s\-]?\d{7}(?!\d)")

#: ``₨`` is the rupee sign. Both orders occur in the wild: "Rs 3000" and
#: "3000 rupay".
_RE_MONEY = re.compile(
    r"(?:(?:rs|rps|pkr|₨)\.?\s*\d[\d,]*(?:\.\d+)?)"
    r"|(?:\d[\d,]*(?:\.\d+)?\s*(?:rs\b|rupees?\b|rupaye\b|rupay\b|pkr\b))",
    re.IGNORECASE,
)

_RE_NUM = re.compile(r"\d+(?:[.,]\d+)?")

#: Cap runs of the same punctuation mark at two, so "!!!!!" contributes two
#: intensity tokens instead of five. Runs are capped before substitution because
#: ``<exc> <exc> <exc>`` is not a character run and would sail past ``_RE_RUN``.
_RE_PUNCT_RUN = re.compile(r"([!?.,])\1+")

_RE_EXC = re.compile(r"!")
_RE_QM = re.compile(r"\?")
_RE_SEP = re.compile(r"[.,;:…\n\r]")

#: Everything that is not a word character, an angle bracket, or whitespace.
#: ``\w`` is Unicode-aware, which is exactly why Urdu script survives.
_RE_NON_TOKEN = re.compile(r"[^\w<>\s]")

#: A run of 3 or more of one character -> exactly two. See design note 2.
_RE_RUN = re.compile(r"(\w)\1{2,}")

_RE_WS = re.compile(r"\s+")

#: Arabic / Urdu script blocks. Presence means the input is outside the training
#: distribution -- the corpus is Roman Urdu and English only.
_RE_URDU = re.compile(
    "["
    "؀-ۿ"   # Arabic
    "ݐ-ݿ"   # Arabic Supplement
    "ࢠ-ࣿ"   # Arabic Extended-A
    "ﭐ-﷿"   # Arabic Presentation Forms-A
    "ﹰ-﻿"   # Arabic Presentation Forms-B
    "]"
)

#: The emoji planes recognised here. Anything matched but absent from
#: ``EMOJI_POLARITY`` becomes ``<emo>`` -- "an emoji with no assigned polarity",
#: which is itself a usable feature. Folding every emoji into one
#: token would make a heart-eyes face and a rage face identical evidence, which
#: is what the first attempt at this module did.
_RE_EMOJI = re.compile(
    "["
    "☀-➿"           # Misc Symbols + Dingbats (heart, warning, check)
    "⬀-⯿"           # Misc Symbols and Arrows (star)
    "\U0001f000-\U0001faff"   # Emoticons, Pictographs, Transport, Supplemental
    "]"
)


# 4. Emoji polarity

_EMOJI_GROUPS: tuple[tuple[str, str], ...] = (
    (
        # grinning, smiley, smile, grin, laughing, blush, slight-smile, wink,
        # heart-eyes, hearts-face, kissing-heart, star-struck, sunglasses,
        # joy, rofl
        "\U0001f600\U0001f603\U0001f604\U0001f601\U0001f606\U0001f60a"
        "\U0001f642\U0001f609\U0001f60d\U0001f970\U0001f618\U0001f929"
        "\U0001f60e\U0001f602\U0001f923"
        # thumbs-up, raised-hands, clap, ok-hand, handshake, fire,
        # hundred-points, trophy, sparkling-heart, two-hearts, green-heart
        "\U0001f44d\U0001f64c\U0001f44f\U0001f44c\U0001f91d\U0001f525"
        "\U0001f4af\U0001f3c6\U0001f496\U0001f495\U0001f49a"
        # red-heart, star, sparkles, check-mark-button
        "❤⭐✨✅",
        POS_EMOJI_TOKEN,
    ),
    (
        # unamused, disappointed, pensive, crying, loudly-crying, angry,
        # pouting, swearing, vomiting, triumph, confused, slight-frown,
        # weary, tired, rolling-eyes, facepalm
        "\U0001f612\U0001f61e\U0001f614\U0001f622\U0001f62d\U0001f620"
        "\U0001f621\U0001f92c\U0001f92e\U0001f624\U0001f615\U0001f641"
        "\U0001f629\U0001f62b\U0001f644\U0001f926"
        # thumbs-down, poo, broken-heart
        "\U0001f44e\U0001f4a9\U0001f494"
        # frowning-face, warning, cross-mark
        "☹⚠❌",
        NEG_EMOJI_TOKEN,
    ),
    (
        # neutral-face, expressionless, thinking, shrug, no-mouth
        "\U0001f610\U0001f611\U0001f914\U0001f937\U0001f636",
        NEU_EMOJI_TOKEN,
    ),
)

#: char -> polarity placeholder.
EMOJI_POLARITY: dict[str, str] = {
    char: token for chars, token in _EMOJI_GROUPS for char in chars
}


# 5. Spelling variants
#
# Whole-token folding only, applied after run collapsing -- so every key must
# already be collapse-stable (no run of 3+). ``self_check()`` proves that, plus
# key length, lowercase, no key->key chains, and value idempotency.
#
# Written as (canonical, variants) groups rather than a flat dict because the
# grouping makes "the canonical is never also a variant" structurally obvious
# and lets the checker catch a variant listed under two canonicals.
#
# Entries ending in a doubled character (``bohatt``, ``achaa``, ``nicee``) are
# collapse residue keys, not typos: ``bohatttt`` -> ``bohatt`` -> ``bohat``.
# Deleting them silently breaks elongation handling, which is the single most
# common orthographic feature of Roman Urdu reviews.

_VARIANT_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    # Roman Urdu polarity core
    ("acha", ("achha", "accha", "acchi", "achi", "achhi", "achay", "achey",
              "ache", "achaa", "aacha", "axa", "axha")),
    ("bura", ("buraa", "boora", "buraah")),
    ("bohat", ("bohot", "bahut", "bohut", "buhat", "bahot", "bhot", "boht",
               "bht", "bhaut", "bohatt", "bahuth")),
    ("nahi", ("nahin", "nhi", "nahe", "nahii", "naheen", "nahien", "nhii")),
    ("theek", ("thk", "thik", "teek", "theak", "theik", "thek", "thike")),
    ("kharab", ("karab", "kharaab", "khrab", "kharap", "kharb")),
    ("bakwas", ("bakwaas", "bkwas", "bakwass", "bakwaz")),
    ("ganda", ("gnda", "gandi", "gande", "ghanda", "gandaa")),
    ("gandagi", ("gandgi", "gandagee")),
    ("maza", ("mza", "mazaa", "maja", "mazay", "maze", "mazza", "mzaa")),
    ("mazedar", ("mazaydar", "mazedaar", "mzedar", "mazaidar")),
    ("behtareen", ("behtreen", "behtarin", "bahtareen", "behterin", "behtrin")),
    ("behtar", ("behter", "behtr", "bahtar")),
    ("shandaar", ("shandar", "shaandar", "shaandaar")),
    ("zabardast", ("zbardast", "zabrdast", "jabardast", "zabardust",
                   "zabardastt")),
    ("ghatiya", ("ghatia", "gatiya", "ghtiya", "ghatya")),
    ("bekar", ("bekaar", "bikar", "baykar")),
    ("badtameez", ("badtamiz", "bdtameez", "badtmeez", "badtamez")),
    ("khaas", ("khas", "khass")),
    ("bilkul", ("bilqul", "bilkl", "bikul", "bilkull")),
    ("waqai", ("waqi", "wakai", "waqae", "wakayi")),
    ("pasand", ("psand", "pasnd", "pasandh")),
    ("umeed", ("umid", "umeid", "ummeed", "umeedd")),
    ("afsos", ("afsoos", "afsoz")),
    ("shukriya", ("shukria", "shukrya", "shukriyaa", "shokria")),
    ("mashallah", ("mashalla", "mashaallah", "masallah", "mashallh")),
    ("alhamdulillah", ("alhamdulilah", "alhamdolillah", "alhamdulillaah")),
    ("galat", ("ghalat", "galath")),
    ("jhoot", ("jhut", "jhooth")),
    ("beimani", ("baimani", "beymani", "bemani", "beimaani")),
    ("mushkil", ("mushkl", "muskil", "mushqil")),
    ("asan", ("aasan", "asaan", "aasaan")),
    ("sust", ("susth",)),
    ("guzara", ("gujara", "guzaara", "guzarah")),
    ("tajurba", ("tajarba", "tajruba", "tajurbah", "tajourba")),
    ("masla", ("maslah", "msla", "maslaa")),
    ("intezam", ("intizam", "intzam", "intezaam", "intazam")),
    ("intezar", ("intzar", "intizar", "intezaar", "intazar")),
    ("zaroor", ("zarur", "zarror", "zaror", "zaruur")),
    ("dobara", ("dubara", "dubbara", "dobarah", "dubarah")),
    ("jaldi", ("jldi", "jaldee", "jaldii")),
    ("phir", ("fir", "phr")),
    ("kya", ("kyaa", "kyya")),
    ("bhai", ("bahi", "bhaai", "bhaee")),
    ("sahi", ("sahee", "saahi", "sahii")),
    ("ziada", ("zyada", "zaida", "zada", "ziyada", "zyaada", "ziyaada")),
    ("chota", ("chhota", "chotta", "chhotta", "chhoti", "choti")),
    ("purana", ("purani", "porana", "puranaa", "puraana")),
    ("raat", ("raatt",)),
    ("ghanta", ("ghnta", "ganta", "ghantaa", "ghante", "ghanto")),
    ("saaf", ("saf", "saff")),
    ("safai", ("safaai", "safayi", "saphai")),
    ("sahulat", ("sahoolat", "suhulat", "sahulath")),
    # Venue / booking domain nouns
    ("ground", ("grownd", "graound", "gournd", "grond", "graund")),
    ("maidan", ("medan", "maidaan", "mydan")),
    ("turf", ("truf", "turff")),
    ("light", ("lights", "lighs", "laits", "lait", "ligths")),
    ("pani", ("paani", "panii", "paany")),
    ("washroom", ("washrum", "washrooms", "washroms")),
    ("parking", ("parkng", "paking", "parkin", "prking")),
    ("booking", ("bookng", "buking", "bookin", "bukking")),
    ("slot", ("slott",)),
    ("owner", ("onwer", "ownr", "owener")),
    ("staff", ("stff", "staf", "staaf")),
    ("service", ("servis", "sarvice", "serivce", "servise")),
    ("refund", ("refnd", "rifund", "refand")),
    ("cancel", ("cancal", "cansel", "kancel")),
    ("paisa", ("paisay", "paise", "paisey", "pesa", "pese", "paisaa")),
    ("wasool", ("wasul", "wusool", "wasol", "wasoll")),
    ("mehnga", ("mehanga", "menga", "mahnga", "mehngi", "mahanga", "mehnge")),
    ("sasta", ("sasti", "saste", "sastaa", "sasata")),
    ("time", ("taim", "tym", "tyme", "taime")),
    ("experience", ("experiance", "expirience", "experince", "expereince",
                    "experiense")),
    # English shorthand and common misspellings
    ("good", ("gud", "guud", "goodd")),
    ("bad", ("badd",)),
    ("best", ("bst", "bestt", "besst")),
    ("worst", ("wrst", "worest", "worstt")),
    ("nice", ("nicee", "nyc", "nise", "niice")),
    ("awesome", ("awsome", "awesom", "ausome", "awsom")),
    ("amazing", ("amazin", "amaizing", "amezing")),
    ("excellent", ("excelent", "excellant", "exellent")),
    ("terrible", ("terible", "terrable", "terribel")),
    ("horrible", ("horible", "horrable", "horibble")),
    ("disappointed", ("dissapointed", "disapointed", "dissappointed",
                      "disappoint", "dissapoint")),
    ("waste", ("wast", "waiste")),
    ("average", ("avarage", "averge", "avrage")),
    ("clean", ("clen", "klean", "cleen")),
    ("dirty", ("drty", "dirtty")),
    ("helpful", ("helpfull", "halpful")),
    ("rude", ("rud",)),
    ("full", ("ful",)),
    ("please", ("plz", "pls", "plzz", "pleaz", "plese", "pleez")),
    ("recommend", ("recomend", "recommand", "rekmend", "recomand", "recommnd")),
    ("thanks", ("thnx", "thanx", "thankz", "thnks")),
    ("sorry", ("sory", "sorryy", "sry")),
    ("so", ("soo",)),
    ("wow", ("woww",)),
    ("yes", ("yess", "yeah")),
    ("no", ("noo",)),
)

#: variant -> canonical.
VARIANTS: dict[str, str] = {
    variant: canonical
    for canonical, variants in _VARIANT_GROUPS
    for variant in variants
}

#: Tokens someone will eventually try to add to ``VARIANTS``, with the reason
#: they must not be. Kept as executable data (and asserted disjoint from
#: ``VARIANTS``) rather than prose, so the argument survives the next edit.
DELIBERATE_EXCLUSIONS: dict[str, str] = {
    "nai": "new / barber; a plausible 'nahi' spelling, but flipping polarity on "
           "a guess is worse than missing one negation",
    "bhi": "'also, too'. Folding it into 'bhai' (brother) would rewrite the "
           "most common particle in the corpus into a vocative",
    "km": "kilometre, and also an SMS form of 'kam' (less). Unresolvable, and "
          "below MIN_VARIANT_KEY_LEN anyway",
    "hy": "'hai' / 'hay' / 'high' all collide; two characters carry no evidence",
    "rat": "English rodent vs 'raat' (night)",
    "thick": "English adjective vs 'theek' (fine). Reviews contain both",
    "lite": "brand spelling and English 'lite' vs 'light'",
    "kiya": "'did' (verb) vs 'kya' (what). Different parts of speech",
    "masala": "spice mix vs 'masla' (problem)",
    "bara": "'big' vs 'bara' (a fried snack). Both appear near food stalls",
    "sast": "would collide with both 'sasta' (cheap) and 'sust' (slow)",
    "cant": "handled by contraction expansion, not the lexicon -- putting it "
            "here too would create two competing rewrite paths",
    "wont": "same as 'cant'",
}


# 6. Negation scope

#: Negators that scope left first, then fall back to the right if nothing was
#: markable on the left. Roman Urdu is verb-final: "acha nahi tha" is
#: good-not-was, so the negated word precedes the negator. The right-hand
#: fallback covers a sentence-initial "nahi" and the postpositional /
#: prepositional ambiguity of "bina": both "parking ke bina" and "bina parking"
#: occur, and the fallback resolves them without a second rule.
NEG_SCOPE_LEFT: frozenset[str] = frozenset({
    "nahi", "nahin", "nhi", "nahe", "nahii",
    "bina", "baghair", "bagair",
})

#: Negators that scope right only -- English word order, plus the Urdu
#: prohibitive particles "na" and "mat" which precede what they negate.
#: Known limitation: the clause-final tag-question "na" ("acha tha na") also
#: lands here. In practice it is clause-final, so the rightward walk immediately
#: hits a boundary and marks nothing. Pinned as a test case.
NEG_SCOPE_RIGHT: frozenset[str] = frozenset({
    "na", "mat",
    "not", "no", "never", "none", "nothing", "nobody",
    "without", "neither", "nor", "cannot",
})

#: Walked over for free: not marked, and not counted against ``NEG_WINDOW``.
#: Copulas, light verbs, case markers, quantifiers and intensifiers -- none of
#: them carry the polarity the negator is aimed at, and stopping on them would
#: make "maza nahi aya" and "acha nahi tha" unnegatable.
NEG_SKIP: frozenset[str] = frozenset({
    # Urdu copulas / auxiliaries / light verbs
    "hai", "hay", "hain", "tha", "thi", "thay", "the", "thin", "ho", "hua",
    "hui", "hue", "hota", "hoti", "raha", "rahi", "ati", "ata", "aya", "ayi",
    "gaya", "gayi", "kar", "karne", "karna", "kiya", "diya", "mila", "mili",
    # Urdu case markers / particles
    "ka", "ki", "ke", "ko", "se", "ne", "me", "mein", "par", "pe", "hi",
    "bhi", "to", "tou",
    # Quantifiers and intensifiers
    "koi", "kuch", "sab", "kabhi", "bohat", "bilkul", "ziada", "thora",
    "thori", "kafi", "itna", "itne", "zara",
    # English function words and intensifiers
    "very", "really", "so", "too", "quite", "at", "all", "a", "an", "is",
    "was", "were", "been", "be", "am", "get", "got",
})

#: Hard boundaries. Scope stops before these, and they are never marked.
#: Coordinators and subordinators start a new polarity clause -- "not bad for
#: the rate" must not spill ``_neg`` onto "rate".
NEG_STOP: frozenset[str] = frozenset({
    SEP_TOKEN, EXC_TOKEN, QM_TOKEN,
    # Urdu coordinators / subordinators
    "aur", "ya", "lekin", "magar", "phir", "kyunke", "kyunki", "agar", "jab",
    "warna", "balke",
    # English coordinators / subordinators / prepositions that end a scope
    "but", "or", "and", "though", "although", "however", "because", "while",
    "whereas", "yet", "for", "with", "from", "of", "by", "than", "if", "when",
})


# 7. Pipeline description

#: (name, description) in execution order. The names go into the fingerprint, so
#: reordering or renaming a step invalidates every existing artifact -- which is
#: the point: step order is as much of the contract as the tables are.
PIPELINE_STEPS: tuple[tuple[str, str], ...] = (
    ("nfkc", "Unicode NFKC compatibility normalisation"),
    ("strip_junk", "drop controls, zero-width, bidi, variation selectors, "
                   "skin-tone modifiers, keycap marks"),
    ("ascii_punct", "map curly quotes, dashes and exotic spaces to ASCII"),
    ("lower", "str.lower (locale-independent in Python 3)"),
    ("guard_placeholders", "strip < > _ from the input so placeholder and "
                           "negation tokens cannot be forged"),
    ("contractions", "expand dont/don't -> do not, won't -> will not, ..."),
    ("emoji", "map each emoji to <posemo>/<negemo>/<neuemo>, else <emo>"),
    ("url_email_mention", "-> <url>, <email>, <user>"),
    ("phone", "Pakistani mobile numbers -> <phone>"),
    ("money", "Rs/PKR amounts -> <money> (before <num>, or the digits win)"),
    ("num", "remaining numbers -> <num>"),
    ("punct_runs", "cap runs of ! ? . , at two"),
    ("intensity", "! -> <exc>, ? -> <qm>"),
    ("clause", ". , ; : ellipsis newline -> <sep>"),
    ("strip_punct", "all other non-word characters -> space (Urdu script "
                    "survives; _ removed)"),
    ("collapse_runs", "runs of 3+ of one character -> exactly 2"),
    ("variants", "whole-token spelling folding via VARIANTS"),
    ("collapse_ws", "collapse whitespace, strip ends"),
)


# 8. Normalisation


def _emoji_sub(match: re.Match[str]) -> str:
    char = match.group(0)
    return " " + EMOJI_POLARITY.get(char, EMOJI_TOKEN) + " "


def normalize_text(value: object) -> str:
    """Normalise one review into the token stream both branches are built from.

    Accepts anything (``None``, floats out of pandas, ints out of a mislabelled
    CSV column) and always returns a ``str``. A corpus row that is empty or
    numeric must not be able to raise from inside a training loop.

    Idempotent on placeholder-free output only -- see design note 1 in the
    module docstring. That is asserted by :func:`self_check`, not accidental.
    """
    if value is None:
        return ""
    text = value if isinstance(value, str) else str(value)

    # 1. nfkc
    text = unicodedata.normalize("NFKC", text)
    # 2. strip_junk
    text = _RE_JUNK.sub("", text)
    # 3. ascii_punct
    text = text.translate(_QUOTE_TABLE)
    # 4. lower
    text = text.lower()
    # 5. guard_placeholders -- must precede every placeholder insertion below
    if "<" in text or ">" in text or "_" in text:
        text = text.replace("<", " ").replace(">", " ").replace("_", " ")
    # 6. contractions
    if "n" in text or "'" in text:
        for pattern, replacement in _CONTRACTIONS:
            text = pattern.sub(replacement, text)
    # 7. emoji
    text = _RE_EMOJI.sub(_emoji_sub, text)
    # 8. url_email_mention (email before mention, or "@host.com" wins)
    text = _RE_URL.sub(" " + URL_TOKEN + " ", text)
    text = _RE_EMAIL.sub(" " + EMAIL_TOKEN + " ", text)
    text = _RE_MENTION.sub(" " + USER_TOKEN + " ", text)
    # 9. phone (before money/num: a phone number is also a run of digits)
    text = _RE_PHONE.sub(" " + PHONE_TOKEN + " ", text)
    # 10. money (before num, or "rs 3000" degrades to "rs <num>")
    text = _RE_MONEY.sub(" " + MONEY_TOKEN + " ", text)
    # 11. num
    text = _RE_NUM.sub(" " + NUM_TOKEN + " ", text)
    # 12. punct_runs
    text = _RE_PUNCT_RUN.sub(r"\1\1", text)
    # 13. intensity
    text = _RE_EXC.sub(" " + EXC_TOKEN + " ", text)
    text = _RE_QM.sub(" " + QM_TOKEN + " ", text)
    # 14. clause
    text = _RE_SEP.sub(" " + SEP_TOKEN + " ", text)
    # 15. strip_punct
    text = _RE_NON_TOKEN.sub(" ", text)
    text = text.replace("_", " ")  # \w includes _; it belongs to NEG_SUFFIX
    # 16. collapse_runs
    text = _RE_RUN.sub(r"\1\1", text)
    # 17. variants
    text = " ".join(VARIANTS.get(word, word) for word in text.split())
    # 18. collapse_ws
    return _RE_WS.sub(" ", text).strip()


def normalize_many(values: Iterable[object]) -> list[str]:
    """Batch wrapper. Identical to a list comprehension over
    :func:`normalize_text`; exists so callers do not each write their own."""
    return [normalize_text(value) for value in values]


def tokenize(text: str) -> list[str]:
    """Split already-normalised text. Whitespace only -- see
    :data:`WORD_TOKEN_PATTERN` for why the vectoriser must not do more."""
    return text.split()


# 9. Negation marking


def _scope(tokens: Sequence[str], out: list[str], index: int, step: int) -> int:
    """Mark up to ``NEG_WINDOW`` content tokens starting at ``index + step``.

    Reads polarity words from ``tokens`` and writes into ``out``, so two
    negators aiming at the same word produce the same result regardless of
    order. An already-suffixed token is rewritten, not double-suffixed, which is
    what makes :func:`mark_negation` idempotent.
    """
    marked = 0
    walked = 0
    total = len(tokens)
    position = index + step
    while 0 <= position < total and marked < NEG_WINDOW and walked < NEG_MAX_WALK:
        walked += 1
        token = tokens[position]
        if (
            token in NEG_STOP
            or token in NEG_SCOPE_LEFT
            or token in NEG_SCOPE_RIGHT
        ):
            break
        if token in NEG_SKIP or token.startswith("<"):
            # Placeholders carry no polarity, so negating them is noise.
            position += step
            continue
        base = token[: -len(NEG_SUFFIX)] if token.endswith(NEG_SUFFIX) else token
        out[position] = base + NEG_SUFFIX
        marked += 1
        position += step
    return marked


def mark_negation(tokens: Sequence[str]) -> list[str]:
    """Suffix ``_neg`` onto tokens that fall inside a negator's scope.

    Direction-aware; see design note 3. Worked examples, all pinned in
    :func:`self_check`::

        acha nahi tha bilkul  ->  acha_neg nahi tha bilkul
        koi masla nahi hua    ->  koi masla_neg nahi hua     (negated negative)
        na acha na bura       ->  na acha_neg na bura_neg    (neither / nor)
        not very good         ->  not very good_neg          (skips 'very')
        not bad for the rate  ->  not bad_neg for the rate   ('for' stops it)
        dobara kabhi nahi     ->  dobara_neg kabhi nahi
        parking ke bina       ->  parking_neg ke bina        (left)
        bina parking          ->  bina parking_neg           (right fallback)
    """
    out = list(tokens)
    for index, token in enumerate(tokens):
        if token in NEG_SCOPE_LEFT:
            marked = _scope(tokens, out, index, -1) if index > 0 else 0
            if marked == 0:
                _scope(tokens, out, index, 1)
        elif token in NEG_SCOPE_RIGHT:
            _scope(tokens, out, index, 1)
    return out


# 10. Pipeline entry points
#
# These two must stay module-level functions. ``FunctionTransformer`` pickles its
# callable by reference, so a lambda or a closure makes the artifact unloadable
# and a bound method makes it depend on an instance that is not in the payload.
#
# They also take and return plain lists of strings, which is what keeps the whole
# classifier a single ``Pipeline`` accepting raw text: ``model.predict(["..."])``
# works at serve time with no preprocessing on the caller's side.


def prep_word(texts: Iterable[object]) -> list[str]:
    """Word branch: normalise, then mark negation scope."""
    return [
        " ".join(mark_negation(tokenize(normalize_text(text)))) for text in texts
    ]


def prep_char(texts: Iterable[object]) -> list[str]:
    """Character branch: normalise only.

    No ``_neg`` markers here on purpose -- see design note 4.
    """
    return [normalize_text(text) for text in texts]


def has_urdu_script(text: object) -> bool:
    """True if the text contains Arabic-block characters.

    The corpus is Roman Urdu and English. Urdu script survives normalisation
    (design note 5) but is out of distribution, so serving uses this to
    downgrade confidence rather than pretending the prediction is calibrated.
    """
    if text is None:
        return False
    return bool(_RE_URDU.search(text if isinstance(text, str) else str(text)))


# 11. Contract identity helpers


def norm_spec_fingerprint() -> str:
    """sha256 (16 hex chars) over every table, constant and regex above.

    ``features.py`` gets away with a bare version string because its derivations
    are a short list a reviewer reads in full. This module carries ~200 lexicon
    entries, ~60 emoji, four negator sets and a dozen regexes: exactly the shape
    of table that gets extended without a version bump. Hashing the contents
    turns "someone edited the lexicon and forgot" from unexplained accuracy
    drift into a load-time ``incompatible`` status.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", NORM_SPEC_VERSION)
    feed("labels", "|".join(LABELS))
    feed("steps", "|".join(name for name, _ in PIPELINE_STEPS))
    feed("max_run", MAX_RUN)
    feed("min_variant_key_len", MIN_VARIANT_KEY_LEN)
    feed("neg_window", NEG_WINDOW)
    feed("neg_max_walk", NEG_MAX_WALK)
    feed("neg_suffix", NEG_SUFFIX)
    feed("word_token_pattern", WORD_TOKEN_PATTERN)
    feed("placeholders", "|".join(PLACEHOLDERS))
    for key in sorted(VARIANTS):
        feed("variant", f"{key}>{VARIANTS[key]}")
    for key in sorted(EMOJI_POLARITY):
        feed("emoji", f"{ord(key):x}>{EMOJI_POLARITY[key]}")
    for key in sorted(DELIBERATE_EXCLUSIONS):
        feed("excluded", key)
    feed("neg_left", "|".join(sorted(NEG_SCOPE_LEFT)))
    feed("neg_right", "|".join(sorted(NEG_SCOPE_RIGHT)))
    feed("neg_skip", "|".join(sorted(NEG_SKIP)))
    feed("neg_stop", "|".join(sorted(NEG_STOP)))
    for name, pattern in (
        ("junk", _RE_JUNK),
        ("url", _RE_URL),
        ("email", _RE_EMAIL),
        ("mention", _RE_MENTION),
        ("phone", _RE_PHONE),
        ("money", _RE_MONEY),
        ("num", _RE_NUM),
        ("punct_run", _RE_PUNCT_RUN),
        ("sep", _RE_SEP),
        ("non_token", _RE_NON_TOKEN),
        ("run", _RE_RUN),
        ("emoji_range", _RE_EMOJI),
        ("urdu", _RE_URDU),
    ):
        feed(f"re:{name}", pattern.pattern)
    for pattern, replacement in _CONTRACTIONS:
        feed("contraction", f"{pattern.pattern}>{replacement}")
    for key in sorted(_QUOTE_MAP):
        feed("quote", f"{ord(key):x}>{_QUOTE_MAP[key]!r}")
    return digest.hexdigest()[:16]


def describe_pipeline() -> list[str]:
    """Numbered, human-readable pipeline for the model card and the CLI."""
    return [
        f"{position:2d}. {name:<20s} {description}"
        for position, (name, description) in enumerate(PIPELINE_STEPS, start=1)
    ]


def spec() -> dict[str, object]:
    """camelCase contract summary for the joblib payload, ``/health`` and the
    metrics JSON. Mirrors ``features.spec()``."""
    return {
        "normSpecVersion": NORM_SPEC_VERSION,
        "normSpecFingerprint": norm_spec_fingerprint(),
        "labels": list(LABELS),
        "steps": [name for name, _ in PIPELINE_STEPS],
        "wordTokenPattern": WORD_TOKEN_PATTERN,
        "maxRun": MAX_RUN,
        "negWindow": NEG_WINDOW,
        "negMaxWalk": NEG_MAX_WALK,
        "negSuffix": NEG_SUFFIX,
        "placeholders": list(PLACEHOLDERS),
        "variantCount": len(VARIANTS),
        "canonicalCount": len(_VARIANT_GROUPS),
        "emojiCount": len(EMOJI_POLARITY),
        "excludedCount": len(DELIBERATE_EXCLUSIONS),
        "negatorCount": len(NEG_SCOPE_LEFT) + len(NEG_SCOPE_RIGHT),
    }


# 12. Self-check

#: Placeholder-free samples used for the idempotency proof. Drawn from the shape
#: of real corpus rows, including the two exam sentences the first model got
#: wrong.
_IDEMPOTENT_SAMPLES: tuple[str, ...] = (
    "bohatttt acha ground tha",
    "staff badtameez hai baat karne ka tareeqa hi nahi",
    "bas guzara ho gaya na acha na bura",
    "behtreen turf hai football khelne ka maza dobala ho gaya",
    "average lights aur average service",
    "not bad for the rate honestly",
)

#: (input, expected :func:`normalize_text` output).
_NORMALIZE_CASES: tuple[tuple[str, str], ...] = (
    # The exact bug in the first implementation of this module: the placeholder
    # was inserted in upper case and then destroyed by the punctuation pass one
    # line later, so every URL silently vanished from the corpus.
    ("check https://x.com now", "check <url> now"),
    ("mail me at a.b@c.com", "mail me at <email>"),
    # guard_placeholders strips the '_' before the mention regex runs, so the
    # handle splits and a benign "pk" token is left behind. That is correct and
    # non-destructive -- far better than a greedy regex that eats real content.
    ("thanks @sportlynk_pk", "thanks <user> pk"),
    ("call 03001234567 for slot", "call <phone> for slot"),
    ("Rs. 3000 mehnga hai", "<money> mehnga hai"),
    ("3000 le liye ek ghante ka", "<num> le liye ek ghanta ka"),
    ("bohatttt bura tajurba", "bohat bura tajurba"),
    # 3+ -> 2, never 3+ -> 1: this must not become "god ground".
    ("gooood ground", "good ground"),
    ("bura!!! acha??", "bura <exc> <exc> acha <qm> <qm>"),
    ("theek tha, phir gaye", "theek tha <sep> phir gaye"),
    ("dont go there", "do not go there"),
    ("wasn't good", "was not good"),
    # Curly apostrophe: what a phone keyboard inserts.
    ("didn’t like it", "did not like it"),
    # 'well' must survive: an optional apostrophe on 'll would make this
    # "we will maintained".
    ("well maintained ground", "well maintained ground"),
    # Forgery guard: a reviewer cannot type a feature the model trusts.
    ("<num> <exc>", "num exc"),
    ("acha_neg tha", "acha neg tha"),
    ("", ""),
)

#: (input, expected :func:`prep_word` output). The negation contract.
_NEGATION_CASES: tuple[tuple[str, str], ...] = (
    ("acha nahi tha bilkul", "acha_neg nahi tha bilkul"),
    ("koi masla nahi hua", "koi masla_neg nahi hua"),
    ("na acha na bura", "na acha_neg na bura_neg"),
    ("not very good", "not very good_neg"),
    ("not bad for the rate", "not bad_neg for the rate"),
    ("dobara kabhi nahi", "dobara_neg kabhi nahi"),
    ("maza nahi aya", "maza_neg nahi aya"),
    ("parking hi nahi hai", "parking_neg hi nahi hai"),
    ("parking ke bina", "parking_neg ke bina"),
    ("bina parking", "bina parking_neg"),
    # Clause-final tag-question 'na': the rightward walk hits the end and marks
    # nothing, which is the correct reading.
    ("acha tha na", "acha tha na"),
)


def self_check() -> list[tuple[str, str]]:
    """Prove every structural property this module's callers rely on.

    Raises ``AssertionError`` with a specific message on the first violation. A
    broken contract must not be recoverable: training records the outcome as a
    release gate and refuses to write ``models/sentiment_latest.joblib``.

    Returns a list of ``(check, detail)`` receipts, so a passing run is also an
    audit trail -- the same reason ``train_pricing.py`` records checks that
    raise as unconditional-True gates.
    """
    receipts: list[tuple[str, str]] = []

    # Labels
    assert LABELS == tuple(sorted(LABELS)), (
        f"LABELS must be alphabetical so it matches sklearn's own class "
        f"ordering; got {LABELS}"
    )
    assert set(LABELS) == {"negative", "neutral", "positive"}, (
        f"LABELS must match the CHECK constraint in migration 013; got {LABELS}"
    )
    receipts.append((
        "labels", f"{len(LABELS)} labels, alphabetical: {', '.join(LABELS)}"
    ))

    # Placeholders
    assert len(set(PLACEHOLDERS)) == len(PLACEHOLDERS), "duplicate placeholder"
    for placeholder in PLACEHOLDERS:
        assert placeholder.startswith("<") and placeholder.endswith(">"), (
            f"placeholder {placeholder!r} must be angle-bracketed"
        )
        assert "_" not in placeholder, (
            f"placeholder {placeholder!r} contains '_', which the punctuation "
            f"pass strips -- it would be split into two tokens"
        )
        assert placeholder.strip("<>").isalnum(), (
            f"placeholder {placeholder!r} body must be alphanumeric"
        )
    receipts.append((
        "placeholders",
        f"{len(PLACEHOLDERS)} tokens, all angle-bracketed and "
        f"underscore-free",
    ))

    # Variant table structure
    declared = sum(len(variants) for _, variants in _VARIANT_GROUPS)
    assert declared == len(VARIANTS), (
        f"{declared - len(VARIANTS)} variant(s) are listed under more than one "
        f"canonical form"
    )
    canonicals = {canonical for canonical, _ in _VARIANT_GROUPS}
    assert len(canonicals) == len(_VARIANT_GROUPS), (
        "the same canonical form appears in two groups; merge them"
    )
    for key, value in VARIANTS.items():
        assert key == key.lower(), f"variant key {key!r} is not lowercase"
        assert " " not in key, (
            f"variant key {key!r} contains a space; folding is whole-token only"
        )
        assert len(key) >= MIN_VARIANT_KEY_LEN, (
            f"variant key {key!r} is shorter than MIN_VARIANT_KEY_LEN="
            f"{MIN_VARIANT_KEY_LEN}; short Roman Urdu tokens are ambiguous"
        )
        assert key != value, f"variant key {key!r} maps to itself (a no-op)"
        collapsed = _RE_RUN.sub(r"\1\1", key)
        assert collapsed == key, (
            f"variant key {key!r} is not collapse-stable: run collapsing turns "
            f"it into {collapsed!r} before the lexicon is consulted, so this "
            f"entry can never match"
        )
        assert key not in canonicals, (
            f"variant key {key!r} is also a canonical form; that is a key->key "
            f"chain and folding order would decide the result"
        )
        assert value not in VARIANTS, (
            f"canonical {value!r} is itself a variant key; that is a key->key "
            f"chain"
        )
        assert normalize_text(value) == value, (
            f"canonical {value!r} does not survive its own normaliser (got "
            f"{normalize_text(value)!r}); folding would never settle"
        )
    receipts.append((
        "variants",
        f"{len(VARIANTS)} variants over {len(_VARIANT_GROUPS)} canonical forms; "
        f"all collapse-stable, chain-free and idempotent",
    ))

    # Deliberate exclusions
    overlap = set(DELIBERATE_EXCLUSIONS) & set(VARIANTS)
    assert not overlap, (
        f"{sorted(overlap)} are documented as deliberately excluded but are "
        f"also VARIANTS keys; one of the two is a mistake"
    )
    for key, reason in DELIBERATE_EXCLUSIONS.items():
        assert reason.strip(), f"exclusion {key!r} has no stated reason"
    receipts.append((
        "exclusions",
        f"{len(DELIBERATE_EXCLUSIONS)} documented refusals, disjoint from "
        f"VARIANTS, each with a reason",
    ))

    # Emoji table
    seen: dict[str, str] = {}
    for chars, token in _EMOJI_GROUPS:
        for char in chars:
            assert char not in seen, (
                f"emoji U+{ord(char):04X} is assigned both {seen[char]} and "
                f"{token}"
            )
            seen[char] = token
            assert _RE_EMOJI.fullmatch(char), (
                f"emoji U+{ord(char):04X} is in the polarity table but outside "
                f"_RE_EMOJI, so it can never be substituted"
            )
    receipts.append((
        "emoji",
        f"{len(EMOJI_POLARITY)} emoji assigned a polarity, all inside the "
        f"recognised ranges, none assigned twice",
    ))

    # Negator sets
    both = NEG_SCOPE_LEFT & NEG_SCOPE_RIGHT
    assert not both, f"{sorted(both)} appear in both negator direction sets"
    negators = NEG_SCOPE_LEFT | NEG_SCOPE_RIGHT
    clash = negators & (NEG_SKIP | NEG_STOP)
    assert not clash, (
        f"{sorted(clash)} are negators and also skip/stop tokens; scope would "
        f"depend on which branch happens to be tested first"
    )
    clash = NEG_SKIP & NEG_STOP
    assert not clash, f"{sorted(clash)} are both skipped and a hard boundary"
    for negator in negators:
        normalised = normalize_text(negator)
        assert normalised in negators, (
            f"negator {negator!r} normalises to {normalised!r}, which is not a "
            f"negator -- the marker would never fire on real input"
        )
    for token in NEG_STOP:
        if token.startswith("<"):
            assert token in PLACEHOLDERS, (
                f"NEG_STOP contains {token!r}, which is not a placeholder this "
                f"module emits"
            )
    receipts.append((
        "negators",
        f"{len(NEG_SCOPE_LEFT)} left-first + {len(NEG_SCOPE_RIGHT)} "
        f"right-only, {len(NEG_SKIP)} skipped, {len(NEG_STOP)} boundaries; all "
        f"sets disjoint and normaliser-stable",
    ))

    # Normalisation cases
    for raw, expected in _NORMALIZE_CASES:
        actual = normalize_text(raw)
        assert actual == expected, (
            f"normalize_text({raw!r}) == {actual!r}, expected {expected!r}"
        )
    for value in (None, 0, 3.5, True):
        assert isinstance(normalize_text(value), str), (
            f"normalize_text({value!r}) did not return a str"
        )
    receipts.append((
        "normalize cases",
        f"{len(_NORMALIZE_CASES)} pinned rewrites pass; None/int/float input "
        f"returns str",
    ))

    # Forgery guard
    for placeholder in PLACEHOLDERS:
        forged = normalize_text(f"ground {placeholder} tha")
        assert placeholder not in forged.split(), (
            f"a reviewer typing {placeholder!r} produced it as a real token "
            f"({forged!r}); the input guard is broken"
        )
    assert "_" not in normalize_text("acha_neg bura__ nice"), (
        "normalize_text emitted an underscore, so NEG_SUFFIX is forgeable"
    )
    receipts.append((
        "forgery guard",
        f"none of the {len(PLACEHOLDERS)} placeholders can be typed by a "
        f"reviewer; no '_' survives normalisation",
    ))

    # Idempotency, and its documented exception
    for sample in _IDEMPOTENT_SAMPLES:
        once = normalize_text(sample)
        assert "<" not in once, (
            f"idempotency sample {sample!r} produced a placeholder; move it out "
            f"of _IDEMPOTENT_SAMPLES"
        )
        assert normalize_text(once) == once, (
            f"normalize_text is not idempotent on {sample!r}: {once!r} -> "
            f"{normalize_text(once)!r}"
        )
    assert normalize_text(normalize_text("rs 3000")) == "money", (
        "the documented non-idempotency on placeholder-bearing text changed; "
        "either the input guard or the module docstring is now wrong"
    )
    receipts.append((
        "idempotency",
        f"stable on {len(_IDEMPOTENT_SAMPLES)} placeholder-free samples; "
        f"placeholder degradation on re-entry is pinned",
    ))

    # Negation cases
    for raw, expected in _NEGATION_CASES:
        actual = prep_word([raw])[0]
        assert actual == expected, (
            f"prep_word([{raw!r}])[0] == {actual!r}, expected {expected!r}"
        )
    assert NEG_SUFFIX not in prep_char(["acha nahi tha"])[0], (
        "prep_char emitted a negation marker; the char branch must see plain "
        "text (design note 4)"
    )
    once = mark_negation(tokenize(normalize_text("acha nahi tha bilkul")))
    assert mark_negation(once) == once, (
        f"mark_negation is not idempotent: {once} -> {mark_negation(once)}"
    )
    receipts.append((
        "negation",
        f"{len(_NEGATION_CASES)} pinned scope decisions pass in both "
        f"directions; idempotent; char branch stays unmarked",
    ))

    # Script handling
    urdu = "اچھا"  # "acha", in Urdu script
    assert has_urdu_script(urdu), "has_urdu_script missed Arabic-block text"
    assert not has_urdu_script("acha"), "has_urdu_script fired on Roman text"
    assert urdu in normalize_text(f"ground {urdu} tha"), (
        "Urdu script did not survive normalisation, so serving could no longer "
        "detect out-of-distribution input"
    )
    receipts.append((
        "urdu script",
        "Arabic-block text is detected and preserved; Roman text is not "
        "misdetected",
    ))

    # Fingerprint
    fingerprint = norm_spec_fingerprint()
    assert len(fingerprint) == 16 and all(
        char in "0123456789abcdef" for char in fingerprint
    ), f"fingerprint {fingerprint!r} is not 16 lowercase hex characters"
    assert norm_spec_fingerprint() == fingerprint, "fingerprint is not stable"
    receipts.append((
        "fingerprint",
        f"{NORM_SPEC_VERSION} / {fingerprint} (stable across calls)",
    ))

    return receipts


# 13. CLI
#
# ASCII output only. A long training run that prints its summary through a
# cp1252 console dies at the last line, which is the most expensive possible
# place to discover an encoding problem.


def _main(argv: Sequence[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m app.core.text_norm",
        description="Inspect and verify the sentiment normalisation contract.",
    )
    parser.add_argument(
        "--self-check", action="store_true",
        help="prove every structural property; exit 1 on any violation",
    )
    parser.add_argument(
        "--text", metavar="STR",
        help="show the full normalisation of one review",
    )
    parser.add_argument(
        "--spec", action="store_true",
        help="print the contract summary and the pipeline steps",
    )
    args = parser.parse_args(argv)

    if not (args.self_check or args.text or args.spec):
        parser.print_help()
        return 2

    if args.spec:
        print(f"norm spec       : {NORM_SPEC_VERSION}")
        print(f"fingerprint     : {norm_spec_fingerprint()}")
        for key, value in spec().items():
            if key in ("normSpecVersion", "normSpecFingerprint"):
                continue
            if isinstance(value, list):
                value = f"{len(value)}: {', '.join(map(str, value))}"
            print(f"  {key:<20s} {value}")
        print()
        print("pipeline:")
        for line in describe_pipeline():
            print(f"  {line}")
        print()

    if args.text:
        raw = args.text
        normalised = normalize_text(raw)
        print(f"raw        : {raw!r}")
        print(f"normalised : {normalised!r}")
        print(f"word branch: {prep_word([raw])[0]!r}")
        print(f"char branch: {prep_char([raw])[0]!r}")
        print(f"tokens     : {len(tokenize(normalised))}")
        print(f"urdu script: {has_urdu_script(raw)}")
        print()

    if args.self_check:
        try:
            receipts = self_check()
        except AssertionError as error:
            print("FAIL  text_norm self-check")
            print(f"      {error}")
            return 1
        width = max(len(name) for name, _ in receipts)
        for name, detail in receipts:
            print(f"ok    {name:<{width}s}  {detail}")
        print()
        print(
            f"PASS  {len(receipts)} checks, {NORM_SPEC_VERSION} / "
            f"{norm_spec_fingerprint()}"
        )
    return 0


__all__: Sequence[str] = (
    "NORM_SPEC_VERSION",
    "LABELS",
    "MAX_RUN",
    "MIN_VARIANT_KEY_LEN",
    "NEG_WINDOW",
    "NEG_MAX_WALK",
    "NEG_SUFFIX",
    "WORD_TOKEN_PATTERN",
    "PLACEHOLDERS",
    "PIPELINE_STEPS",
    "VARIANTS",
    "DELIBERATE_EXCLUSIONS",
    "EMOJI_POLARITY",
    "NEG_SCOPE_LEFT",
    "NEG_SCOPE_RIGHT",
    "NEG_SKIP",
    "NEG_STOP",
    "URL_TOKEN",
    "EMAIL_TOKEN",
    "USER_TOKEN",
    "PHONE_TOKEN",
    "MONEY_TOKEN",
    "NUM_TOKEN",
    "SEP_TOKEN",
    "EXC_TOKEN",
    "QM_TOKEN",
    "POS_EMOJI_TOKEN",
    "NEG_EMOJI_TOKEN",
    "NEU_EMOJI_TOKEN",
    "EMOJI_TOKEN",
    "normalize_text",
    "normalize_many",
    "tokenize",
    "mark_negation",
    "prep_word",
    "prep_char",
    "has_urdu_script",
    "norm_spec_fingerprint",
    "describe_pipeline",
    "spec",
    "self_check",
)


if __name__ == "__main__":
    raise SystemExit(_main())
