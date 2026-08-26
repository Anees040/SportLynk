"""
Sentiment + moderation endpoint  —  S.4 Wave B  (FR9.9, FR9.10)

WHAT THIS ENDPOINT IS
`POST /predict/sentiment` scores one review with model #2 and returns three things
the rest of the system stores separately, because they answer separate questions:

    label / score   how positive or negative the review reads   (FR9.9)
    toxicity        whether it contains abusive language         (FR9.10)
    needsReview     whether a human should look at it            (moderation)

`POST /predict/sentiment/batch` does the same for many reviews in one
`predict_proba` call, which is what a moderation queue and the one-off backfill of
existing `reviews` rows need. Both answer 503 `model_not_loaded` when no valid
artifact is on disk, and neither invents a label.

WHY sentimentScore IS SIGNED POLARITY AND NOT CONFIDENCE
`reviews.sentiment_score` is a single `numeric` column (migration 013:191), and
`player_profiles.trust_sentiment` (013:207) is derived by AGGREGATING a player's
reviews. That aggregation decides what the column has to mean.

    score = P(positive) - P(negative)        in [-1, +1]

Averaging THAT is meaningful: a run of hostile reviews pulls a player's trust down
and a run of warm ones pushes it up. Averaging the model's confidence instead --
`max(probabilities)`, the other obvious candidate -- would be actively wrong,
because a confidently-negative review and a confidently-positive one would both
raise the same number. So the signed form goes in the numeric column, and
`confidence` is published as its own field for the UI to caption with.

`neutral` deliberately does not appear in the score. It is the ABSENCE of polarity,
so it belongs at 0 by construction rather than as a third term with a sign nobody
can justify. A confidently-neutral review and a review the model cannot separate
both land near 0, which is correct: neither is evidence about the reviewer.

THE PROBABILITIES ARE UNCALIBRATED, AND THIS RESPONSE SAYS SO
Model #2 is an uncalibrated `LinearSVC` wrapped so that
`predict_proba = softmax(decision_function)` (see `app/core/proba.py`). That wrapper
exists because calibrating it cost real accuracy and, critically, negative recall --
the class moderation cares about. The consequence has to be stated on the wire
rather than buried in the model card: these three numbers are a RANKING, not
frequencies. A `confidence` of 0.94 does not mean "94 times out of 100".

So the response carries `calibrated: false` alongside them. That single field is the
difference between publishing a number and publishing a claim about a number, and it
is the answer to "is that really a 94% probability?" -- asked by a supervisor, or by
whoever maintains this next. Model #1 can afford the opposite posture (calibration is
its headline metric, because its optimizer MULTIPLIES a probability by a rupee
amount); this model is used for ordering and thresholding only, so ranking is
sufficient and honesty about the difference is mandatory.

For the same reason `negativeProbabilityThreshold` is read from the ARTIFACT, not
from a constant in this file. It is an operating point measured against the exam's
score distribution for the model being served, so it belongs to that model. A
retrain that shifts the distribution ships a new threshold with it, and no code
changes. This mirrors `pricing._policy_max_ratio`, which reads its band from the
joblib for the same reason.

WHY TOXICITY IS NOT DERIVED FROM THE SENTIMENT SCORE
They are orthogonal signals and are kept orthogonal (see `app/core/toxicity.py`):

    "worst turf in the city, staff ignored us for an hour"
        strongly negative, no abuse   -> NOT toxic
    "chutiya management, complete bakwas"
        abusive                       -> toxic, whatever the score says

An earlier version OR-ed the lexicon with `P(negative) > 0.90` and called the result
"toxic". That would flag every angry-but-clean one-star review as abusive and bury
the real moderation cases in noise. `toxicity.flagged` therefore means "the lexicon
matched, and here are the terms"; `strongNegative` means "the model scored this very
negative". `needsReview` is the union, and `reviewReasons` names which fired -- so a
moderator sees WHY a row is in the queue, and `reviews.flagged` can be set from one
boolean without collapsing the distinction that produced it.

WHY AN UNSCOREABLE REVIEW IS A 422 AND NOT A NEUTRAL LABEL
Text that normalises to nothing -- "...", "___", a bare "?" -- carries no evidence.
The pipeline would still answer (an all-zero feature vector reduces to the
intercept, i.e. the training prior wearing a confidence value), and storing that is
worse than storing nothing. 422 `unusable_text` composes correctly with the client:
`mlClient.js` treats any non-2xx as "do not record a prediction", so the review
saves with `sentiment_label` NULL, which is the truthful state.

REVIEW TEXT IS NEVER LOGGED
Reviews are user-authored content about named venues and named opponents. The log
line carries the review id, the label, the flags and the text LENGTH -- never the
body, and never the matched abuse terms. Anything that must be inspected is already
in the response the caller received.

WIRE FORMAT
camelCase both directions, `extra="forbid"`, prediction endpoints return typed
pydantic BARE so /docs publishes a real schema -- all three matching
`routers/pricing.py`. `mlClient.js` reads `body.data ?? body`, so a bare body is what
the Node client already expects from a prediction route.
"""

from __future__ import annotations

import logging
from typing import Any, Iterable, Sequence

import numpy as np
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

from ..core import text_norm, toxicity
from ..core.registry import STATUS_READY, registry

log = logging.getLogger("sportlynk.ml.sentiment")

router = APIRouter(tags=["sentiment"])

#: Registry key for model #2.
MODEL_KEY = "sentiment"

#: Longest review this endpoint will score. `reviews.comment` is unbounded `text`,
#: so the cap belongs here: a char_wb vectoriser over a pasted novel is a slow
#: request on a shared threadpool, and no genuine venue review is 4,000 characters.
MAX_TEXT_CHARS = 4000

#: Reviews per batch call. Sized for a moderation page and a chunked backfill; the
#: ceiling stops one request from turning into an unbounded `predict_proba` on a
#: client timeout. Batching is the point -- per-row HTTP for a queue would pay the
#: pipeline's setup cost once per review.
MAX_BATCH_ITEMS = 200

#: Fallback operating point for the strong-negative escalation, used ONLY when the
#: served artifact carries no threshold of its own. The real value ships in the
#: joblib (`toxicity.negativeProbabilityThreshold`), because it is a property of
#: the score distribution of one trained model -- see the module docstring.
#:
#: It was 0.90 here, matching what the trainer shipped at the time. That pairing is
#: what makes a fallback dangerous: 0.90 stopped meaning "strongly negative" the
#: moment C changed and the model's margins narrowed (the highest P(negative) the
#: shipped model emits anywhere on the exam is 0.9234, so 0.90 escalated 2 rows out
#: of 68 true negatives). A fallback is by definition a guess about a model this
#: code knows nothing about, so it is now set on the LOOSE side: a slightly
#: over-eager escalation is visible and gets fixed, whereas one that never fires
#: looks exactly like a well-behaved quiet feature.
DEFAULT_NEG_THRESHOLD = 0.70

#: Bounds applied to a threshold read from a file. Below 0.5 a "strong" negative
#: could lose to another class outright; 0.999 leaves the flag unreachable.
MIN_NEG_THRESHOLD = 0.50
MAX_NEG_THRESHOLD = 0.999

#: `reviewReasons` values. Stable identifiers, safe for the client to switch on and
#: for a moderation UI to group by.
REASON_ABUSE = "abusive_language"
REASON_STRONG_NEGATIVE = "strong_negative"

#: Emoji placeholders. These ARE evidence -- a review that is nothing but "🎉" or
#: "😡" carries a genuine polarity signal, which is the whole reason `text_norm` maps
#: emoji to polarity tokens instead of discarding them. Kept out of the set below so
#: an emoji-only review is scored rather than rejected.
_EMOJI_TOKENS = frozenset(
    {
        text_norm.POS_EMOJI_TOKEN,
        text_norm.NEG_EMOJI_TOKEN,
        text_norm.NEU_EMOJI_TOKEN,
        text_norm.EMOJI_TOKEN,
    }
)

#: Normalised tokens that carry no sentiment evidence: <sep>, <exc>, <qm>, <num>,
#: <money>, <url>, <email>, <user>, <phone>. A review made only of these has nothing
#: to score -- see `_scoreable`.
#:
#: DERIVED from `text_norm.PLACEHOLDERS` rather than typed out, so that adding a
#: placeholder to the normaliser cannot silently leave a hole here. A new
#: non-emoji placeholder joins this set automatically, which is the safe default:
#: worst case a review is rejected as unusable, never scored on no evidence.
EVIDENCE_FREE_TOKENS = frozenset(text_norm.PLACEHOLDERS) - _EMOJI_TOKENS


class CamelModel(BaseModel):
    """Base: camelCase on the wire, snake_case in Python.

    `protected_namespaces` cleared for the same reason as in `routers/pricing.py`:
    `model_version` is a field we genuinely want published, it sits in pydantic's
    protected `model_` namespace, and leaving the default would emit a UserWarning
    at import time -- i.e. into the boot log, where warnings get learned-to-ignore.
    """

    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="forbid",
        str_strip_whitespace=True,
        protected_namespaces=(),
    )


# ─────────────────────────────────────────────────────────────────────────────
# Requests
# ─────────────────────────────────────────────────────────────────────────────


class SentimentRequest(CamelModel):
    """One review, as raw text.

    RAW text on purpose. The served model is a single `Pipeline` whose first step is
    `FunctionTransformer(prep_char)`, so normalisation happens INSIDE the artifact
    using the exact `app/core/text_norm.py` the model was trained against. A caller
    that pre-normalised would be applying a second, unversioned copy of that
    contract -- the one failure mode `norm_spec_fingerprint()` exists to prevent.
    """

    text: str = Field(
        min_length=1,
        max_length=MAX_TEXT_CHARS,
        description="the review body, exactly as the reviewer typed it",
    )
    #: Echoed back and written to the log line, never used as a feature. Lets the
    #: caller correlate a batch response without relying on list order.
    review_id: str | None = Field(default=None, max_length=64)


class SentimentBatchRequest(CamelModel):
    """Many reviews, scored in one `predict_proba` call."""

    items: list[SentimentRequest] = Field(min_length=1, max_length=MAX_BATCH_ITEMS)


# ─────────────────────────────────────────────────────────────────────────────
# Responses
# ─────────────────────────────────────────────────────────────────────────────


class ClassScores(CamelModel):
    """The three class scores, in `text_norm.LABELS` order.

    Named `ClassScores` and not `Probabilities` deliberately. They sum to 1 and they
    order correctly, but they are softmax over an SVM decision function and are NOT
    calibrated frequencies -- see `SentimentResponse.calibrated`.
    """

    negative: float = Field(ge=0, le=1)
    neutral: float = Field(ge=0, le=1)
    positive: float = Field(ge=0, le=1)


class ToxicityVerdict(CamelModel):
    """Whether the abuse lexicon matched, and exactly which terms did.

    `matched` is the point of the feature: a moderation flag a human can act on says
    WHICH term fired, so the review can be triaged -- or the flag disputed -- without
    re-running anything. Empty list <=> not flagged.
    """

    flagged: bool
    matched: list[str] = Field(
        default_factory=list, description="the listed lexicon terms that matched"
    )


class SentimentModelMetrics(CamelModel):
    """The served artifact's own measured scores, lifted straight from the joblib.

    On the wire for the same reason `pricing.ModelMetrics` is: an admin screen that
    captions a moderation queue with the model's accuracy must read that number off
    the artifact that produced the labels beside it, not from a constant in Dart that
    can drift a retrain later.

    `domainAccuracy` is accuracy on `domain_test_200.csv` -- the held-out, in-domain
    exam -- NOT the validation split. The validation number is over a corpus that is
    mostly public Roman Urdu and English tweets; the exam is 200 SportLynk venue
    reviews, so it is the number that answers "how well does this work on OUR data".
    Both are published because the gap between them IS the domain-shift story.
    """

    domain_accuracy: float | None = None
    domain_macro_f1: float | None = None
    validation_accuracy: float | None = None
    validation_macro_f1: float | None = None
    trained_at: str | None = None
    dataset_source: str | None = None


class SentimentResponse(CamelModel):
    """The full verdict for one review."""

    source: str = Field(
        default="model", description='always "model" from this service -- never a rule'
    )
    model_version: str | None = None
    norm_spec_version: str = text_norm.NORM_SPEC_VERSION

    review_id: str | None = None

    label: str = Field(description="negative | neutral | positive")
    score: float = Field(
        ge=-1,
        le=1,
        description=(
            "signed polarity, P(positive) - P(negative). Stored in "
            "reviews.sentiment_score; averages meaningfully into "
            "player_profiles.trust_sentiment"
        ),
    )
    confidence: float = Field(
        ge=0,
        le=1,
        description="the winning class score; NOT a calibrated probability",
    )
    class_scores: ClassScores
    calibrated: bool = Field(
        default=False,
        description=(
            "false for this model: scores are softmax over an SVM decision "
            "function, so they rank correctly but are not frequencies"
        ),
    )

    toxicity: ToxicityVerdict
    strong_negative: bool = Field(
        description="P(negative) >= the artifact's negativeProbabilityThreshold"
    )
    needs_review: bool = Field(
        description="abusive language OR strongly negative; maps to reviews.flagged"
    )
    review_reasons: list[str] = Field(
        default_factory=list,
        description=f"which checks fired: {REASON_ABUSE} / {REASON_STRONG_NEGATIVE}",
    )
    negative_probability_threshold: float = Field(
        description="the operating point actually applied, read from the artifact"
    )

    out_of_distribution: bool = Field(
        default=False,
        description=(
            "the review contains Urdu-script text. The corpus is Roman Urdu and "
            "English, so this prediction is extrapolation -- treat as low confidence"
        ),
    )
    model_metrics: SentimentModelMetrics | None = None


class SentimentBatchResponse(CamelModel):
    source: str = "model"
    model_version: str | None = None
    norm_spec_version: str = text_norm.NORM_SPEC_VERSION
    count: int
    flagged_count: int = Field(description="how many items need a human look")
    results: list[SentimentResponse] = Field(default_factory=list)
    model_metrics: SentimentModelMetrics | None = None


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _require_model() -> Any:
    """The loaded sentiment estimator, or a 503 that says exactly what is wrong.

    Forwards the registry's own diagnosis rather than collapsing it: never trained,
    trained against a different normaliser spec, or a corrupt artifact need three
    different fixes (train it / retrain it / investigate it).
    """
    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "model_not_loaded",
                "message": (
                    f"sentiment model unavailable ({entry.status}): "
                    f"{entry.reason or 'no reason recorded'}"
                ),
                "modelStatus": entry.status,
            },
        )
    return entry


def _class_order(entry: Any) -> list[str]:
    """`estimator.classes_` as a list, checked against the service's label set.

    Never assumes column 0 is "negative". scikit-learn sorts string classes
    alphabetically and `text_norm.LABELS` is alphabetical for exactly that reason, so
    the orders do agree today -- but reading `classes_` costs nothing and closes a
    silent failure mode: an artifact trained on a different label spelling would
    otherwise have every score assigned to the wrong class with nothing raising.

    A genuine mismatch is a 503, not a 500. The request was fine; the artifact
    disagrees with the service, which is the same class of fault the registry's
    compatibility contract exists to refuse.
    """
    classes = [str(c) for c in getattr(entry.estimator, "classes_", [])]
    if sorted(classes) != sorted(text_norm.LABELS):
        log.error(
            "artifact %s exposes classes %s, service expects %s",
            entry.version,
            classes,
            list(text_norm.LABELS),
        )
        raise HTTPException(
            status_code=503,
            detail={
                "code": "label_mismatch",
                "message": (
                    f"served artifact predicts {classes or '[]'} but this service's "
                    f"contract is {list(text_norm.LABELS)}. Retrain: "
                    f"python training/train_sentiment.py"
                ),
                "modelStatus": entry.status,
            },
        )
    return classes


def _scoreable(text: str) -> str:
    """Return the normalised form, or 422 if the review carries no evidence.

    Uses the SAME `text_norm` the artifact's own first pipeline step uses, so this
    check cannot disagree with what the model is about to see.

    Emptiness is not a sufficient test, which is what the first version of this
    function got wrong. Punctuation does not vanish under normalisation -- it becomes
    a placeholder:

        "___"   ->  ""                  caught by the empty check
        "..."   ->  "<sep> <sep>"       NOT empty, and scored neutral at 0.90
        "?!"    ->  "<qm> <exc>"        NOT empty
        "2500"  ->  "<num>"             NOT empty

    Those all reached the model, whose all-placeholder feature vector reduces to
    little more than the training prior -- and it duly returned `neutral` with a
    confidence near 0.90. A high-confidence label on no evidence is the single worst
    thing this endpoint could store, because nothing downstream can tell it apart
    from a real verdict.

    So the test is EVIDENCE, not emptiness: reject when every surviving token is a
    non-emoji placeholder. Emoji placeholders are deliberately exempt -- see
    `EVIDENCE_FREE_TOKENS`.
    """
    normalised = text_norm.normalize_text(text)
    tokens = normalised.split()
    if not tokens or all(token in EVIDENCE_FREE_TOKENS for token in tokens):
        raise HTTPException(
            status_code=422,
            detail={
                "code": "unusable_text",
                "message": (
                    "the review carries no sentiment evidence (punctuation, "
                    "separators or numbers only), so there is nothing to score"
                ),
            },
        )
    return normalised


def _predict(entry: Any, texts: Sequence[str]) -> np.ndarray:
    """Class scores for every review, in ONE `predict_proba` call.

    Batched for the same reason the price sweep is: the pipeline's vectoriser setup
    is paid per call, not per row, so a 200-review backfill through one call is
    dramatically cheaper than 200 calls.

    A failure here is a 503, not a 500: the request was valid and the text was
    scoreable, so the fault is the served artifact's. Only the exception TYPE reaches
    the client (Golden Rule 5); the traceback goes to the log.
    """
    if not texts:
        return np.zeros((0, len(text_norm.LABELS)), dtype=float)
    try:
        proba = np.asarray(entry.estimator.predict_proba(list(texts)), dtype=float)
    except Exception as exc:  # noqa: BLE001 - deliberately broad; see docstring
        log.exception("predict_proba failed on %d review(s)", len(texts))
        raise HTTPException(
            status_code=503,
            detail={
                "code": "inference_failed",
                "message": (
                    "the sentiment model failed to score this request "
                    f"({type(exc).__name__})"
                ),
                "modelStatus": entry.status,
            },
        ) from exc
    return np.clip(proba, 0.0, 1.0)


def _neg_threshold(entry: Any) -> float:
    """The strong-negative operating point the SERVED artifact was tuned with.

    Read from the joblib and clamped, exactly as `pricing._policy_max_ratio` reads
    the price band from its artifact. The threshold is a statement about one model's
    score distribution, so pinning it in code would let a retrain silently invalidate
    it -- the flag would keep firing at 0.90 on a model whose scores no longer live
    where 0.90 meant something.
    """
    block = (entry.meta or {}).get("toxicity") or {}
    raw = block.get("negativeProbabilityThreshold")
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        return DEFAULT_NEG_THRESHOLD
    return float(min(max(float(raw), MIN_NEG_THRESHOLD), MAX_NEG_THRESHOLD))


def _model_metrics(entry: Any) -> SentimentModelMetrics | None:
    """Lift the artifact's own scores out of the joblib meta.

    Written by `training/train_sentiment.py` into `payload["metrics"]`, so these are
    the numbers the release gates were evaluated against rather than a copy
    maintained somewhere else. `None` for an artifact that carries no metrics block,
    which the UI must render as no caption rather than as a zero.
    """
    meta = entry.meta or {}
    scores = meta.get("metrics") or {}
    if not scores:
        return None

    def num(key: str) -> float | None:
        value = scores.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return round(float(value), 4)

    dataset = meta.get("dataset") or {}
    return SentimentModelMetrics(
        domain_accuracy=num("domain_accuracy"),
        domain_macro_f1=num("domain_macro_f1"),
        validation_accuracy=num("validation_accuracy"),
        validation_macro_f1=num("validation_macro_f1"),
        trained_at=meta.get("trainedAt"),
        dataset_source=dataset.get("source"),
    )


def _verdict(
    request: SentimentRequest,
    row: np.ndarray,
    classes: Sequence[str],
    *,
    threshold: float,
    model_version: str | None,
    metrics: SentimentModelMetrics | None,
) -> SentimentResponse:
    """Assemble one review's answer from its score row.

    The label is `argmax` of the score row, which for this artifact is EXACTLY
    `estimator.predict()`: `SoftmaxSVC` applies a monotone softmax to the decision
    function, and a monotone map cannot reorder an argmax. Taking the label from the
    scores rather than issuing a second `predict()` call therefore costs nothing and
    guarantees the label can never disagree with the numbers published beside it --
    which a separate call, on a future non-monotone probability method, could.
    """
    by_class = {name: float(value) for name, value in zip(classes, row, strict=True)}
    negative = by_class["negative"]
    positive = by_class["positive"]

    label = max(by_class, key=lambda name: by_class[name])
    verdict = toxicity.check(request.text)
    strong_negative = negative >= threshold

    reasons: list[str] = []
    if verdict.flagged:
        reasons.append(REASON_ABUSE)
    if strong_negative:
        reasons.append(REASON_STRONG_NEGATIVE)

    return SentimentResponse(
        model_version=model_version,
        review_id=request.review_id,
        label=label,
        score=round(positive - negative, 4),
        confidence=round(by_class[label], 4),
        class_scores=ClassScores(
            negative=round(negative, 4),
            neutral=round(by_class["neutral"], 4),
            positive=round(positive, 4),
        ),
        toxicity=ToxicityVerdict(flagged=verdict.flagged, matched=list(verdict.matched)),
        strong_negative=strong_negative,
        needs_review=bool(reasons),
        review_reasons=reasons,
        negative_probability_threshold=round(threshold, 4),
        out_of_distribution=text_norm.has_urdu_script(request.text),
        model_metrics=metrics,
    )


def _log_batch(results: Iterable[SentimentResponse], requests: Sequence[SentimentRequest]) -> None:
    """One compact line per review. NEVER the review body, never the matched terms.

    Reviews are user-authored content about named venues and named opponents, so the
    body does not belong in a log file that outlives the request. The length is
    logged instead: it is enough to recognise a truncation or an empty-ish review
    while carrying none of the content.
    """
    for result, request in zip(results, requests, strict=True):
        log.info(
            "sentiment review=%s len=%d label=%s score=%+.3f conf=%.3f "
            "toxic=%s strongNeg=%s needsReview=%s ood=%s",
            request.review_id or "-",
            len(request.text),
            result.label,
            result.score,
            result.confidence,
            result.toxicity.flagged,
            result.strong_negative,
            result.needs_review,
            result.out_of_distribution,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────────────


@router.get("/sentiment/spec", summary="The frozen normalisation contract")
def sentiment_spec() -> dict[str, Any]:
    """Publish `core/text_norm.py`'s contract over HTTP.

    The mirror of `/features/spec`, and it exists for the same non-documentation
    reason: `text_norm.LABELS` is duplicated outside Python -- in the
    `sentiment_label` comment in migration 013, and in whatever Dart enum renders the
    badge -- and Node cannot import a Python module. This endpoint lets
    `backend/src/scripts/check_ml_service.js` ASSERT the label set and the normaliser
    fingerprint match what the rest of the system believes, turning "keep these in
    sync" from a hope into a check that fails in CI.
    """
    return {"success": True, "data": text_norm.spec()}


@router.post(
    "/predict/sentiment",
    response_model=SentimentResponse,
    summary="Classify one review + abuse check (503 when no model is loaded)",
)
def predict_sentiment(payload: SentimentRequest) -> SentimentResponse:
    """Score one review: label, signed polarity, abuse verdict, moderation flag.

    Ordering matches `pricing.predict_price`: the text is checked for scoreability
    BEFORE the model check, so an unusable review is a 422 whether or not an artifact
    happens to be loaded. The Node client's error handling therefore behaves
    identically in both states and cannot be written against one and surprised by the
    other.

    `def`, not `async def`, on purpose: `predict_proba` is CPU-bound and releases no
    event loop, so letting FastAPI run it in its threadpool is what keeps a 200-review
    batch from stalling every other request in the process.
    """
    _scoreable(payload.text)

    entry = _require_model()
    classes = _class_order(entry)
    scores = _predict(entry, [payload.text])

    result = _verdict(
        payload,
        scores[0],
        classes,
        threshold=_neg_threshold(entry),
        model_version=entry.version,
        metrics=_model_metrics(entry),
    )
    _log_batch([result], [payload])
    return result


@router.post(
    "/predict/sentiment/batch",
    response_model=SentimentBatchResponse,
    summary="Classify many reviews in one pass (503 when no model is loaded)",
)
def predict_sentiment_batch(payload: SentimentBatchRequest) -> SentimentBatchResponse:
    """Score up to `MAX_BATCH_ITEMS` reviews in a single `predict_proba` call.

    This is the endpoint for a moderation queue and for the one-off backfill of
    `reviews` rows that predate the model. Results come back in request order AND
    carry `reviewId`, so the caller can join on the id rather than trusting order.

    ALL-OR-NOTHING on validation, by design. One unusable review fails the whole
    batch with a 422 naming its position, rather than silently returning 199 results
    for a 200-item request -- a partial success the caller would have to detect by
    counting, and would eventually forget to. Scoreability is checked for every item
    up front, before any inference, so the failure is cheap and the message is
    specific.
    """
    for position, item in enumerate(payload.items):
        try:
            _scoreable(item.text)
        except HTTPException as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {}
            raise HTTPException(
                status_code=422,
                detail={
                    "code": "unusable_text",
                    "message": (
                        f"item {position}"
                        f"{f' (reviewId {item.review_id})' if item.review_id else ''}: "
                        f"{detail.get('message', 'not scoreable')}"
                    ),
                    "itemIndex": position,
                },
            ) from exc

    entry = _require_model()
    classes = _class_order(entry)
    metrics = _model_metrics(entry)
    threshold = _neg_threshold(entry)

    scores = _predict(entry, [item.text for item in payload.items])
    results = [
        _verdict(
            item,
            row,
            classes,
            threshold=threshold,
            model_version=entry.version,
            metrics=None,  # published once on the envelope, not per row
        )
        for item, row in zip(payload.items, scores, strict=True)
    ]
    _log_batch(results, payload.items)

    flagged = sum(1 for result in results if result.needs_review)
    log.info(
        "sentiment batch n=%d flagged=%d model=%s", len(results), flagged, entry.version
    )
    return SentimentBatchResponse(
        model_version=entry.version,
        count=len(results),
        flagged_count=flagged,
        results=results,
        model_metrics=metrics,
    )


__all__ = (
    "router",
    "MODEL_KEY",
    "MAX_TEXT_CHARS",
    "MAX_BATCH_ITEMS",
    "DEFAULT_NEG_THRESHOLD",
    "REASON_ABUSE",
    "REASON_STRONG_NEGATIVE",
    "SentimentRequest",
    "SentimentBatchRequest",
    "ClassScores",
    "ToxicityVerdict",
    "SentimentModelMetrics",
    "SentimentResponse",
    "SentimentBatchResponse",
)
