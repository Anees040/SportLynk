"""Assistant NLU HTTP contract — the front half of model #4 (S.6 / Wave B).

WHAT THIS ENDPOINT IS, AND WHAT IT DELIBERATELY IS NOT
`POST /nlu/parse` reads one utterance and answers WHAT the user wants (a trained
intent + a calibrated confidence) and WITH WHAT (the five rule-extracted slots).
That is all it does. It does not look up a venue, hold a slot, read a wallet, or
remember the previous turn — this process has no database and no session store,
by design (see main.py's trust boundary), and the Node dialog manager owns every
business rule (FR8.15). The consequence is the property that makes shipping a
0.62-exam-accuracy classifier defensible: a misread intent costs a wrong MENU,
never a wrong booking.

    Flutter chat ──▶ Node  POST /api/assistant/message {text, session_id}
                      │      (dialog state, JWT user, action execution)
                      └──▶ ML   POST /nlu/parse {text}
                             {intent, confidence, entities}

WHY THE ABSTAIN FLOOR LIVES IN THE ARTIFACT AND IS APPLIED HERE
The classifier's serving rule is `confidence < threshold -> out_of_scope`, and
the threshold is READ FROM THE JOBLIB (`artifact["confidenceThreshold"]`, 0.45 as
trained), never hard-coded in this file. S.4 taught that lesson expensively: the
sentiment router carried its own 0.90 strong-negative constant, the trainer's C
changed, the model's margins narrowed, and the rule silently stopped firing. A
number that describes ONE model's score distribution has to travel with that
model. `DEFAULT_THRESHOLD` below exists only for an artifact that carries none.

Abstention here is not an error and not an empty answer. `intent` becomes
`out_of_scope` — a REAL trained label with 112 corpus rows behind it — while
`topIntent` / `topConfidence` keep what the model actually thought, and
`alternatives` carries the top three. Node needs all of it: `abstained` decides
whether to show the fallback menu, and `alternatives` is what lets that menu
offer the two or three things the user most likely meant instead of a generic
"I didn't understand". Nothing on this response is user-facing COPY: the wording
of the menu is Node's and Flutter's, because the same JSON has to serve an
English UI, a Roman Urdu one, and a screen reader.

THE THREE WAYS AN UTTERANCE GETS NO ANSWER, AND WHY THEY ARE NAMED SEPARATELY
`abstainReason` is `low_confidence` when the model had an opinion below the
floor; `no_evidence` when the utterance contains nothing to classify (an emoji,
"???", a bare number — after nlu_text.prep it is only placeholders); and
`no_known_terms` when it has real tokens but not one of them was ever seen in
training. The last two never reach the estimator: predicting on "<qm>" wastes the
call and returns a confident-looking answer derived from punctuation, and a
keyboard-mash scores 0.528 for `greeting` — ABOVE the 0.45 floor — because
`char_wb` n-grams fire on any string at all. The floor cannot catch that case by
construction, so it is caught by construction instead (see `_known_unigrams`, and
`sentiment._scoreable` for the same guard one model over).

Node distinguishes them because its reply differs: `low_confidence` offers
`alternatives` as a did-you-mean menu, `no_evidence` re-asks the slot question
that was pending, `no_known_terms` says it did not understand. All three still
carry `entities`.

WHAT IS NOT LOGGED
Never the utterance. Intent, confidence, character length and the opaque
`sessionId` — nothing else. An assistant transcript is more sensitive than a
review body, and `routers/sentiment.py` already established that the text of a
user's writing does not go into this service's logs.

LATENCY
The wave's budget is 50 ms per parse. Both halves are cheap once warm (two TF-IDF
transforms plus 15 sigmoid evaluations; regex over <=500 characters), but the
COLD costs are brutal and neither is this endpoint's fault: joblib load is
~300 ms and dateparser's first parse was measured at 8.3 SECONDS. `warm()` pays
both at boot. Every response carries its own `elapsedMs`, and a parse over budget
logs a warning naming which half was slow — a p99 regression should show up in
the log of the service that caused it, not in a Flutter bug report.

ENDPOINTS
    POST /nlu/parse    one utterance -> {intent, confidence, entities, ...}
    GET  /nlu/spec     the label catalog, the entity contract, the fingerprints
    POST /nlu/refresh  drop the cached artifact after a retrain (mirrors
                       /reco/refresh, including its deliberate failure mode)
"""
from __future__ import annotations

import logging
import time
from datetime import datetime
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

from ..core import entities, intent_spec, nlu_text
from ..core.registry import STATUS_READY, registry

log = logging.getLogger("sportlynk.ml.nlu")

router = APIRouter(tags=["assistant"])

#: Registry key for model #4's classifier half. `models/intent_latest.joblib`.
MODEL_KEY = "intent"

#: Longest utterance this endpoint will classify. The corpus caps rows at
#: `intent_spec.MAX_TEXT_CHARS` (160) because a generated row that long is a bad
#: row, but real users paste, ramble and dictate, and 160 would 422 a genuine
#: message. 500 is the point past which the text is a paragraph rather than an
#: utterance, and a paragraph needs a different product (see the escalation loop
#: in progress.md), not a longer vectoriser.
MAX_TEXT_CHARS = 500

#: Used only when the served artifact carries no `confidenceThreshold`. Set to the
#: trained value, and bounded below, because the failure it guards is silent: a
#: threshold of 0 turns every guess into a confident answer, and 0.99 makes the
#: assistant answer nothing at all. See the module docstring on why this is a
#: fallback rather than the source of truth.
DEFAULT_THRESHOLD = 0.45
MIN_THRESHOLD = 0.05
MAX_THRESHOLD = 0.95

#: How many scored intents the response carries. Three, because that is what a
#: fallback menu can show without becoming a list to read: "did you mean A, B or
#: C". More would ship the whole 15-way distribution to a phone for nothing.
ALTERNATIVES = 3

#: Per-request budget from the wave spec. Exceeding it is logged, never an error:
#: a slow correct answer is still the right answer, and turning latency into a 500
#: would take the assistant down over a garbage-collection pause.
LATENCY_BUDGET_MS = 50.0

#: The label an abstention becomes. Read from the artifact when it declares one
#: (`fallbackIntent`), so the trainer and the router cannot disagree about it.
FALLBACK_INTENT = "out_of_scope"

#: `abstainReason` values. Stable identifiers — Node branches on them and the
#: dialog manager's tests assert on them.
REASON_LOW_CONFIDENCE = "low_confidence"
REASON_NO_EVIDENCE = "no_evidence"
REASON_NO_KNOWN_TERMS = "no_known_terms"


class CamelModel(BaseModel):
    """camelCase on the wire, snake_case in Python — as in `routers/sentiment.py`.

    `protected_namespaces` cleared for the same reason it is there: `model_version`
    is a field we publish deliberately and pydantic would otherwise warn about it
    at import time, i.e. into the boot log.
    """

    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="forbid",
        str_strip_whitespace=True,
        protected_namespaces=(),
    )


# Requests


class ParseRequest(CamelModel):
    """One utterance, raw.

    RAW is the contract. The frozen normaliser (`nlu_text.prep`) is baked into the
    pipeline as a FunctionTransformer, so Node must NOT pre-clean the text: doing
    so would apply a second, different normalisation and reintroduce exactly the
    train/serve skew the artifact was shaped to make impossible.
    """

    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARS,
                      description="the user's message, exactly as typed")
    session_id: str | None = Field(
        default=None, max_length=64,
        description="opaque conversation id, logged for correlation and nothing else; "
                    "this service holds no session state",
    )
    now: datetime | None = Field(
        default=None,
        description="reference instant for relative dates ('kal', 'is weekend'). "
                    "Omit in production. Does NOT change the timezone — resolution "
                    "is always Asia/Karachi; a naive value is read AS Karachi local. "
                    "Exists so a demo, a replay or a test can pin 'tomorrow'.",
    )


# The three contract identifiers every parse publishes, bound here rather than
# read inside `ParseResponse`. A pydantic class body is executed top to bottom in
# its own namespace, so the response model's `entities` field shadows the
# `entities` module for every line after it — `entities.ENTITY_SPEC_VERSION` two
# lines down resolves against a FieldInfo and raises at import time.
INTENT_SPEC_VERSION = intent_spec.INTENT_SPEC_VERSION
ENTITY_SPEC_VERSION = entities.ENTITY_SPEC_VERSION
NLU_TEXT_SPEC_VERSION = nlu_text.NLU_TEXT_SPEC_VERSION


# Responses


class ScoredIntent(CamelModel):
    """One candidate label with its calibrated probability and coarse group."""

    intent: str
    confidence: float = Field(ge=0.0, le=1.0)
    group: str


class ParseResponse(CamelModel):
    """`{intent, confidence, entities}` as the wave specifies, plus what the
    dialog manager needs to act on it.

    The first three fields are the contract; everything after them exists for a
    named consumer:

    * `abstained` / `abstainReason` — whether Node shows the fallback menu, and
      which of the three silences it was (see the module docstring).
    * `topIntent` / `topConfidence` — what the model believed BEFORE the floor was
      applied. Without these an abstention is unauditable: "it said out_of_scope"
      and "it thought book_venue at 0.41" call for different fixes.
    * `alternatives` — the menu's content, best first.
    * `threshold` / `modelVersion` / spec fields — provenance. The version and the
      contract fingerprints travel with the DATA, not just on /health, so a logged
      or stored turn can be traced to the exact artifact that produced it. Wave A's
      recommender and Wave B's ranker publish theirs for the same reason.
    """

    intent: str
    confidence: float = Field(ge=0.0, le=1.0)
    entities: dict[str, Any] = Field(
        description="all five slots, always present; each is null or a dict "
                    "(date/time/sport/area/budget)",
    )

    abstained: bool = False
    abstain_reason: str | None = None
    top_intent: str
    top_confidence: float = Field(ge=0.0, le=1.0)
    intent_group: str
    alternatives: list[ScoredIntent] = Field(default_factory=list)

    threshold: float
    source: str = "model"
    model_version: str | None = None
    intent_spec_version: str = INTENT_SPEC_VERSION
    entity_spec_version: str = ENTITY_SPEC_VERSION
    nlu_text_spec_version: str = NLU_TEXT_SPEC_VERSION
    elapsed_ms: float = Field(description="server-side wall clock for this parse")
    intent_ms: float
    entity_ms: float


# Helpers


def _require_model() -> Any:
    """The loaded intent estimator, or a 503 that says what is wrong and how to fix it.

    Forwards the registry's own diagnosis rather than flattening it: never trained,
    trained against a different label/normaliser contract, or a corrupt file are
    three different jobs (train it / retrain it / investigate it). Node's circuit
    breaker turns any of them into the same user-visible fallback menu, so the
    detail exists for whoever is fixing it, not for the phone.
    """
    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "model_not_loaded",
                "message": (
                    f"intent model unavailable ({entry.status}): "
                    f"{entry.reason or 'no reason recorded'}"
                ),
                "modelStatus": entry.status,
            },
        )
    return entry


def _labels(entry: Any) -> list[str]:
    """`estimator.classes_`, checked against `intent_spec.INTENTS`.

    Never assumes a column order. sklearn sorts string classes alphabetically and
    the argmax below reads `classes_` positionally, so an artifact trained on a
    different label SET (a 16th intent added, one renamed) would otherwise assign
    every probability to the wrong name with nothing raising. That is a 503 and not
    a 500: the request was fine, the artifact disagrees with the service — the same
    class of fault the registry's load contract refuses.
    """
    classes = [str(c) for c in getattr(entry.estimator, "classes_", [])]
    if sorted(classes) != sorted(intent_spec.INTENTS):
        log.error("artifact %s exposes labels %s", entry.version, classes)
        raise HTTPException(
            status_code=503,
            detail={
                "code": "label_contract_mismatch",
                "message": (
                    "served artifact's labels do not match "
                    f"{intent_spec.INTENT_SPEC_VERSION}: artifact has "
                    f"{len(classes)} labels, service expects "
                    f"{len(intent_spec.INTENTS)}. Retrain: "
                    "python training/train_intents.py"
                ),
                "modelStatus": entry.status,
            },
        )
    return classes


def _threshold(entry: Any) -> float:
    """The abstain floor the SERVED artifact was validated with, clamped.

    Same mechanism as `sentiment._neg_threshold` and `pricing._policy_max_ratio`,
    and for the same reason: the number describes one model's score distribution.
    A retrain that shifts the scale ships a new floor with itself; this file's
    `DEFAULT_THRESHOLD` only ever applies to an artifact that declares none.
    """
    raw = (entry.meta or {}).get("confidenceThreshold")
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        return DEFAULT_THRESHOLD
    return float(min(max(float(raw), MIN_THRESHOLD), MAX_THRESHOLD))


def _fallback_label(entry: Any, labels: list[str]) -> str:
    """The label an abstention becomes, preferring the artifact's own declaration."""
    declared = (entry.meta or {}).get("fallbackIntent")
    if isinstance(declared, str) and declared in labels:
        return declared
    return FALLBACK_INTENT


#: Single-slot cache for the served artifact's word vocabulary, keyed by model
#: version so `/nlu/refresh` invalidates it for free.
_VOCAB_CACHE: tuple[str, frozenset[str]] = ("", frozenset())


def _known_unigrams(entry: Any) -> frozenset[str]:
    """The word-vectoriser terms the SERVED artifact was fitted on.

    Used for one check the confidence floor provably cannot make. `char_wb` n-grams
    fire on any string at all, so a keyboard-mash ("asdkjh qwe zxcv") still lands
    somewhere in the 15-way simplex — measured at `greeting` 0.528, i.e. ABOVE the
    0.45 floor. Nothing is wrong with the calibration: 0.53 is an honest statement
    about character shapes. It is just not evidence about intent.

    An utterance none of whose tokens is a fitted word term has no word evidence at
    all, and this is decidable rather than a guess: `ngram_range=(1, 2)` with
    `min_df=1` puts every training unigram in the vocabulary, so a bigram key can
    only exist when both its unigrams do — "no token is a vocabulary unigram"
    therefore means the whole word half of the feature union is a zero row. Checked
    against the transformer itself over all 1,830 corpus + exam rows and 87
    gibberish strings: 0 disagreements with `nnz(word.transform(text)) == 0`.

    The cost of the check on real data is measured, not assumed: it fires on 0 of
    the 1,680 corpus rows and 0 of the 150 exam rows, and on 85 of 87 gibberish
    strings (the other two are already `no_evidence`). Misspellings survive it
    because `nlu_text.prep` canonicalises them BEFORE this runs — "futbal" arrives
    as "football", which is in the vocabulary. 0.022 ms per call.

    Returns an empty set when the pipeline's shape is not what this code expects,
    which disables the guard rather than breaking the endpoint: an unrecognised
    pipeline is a reason to fall back to the confidence floor alone, not to refuse
    to parse.
    """
    global _VOCAB_CACHE
    version, cached = _VOCAB_CACHE
    if version == entry.version:
        return cached
    vocab: frozenset[str] = frozenset()
    try:
        union = entry.estimator.named_steps["features"]
        word = dict(union.transformer_list)["word"]
        vocab = frozenset(term for term in word.steps[-1][1].vocabulary_ if " " not in term)
    except Exception as exc:  # noqa: BLE001 — the guard is an optimisation, not the contract
        log.warning(
            "intent word vocabulary unavailable (%s): out-of-vocabulary guard disabled, "
            "abstention falls back to the %.2f confidence floor alone",
            type(exc).__name__, _threshold(entry),
        )
    _VOCAB_CACHE = (entry.version, vocab)
    return vocab


def _scored(entry: Any, labels: list[str], text: str) -> list[tuple[str, float]]:
    """Every label with its calibrated probability, best first.

    ONE `predict_proba` call produces both the label and its confidence, which is
    exactly how `train_intents._predict_with_conf` measured every number in the
    model card. Deriving the label from `predict()` and the confidence from a
    second call would be two model evaluations that are only USUALLY consistent —
    they can disagree, because `CalibratedClassifierCV.predict` on a calibrated
    estimator and the argmax of its probabilities are computed differently.
    """
    try:
        row = entry.estimator.predict_proba([text])[0]
    except Exception as exc:  # noqa: BLE001 — an artifact fault, not a bad request
        log.error("intent predict_proba failed on a %d-char utterance: %s", len(text), exc)
        raise HTTPException(
            status_code=503,
            detail={
                "code": "inference_failed",
                "message": f"intent inference failed: {type(exc).__name__}",
                "modelStatus": entry.status,
            },
        ) from exc
    pairs = [(label, float(p)) for label, p in zip(labels, row)]
    pairs.sort(key=lambda pair: (-pair[1], pair[0]))
    return pairs


# Routes


@router.post("/nlu/parse", response_model=ParseResponse)
def parse(body: ParseRequest) -> ParseResponse:
    """Classify one utterance and extract its slots. FR8.15's NLU step.

    The two halves are independent on purpose, and BOTH always run:

    * The classifier can be confident on an utterance with no slots at all
      ("mere bookings dikhao").
    * The extractor can find slots in an utterance the classifier cannot place —
      including the case that matters most, a bare "2500" or "kal 6 baje" typed as
      the ANSWER to a question the dialog manager asked. Returning `entities: {}`
      alongside an abstention would break slot-filling for exactly the turns where
      the user was being most cooperative.

    So an abstention still carries its slots, and the response reports which half
    spent the time.
    """
    started = time.perf_counter()
    entry = _require_model()
    labels = _labels(entry)
    threshold = _threshold(entry)

    t_ent = time.perf_counter()
    slots = entities.extract(body.text, now=body.now)
    entity_ms = (time.perf_counter() - t_ent) * 1000.0

    t_int = time.perf_counter()
    known = _known_unigrams(entry)
    if not nlu_text.content_tokens(body.text):
        # Nothing but placeholders after normalisation ("???", "🙏"). The estimator
        # is not called at all: it would answer, and its answer would be a reading
        # of punctuation dressed up as a calibrated probability.
        top_intent, top_confidence = _fallback_label(entry, labels), 0.0
        abstained, reason, alternatives = True, REASON_NO_EVIDENCE, []
    elif known and not any(token in known for token in nlu_text.tokens(body.text)):
        # Real tokens, none of them ever seen in training — see `_known_unigrams`.
        # Same treatment as no evidence, different reason, because Node's reply
        # differs: "I did not understand that" rather than the slot-filling nudge.
        top_intent, top_confidence = _fallback_label(entry, labels), 0.0
        abstained, reason, alternatives = True, REASON_NO_KNOWN_TERMS, []
    else:
        pairs = _scored(entry, labels, body.text)
        top_intent, top_confidence = pairs[0]
        abstained = top_confidence < threshold
        reason = REASON_LOW_CONFIDENCE if abstained else None
        alternatives = [
            ScoredIntent(intent=name, confidence=round(prob, 4),
                         group=intent_spec.intent_group(name))
            for name, prob in pairs[:ALTERNATIVES]
        ]
    intent_ms = (time.perf_counter() - t_int) * 1000.0

    served = _fallback_label(entry, labels) if abstained else top_intent
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    if elapsed_ms > LATENCY_BUDGET_MS:
        # Named halves, because the two have completely different cold paths:
        # dateparser's language data on the entity side, the joblib and the
        # vectorisers on the intent side. "the parse was slow" is not actionable.
        log.warning(
            "nlu parse over budget: %.1fms (intent %.1f, entity %.1f) budget %.0fms",
            elapsed_ms, intent_ms, entity_ms, LATENCY_BUDGET_MS,
        )
    log.info(
        "nlu parse intent=%s conf=%.3f abstained=%s chars=%d session=%s %.1fms",
        served, top_confidence, abstained, len(body.text),
        body.session_id or "-", elapsed_ms,
    )
    return ParseResponse(
        intent=served,
        confidence=round(top_confidence, 4),
        entities=slots,
        abstained=abstained,
        abstain_reason=reason,
        top_intent=top_intent,
        top_confidence=round(top_confidence, 4),
        intent_group=intent_spec.intent_group(served),
        alternatives=alternatives,
        threshold=threshold,
        model_version=entry.version,
        elapsed_ms=round(elapsed_ms, 2),
        intent_ms=round(intent_ms, 2),
        entity_ms=round(entity_ms, 2),
    )


@router.get("/nlu/spec")
def nlu_spec() -> dict[str, Any]:
    """Everything a caller needs to interpret a parse, without guessing.

    Deliberately does NOT 503 when the artifact is missing. This endpoint answers
    "what contract does this service implement", which is true whether or not a
    joblib is on disk; the model's own state is reported as a field instead. That
    split is what lets Node validate its label mapping at startup even against a
    service whose model has not been trained yet — and it is why the intent
    CATALOG lives here with its glosses: the dialog manager routes on the label,
    and a label it has never heard of must be a visible mismatch rather than a
    silent no-op branch.

    The `corpus` block is the dataset contract (row budgets, near-duplicate
    thresholds, exam quotas). It is on the wire for the report and the committee:
    it is the difference between claiming a model was trained honestly and being
    able to show the rules the data was held to.
    """
    entry = registry.get(MODEL_KEY)
    meta = entry.meta or {}
    return {
        "success": True,
        "data": {
            "model": {
                "key": MODEL_KEY,
                "status": entry.status,
                "reason": entry.reason,
                "modelVersion": entry.version,
                "artifact": entry.path.name if entry.path else None,
                "trainedAt": meta.get("trainedAt"),
                "threshold": _threshold(entry),
                "thresholdSource": (
                    "artifact" if meta.get("confidenceThreshold") is not None else "router default"
                ),
                "fallbackIntent": meta.get("fallbackIntent") or FALLBACK_INTENT,
                "metrics": meta.get("metrics"),
                "trainer": "python training/train_intents.py",
            },
            "intents": [
                {"intent": name, "group": group, "gloss": gloss, "confusableWith": sibling}
                for name, group, gloss, sibling in intent_spec.INTENT_CATALOG
            ],
            "groups": list(intent_spec.INTENT_GROUPS),
            "entities": entities.describe(),
            "text": nlu_text.describe(),
            "corpus": intent_spec.spec(),
            "abstainReasons": {
                REASON_LOW_CONFIDENCE: "top probability below the artifact's threshold",
                REASON_NO_EVIDENCE: "no content tokens after normalisation",
                REASON_NO_KNOWN_TERMS: "tokens present, none of them in the fitted word vocabulary",
            },
            "limits": {
                "maxTextChars": MAX_TEXT_CHARS,
                "alternatives": ALTERNATIVES,
                "latencyBudgetMs": LATENCY_BUDGET_MS,
            },
        },
        "message": (
            f"Assistant NLU contract: {len(intent_spec.INTENTS)} intents "
            f"({intent_spec.INTENT_SPEC_VERSION}), "
            f"{len(entities.ENTITY_KEYS)} rule-extracted slots "
            f"({entities.ENTITY_SPEC_VERSION})"
        ),
    }


@router.post("/nlu/refresh")
def refresh_nlu() -> dict[str, Any]:
    """Pick up a freshly trained intent artifact without restarting uvicorn.

    Mirrors `/reco/refresh` exactly, including its deliberate failure mode: the
    cached object is dropped BEFORE the replacement is validated, so if
    `models/intent_latest.joblib` is missing or its label/normaliser fingerprints
    no longer match this code, this returns 503 with the registry's reason and
    `/nlu/parse` starts returning 503 too. Serving a model whose file on disk has
    been replaced by an incompatible one is a quieter and worse lie than an outage
    that says why.

    `train_intents.py` writes `intent_latest.joblib` only when all ten of its gates
    pass, so a failed retrain leaves the previously served artifact in place and
    this route is a no-op that reports the same version back.

    Key-gated like every other route (the `X-API-Key` middleware exempts only
    /health and the docs), so a phone cannot reach it and Node is the only caller.
    """
    registry.reload(MODEL_KEY)
    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "model_not_loaded",
                "message": f"intent model unavailable ({entry.status}): "
                           f"{entry.reason or 'no reason recorded'}",
                "modelStatus": entry.status,
            },
        )
    labels = _labels(entry)
    return {
        "success": True,
        "data": {
            **entry.describe(),
            "labels": len(labels),
            "threshold": _threshold(entry),
        },
        "message": f"Intent classifier reloaded from {entry.path.name if entry.path else 'disk'}",
    }


def warm() -> str:
    """Pay both cold costs at boot, best-effort. Called from main.py's lifespan.

    This is the one warm-up in the service that is fixing a real, measured cliff
    rather than shaving a first-request tail: `dateparser`'s language data took
    8,254 ms on its first parse and 1-7 ms after (measured in `entities.warm()`).
    A 50 ms budget and an 8-second first request are not the same feature, and the
    first user of the assistant after a deploy must not be the one who finds that
    out. The gazetteer's read of `models/reco_latest.joblib` is paid here too.

    Then one real parse through the actual route, which loads the joblib and warms
    both vectorisers.

    Never raises. A model that cannot warm must still surface as an honest 503 on
    `/nlu/parse` via the lazy-load contract, not as a service that refuses to boot
    — the same rule `pricing.warm()` and `sentiment.warm()` follow.
    """
    detail = ""
    try:
        stats = entities.warm()
        detail = (f"entities {stats['areas']} areas, dateparser="
                  f"{stats['dateparser']} in {stats['elapsedMs']}ms")
    except Exception as exc:  # noqa: BLE001 — warm-up must never break boot
        log.warning("entity warm-up failed (non-fatal): %s", exc)
        detail = f"entities warm-up skipped ({type(exc).__name__})"

    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        return f"nlu not warmed — intent model {entry.status}; {detail}"
    try:
        result = parse(ParseRequest(text="kal shaam f-11 me futsal ground chahiye"))
        return (f"nlu warmed (model {result.model_version}, "
                f"{result.elapsed_ms}ms first parse); {detail}")
    except Exception as exc:  # noqa: BLE001
        log.warning("nlu warm-up failed (non-fatal): %s", exc)
        return f"nlu warm-up skipped ({type(exc).__name__}); {detail}"


__all__ = (
    "router",
    "MODEL_KEY",
    "warm",
    "MAX_TEXT_CHARS",
    "DEFAULT_THRESHOLD",
    "ALTERNATIVES",
    "LATENCY_BUDGET_MS",
    "FALLBACK_INTENT",
    "REASON_LOW_CONFIDENCE",
    "REASON_NO_EVIDENCE",
    "REASON_NO_KNOWN_TERMS",
    "INTENT_SPEC_VERSION",
    "ENTITY_SPEC_VERSION",
    "NLU_TEXT_SPEC_VERSION",
    "ParseRequest",
    "ParseResponse",
    "ScoredIntent",
)
