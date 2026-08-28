"""
Model registry  —  S.3 Wave A

WHAT IT IS FOR
`/health` has to answer "which models are loaded, and at what version" — the wave's
requirement #1. That question needs somewhere that knows what is on disk, what
loaded, what refused to load and why. This is that place.

It is also the component that makes train/serve skew impossible rather than
unlikely. Every artifact carries the `FEATURE_SPEC_VERSION` that was in effect
when it was trained. On load, that string is compared against the one currently in
core/features.py. If they differ, the model is marked `incompatible` and is never
served. The alternative — feeding a model trained on 10 features an 11-feature
frame — does not crash; sklearn happily predicts, and the prediction is garbage
wearing a confidence score. A pricing engine that is confidently wrong is worse
than one that is honestly unavailable, because a venue owner acts on it.

THE FILENAME CONVENTION
    models/<key>_latest.joblib      the artifact this service will serve
    models/<key>_<timestamp>.joblib every trained run, kept for provenance

`<key>_latest.joblib` is what gets loaded; `pricing_latest.joblib` therefore
registers under the key `pricing`. Timestamped siblings are the audit trail — they
are what lets you answer "which exact model produced the screenshot in the report"
three months from now, which for an FYP is the difference between evidence and a
claim. .gitignore keeps `*_latest.joblib` and ignores the timestamped ones, so a
fresh clone can serve without carrying every historical artifact in git.

THE ARTIFACT CONTRACT (written by training/train_pricing.py in Wave B)
A dict, not a bare estimator, because a bare estimator cannot tell you what it was
trained on:

    {
      "model":              sklearn Pipeline (preprocessing INSIDE it),
      "featureSpecVersion": features.FEATURE_SPEC_VERSION at train time,
      "featureOrder":       list(features.FEATURE_ORDER) at train time,
      "modelVersion":       e.g. "pricing-v1-20260824-1830",
      "trainedAt":          ISO-8601 UTC,
      "metrics":            {"rocAuc": ..., "brier": ..., "logLoss": ..., ...},
      "libraries":          {"sklearn": ..., "numpy": ..., "pandas": ..., "python": ...},
      "dataset":            {"rows": ..., "source": "synthetic", "seed": ...},
    }

`dataset.source` is in the contract on purpose. This model is trained on simulated
data (the live database has 22 bookings and not one instance of the same slot
offered at two prices, so it contains no elasticity signal at all). That fact must
travel with the artifact and surface in /health, so nothing downstream can present
a synthetic model as if it had learned from real Pakistani market demand.

WHY NOTHING HERE RAISES
A corrupt or stale .joblib must degrade the pricing feature, not take down the
process. Every failure is captured as a status string and a reason; the router
turns a non-ready model into a 503, the Node client turns a 503 into its heuristic,
and the owner still sees a dashboard. Same principle as
backend/src/utils/globalSettings.js: "a bad row must not be able to take out a
booking", so `get()` there never throws either.
"""

from __future__ import annotations

import logging
import platform
import sys
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import config, features, intent_spec, nlu_text, reco_features, text_norm

log = logging.getLogger("sportlynk.ml.registry")

#: Suffix that marks the artifact to serve.
LATEST_SUFFIX = "_latest.joblib"

#: Model keys this service knows about. Listed explicitly rather than discovered
#: purely from disk, so /health can report `not_loaded` for a model that is
#: EXPECTED but absent. Discovery alone cannot distinguish "no pricing model yet"
#: from "no pricing model was ever supposed to exist" — and in Wave A the correct
#: answer is the first one, which is the whole point of the health endpoint.
KNOWN_MODELS: tuple[str, ...] = ("pricing", "sentiment", "reco", "intent")

#: Status values, exhaustive. Exported as constants because the router branches on
#: them and the Node client's tests assert on them — a typo'd string literal in
#: either place would silently mean "not ready".
STATUS_READY = "ready"
STATUS_NOT_LOADED = "not_loaded"
STATUS_INCOMPATIBLE = "incompatible"
STATUS_ERROR = "error"


# ── per-model load contracts ──────────────────────────────────────────────────
#
# The registry's reason for existing is to refuse a stale artifact rather than
# serve a confidently-wrong one. But "stale" is model-specific: pricing skews if
# the FEATURE SET drifts (core/features.py), sentiment skews if the frozen TEXT
# NORMALIZER drifts (core/text_norm.py) — a model trained on `<num>`/`_neg` tokens
# fed text tokenised by a different normalizer predicts garbage with a confidence
# score. So each known model pins itself, at load time, to the exact serving-side
# component it must agree with. Expressed once, here, so both models get the same
# guarantee and adding the third is a dict entry, not a rewrite of _load().


@dataclass(frozen=True)
class ModelContract:
    """What a given model key must prove at load time to be served.

    * ``spec_field``   — the payload key holding the spec string stamped at train time.
    * ``service_spec`` — the spec string THIS process would stamp now; the artifact's
                         must equal it or the model is `incompatible`.
    * ``trainer``      — retrain command, quoted verbatim in the reason string so the
                         /health reader knows exactly how to fix a mismatch.
    * ``verify``       — a second, finer check under the SAME spec version (feature
                         ORDER for pricing, normalizer FINGERPRINT for sentiment):
                         returns an incompatibility reason, or None when compatible.
    """

    spec_field: str
    service_spec: Callable[[], str]
    trainer: str
    verify: Callable[[dict[str, Any]], str | None]


def _pricing_verify(payload: dict[str, Any]) -> str | None:
    order = payload.get("featureOrder")
    if order is not None and tuple(order) != features.FEATURE_ORDER:
        # Same version string, different columns — a bad rebase, or a feature added
        # without bumping FEATURE_SPEC_VERSION. Belt and braces to the version check.
        return (
            "feature ORDER mismatch under the same spec version — "
            f"artifact={list(order)} service={list(features.FEATURE_ORDER)}. "
            "Bump FEATURE_SPEC_VERSION and retrain."
        )
    return None


def _sentiment_verify(payload: dict[str, Any]) -> str | None:
    fingerprint = payload.get("normSpecFingerprint")
    current = text_norm.norm_spec_fingerprint()
    if fingerprint is not None and fingerprint != current:
        # The version string can stay "sentiment-norm-v1" while the regex/vocab of
        # the normalizer changes underneath it; the fingerprint is the mechanism
        # that catches the day someone edits text_norm.py without bumping the name.
        return (
            "normalizer FINGERPRINT mismatch under the same spec version — "
            f"artifact={fingerprint!r} service={current!r}. The frozen normalizer in "
            "core/text_norm.py changed; retrain: python training/train_sentiment.py"
        )
    return None

def _reco_verify(payload: dict[str, Any]) -> str | None:
    fingerprint = payload.get("recoSpecFingerprint")
    current = reco_features.reco_spec_fingerprint()
    if fingerprint != current:
        return f"recommender feature fingerprint mismatch: artifact={fingerprint!r} service={current!r}. Retrain: python training/build_reco.py"
    return None


def _intent_verify(payload: dict[str, Any]) -> str | None:
    """Model #4 answers to TWO frozen contracts, and only two.

    GATED, because either one drifting makes the artifact predict confident
    nonsense:
      * the LABEL set (`intent_spec.intent_spec_fingerprint`) — the router reads
        `classes_` positionally, so a renamed or reordered intent misassigns every
        probability;
      * the TEXT normaliser (`nlu_text.nlu_text_fingerprint`) — the artifact bakes
        `nlu_text.prep` in as a FunctionTransformer, so the code that prepped the
        training rows IS this process's code. Edit a fold table and the vocabulary
        the vectoriser learned no longer describes what arrives at serving time.
        Same failure mode as sentiment's normalizer fingerprint.

    NOT gated, and deliberately so:
      * `datasetSpecFingerprint` — the corpus GENERATION rules (row budgets, exam
        quotas, near-duplicate ceilings). Provenance, not compatibility: those
        rules describe how the training data was built, and changing them cannot
        make an already-trained model disagree with this service. Gating it would
        brick a working assistant the day someone edits a row budget.
      * `entitySpecFingerprint` — the rule extractor is SERVED next to this model
        (`POST /nlu/parse` returns both) but the classifier does not consume it.
        Moving the "shaam" window must not take the classifier offline.
    Both are still stamped in the artifact and published on /health, because
    "which data, which rules" is a question the report has to answer.
    """
    checks = (
        ("intentSpecFingerprint", intent_spec.intent_spec_fingerprint(),
         "the intent LABEL contract in core/intent_spec.py changed"),
        ("nluTextSpecFingerprint", nlu_text.nlu_text_fingerprint(),
         "the frozen normaliser in core/nlu_text.py changed"),
    )
    for field, current, why in checks:
        stamped = payload.get(field)
        if stamped is not None and stamped != current:
            return (
                f"{field} mismatch under the same spec version — "
                f"artifact={stamped!r} service={current!r}. {why}; "
                "retrain: python training/train_intents.py"
            )
    return None


#: The contract per known model. A key absent here (a stray *_latest.joblib from an
#: experiment) is still loaded and reported, but without a spec check — we cannot
#: verify a contract we do not know, and that fact is made explicit in its reason.
MODEL_CONTRACTS: dict[str, ModelContract] = {
    "pricing": ModelContract(
        spec_field="featureSpecVersion",
        service_spec=lambda: features.FEATURE_SPEC_VERSION,
        trainer="python training/train_pricing.py",
        verify=_pricing_verify,
    ),
    "sentiment": ModelContract(
        spec_field="normSpecVersion",
        service_spec=lambda: text_norm.NORM_SPEC_VERSION,
        trainer="python training/train_sentiment.py",
        verify=_sentiment_verify,
    ),
    "reco": ModelContract(
        spec_field="recoSpecVersion",
        service_spec=lambda: reco_features.RECO_SPEC_VERSION,
        trainer="python training/build_reco.py",
        verify=_reco_verify,
    ),
    "intent": ModelContract(
        spec_field="intentSpecVersion",
        service_spec=lambda: intent_spec.INTENT_SPEC_VERSION,
        trainer="python training/train_intents.py",
        verify=_intent_verify,
    ),
}


class LoadedModel:
    """One artifact, plus everything /health and the model card need to say about it."""

    __slots__ = ("key", "path", "status", "reason", "estimator", "meta", "loaded_at")

    def __init__(
        self,
        key: str,
        *,
        path: Path | None = None,
        status: str = STATUS_NOT_LOADED,
        reason: str | None = None,
        estimator: Any = None,
        meta: dict[str, Any] | None = None,
    ) -> None:
        self.key = key
        self.path = path
        self.status = status
        self.reason = reason
        self.estimator = estimator
        self.meta = meta or {}
        self.loaded_at = datetime.now(tz=timezone.utc).isoformat(timespec="seconds")

    @property
    def is_ready(self) -> bool:
        return self.status == STATUS_READY and self.estimator is not None

    @property
    def version(self) -> str | None:
        value = self.meta.get("modelVersion")
        return str(value) if value else None

    def describe(self) -> dict[str, Any]:
        """
        The /health view. camelCase, because it goes on the wire.

        `reason` is present on every non-ready status. A health endpoint that says
        `"status": "error"` and nothing else sends whoever is on call to read logs
        on a box they may not have; the reason string is the whole value of the
        endpoint at 2am.

        `specVersion` is the model-agnostic answer to "what contract was this trained
        under" — pricing's featureSpecVersion, sentiment's normSpecVersion, whichever
        applies. `featureSpecVersion` is kept alongside it, unchanged, so the existing
        pricing consumers (main.py, the Node client tests) keep reading the field they
        already read; it is simply null for a model that has no feature spec.
        """
        contract = MODEL_CONTRACTS.get(self.key)
        spec_version = self.meta.get(contract.spec_field) if contract else None
        return {
            "key": self.key,
            "status": self.status,
            "reason": self.reason,
            "modelVersion": self.version,
            "specVersion": spec_version,
            "featureSpecVersion": self.meta.get("featureSpecVersion"),
            "trainedAt": self.meta.get("trainedAt"),
            "datasetSource": (self.meta.get("dataset") or {}).get("source"),
            "metrics": self.meta.get("metrics"),
            "artifact": self.path.name if self.path else None,
            "checkedAt": self.loaded_at,
        }


class ModelRegistry:
    """
    Loads artifacts once, answers questions about them cheaply.

    Loading is lazy and cached: `uvicorn --reload` restarts the process constantly
    in development, and a joblib load is hundreds of milliseconds. It is also
    lock-guarded — uvicorn serves requests on a thread pool, and two concurrent
    /health calls on a cold process would otherwise both unpickle the same file.
    """

    def __init__(self, model_dir: Path | None = None) -> None:
        self._dir = model_dir or config.MODEL_DIR
        self._lock = threading.Lock()
        self._cache: dict[str, LoadedModel] = {}

    # ── loading ─────────────────────────────────────────────────────────────

    def path_for(self, key: str) -> Path:
        return self._dir / f"{key}{LATEST_SUFFIX}"

    def get(self, key: str) -> LoadedModel:
        """The model for `key`, loading it on first use. Never raises."""
        cached = self._cache.get(key)
        if cached is not None:
            return cached
        with self._lock:
            cached = self._cache.get(key)  # another thread may have won the race
            if cached is not None:
                return cached
            loaded = self._load(key)
            self._cache[key] = loaded
            return loaded

    def reload(self, key: str | None = None) -> None:
        """
        Drop the cache so the next `get()` re-reads disk.

        Needed because Wave B trains a model into a directory this process is
        already serving from. Without it, the only way to pick up a freshly trained
        artifact is to restart uvicorn — survivable for one developer, and exactly
        the kind of footgun that turns into "the model didn't change" during a demo.
        """
        with self._lock:
            if key is None:
                self._cache.clear()
            else:
                self._cache.pop(key, None)

    def _load(self, key: str) -> LoadedModel:
        path = self.path_for(key)
        contract = MODEL_CONTRACTS.get(key)
        trainer_hint = contract.trainer if contract else "the matching training script"

        if not path.exists():
            return LoadedModel(
                key,
                status=STATUS_NOT_LOADED,
                reason=f"{path.name} not found in {self._dir}. Train it with:  {trainer_hint}",
            )

        # joblib is imported here, not at module import: it pulls in numpy and
        # scipy, and /health must still answer if the ML dependencies are only
        # half-installed. A health endpoint that cannot start because of the thing
        # it is meant to report on is not a health endpoint.
        try:
            import joblib  # noqa: PLC0415  (deliberate late import)
        except Exception as exc:  # pragma: no cover - environment failure
            return LoadedModel(
                key, path=path, status=STATUS_ERROR, reason=f"joblib unavailable: {exc}"
            )

        try:
            payload = joblib.load(path)
        except Exception as exc:
            # Truncated: an unpickling traceback can be enormous and this string
            # goes into an HTTP response body.
            return LoadedModel(
                key,
                path=path,
                status=STATUS_ERROR,
                reason=f"could not load artifact: {type(exc).__name__}: {str(exc)[:200]}",
            )

        if not isinstance(payload, dict) or "model" not in payload:
            return LoadedModel(
                key,
                path=path,
                status=STATUS_ERROR,
                reason=(
                    "artifact is not the expected dict {model, modelVersion, ...} — "
                    f"retrain with {trainer_hint}"
                ),
            )

        meta = {k: v for k, v in payload.items() if k != "model"}

        # ── the compatibility contract: refuse a stale artifact, don't serve it ──
        # Model-specific (see MODEL_CONTRACTS): pricing checks the feature spec +
        # column order against core/features.py; sentiment checks the normalizer
        # spec + fingerprint against core/text_norm.py. A key with no contract is a
        # stray *_latest.joblib from an experiment — we cannot vouch for a contract
        # we do not know, so it loads but is flagged, never silently trusted.
        trained_spec = meta.get(contract.spec_field) if contract else None
        if contract is not None:
            service_spec = contract.service_spec()
            if trained_spec != service_spec:
                # The guard this class exists for. Refuse, loudly, rather than predict.
                return LoadedModel(
                    key,
                    path=path,
                    status=STATUS_INCOMPATIBLE,
                    meta=meta,
                    reason=(
                        f"{contract.spec_field} mismatch: artifact was trained on "
                        f"{trained_spec!r} but this service builds {service_spec!r}. "
                        f"Retrain: {contract.trainer}"
                    ),
                )
            finer = contract.verify(payload)
            if finer is not None:
                return LoadedModel(
                    key, path=path, status=STATUS_INCOMPATIBLE, meta=meta, reason=finer
                )

        estimator = payload["model"]
        if key != "reco" and not hasattr(estimator, "predict_proba"):
            return LoadedModel(
                key,
                path=path,
                status=STATUS_ERROR,
                meta=meta,
                reason=(
                    f"estimator {type(estimator).__name__} has no predict_proba; "
                    "a served classifier must expose predict_proba"
                ),
            )

        if contract is None:
            log.warning("model %s has no load contract; served without a spec check", key)
        log.info(
            "model %s loaded: version=%s spec=%s artifact=%s",
            key,
            meta.get("modelVersion"),
            trained_spec if contract else "(unverified)",
            path.name,
        )
        return LoadedModel(
            key, path=path, status=STATUS_READY, estimator=estimator, meta=meta
        )

    # ── reporting ───────────────────────────────────────────────────────────

    def inventory(self) -> list[dict[str, Any]]:
        """
        Every known model plus any unexpected `*_latest.joblib` found on disk.

        Both halves matter. KNOWN_MODELS reports what SHOULD be there (so a missing
        pricing model is visible as `not_loaded`, not as an empty list); the disk
        scan reports what actually is (so a stray artifact from an experiment is
        visible rather than quietly ignored).
        """
        keys = list(KNOWN_MODELS)
        try:
            for found in sorted(self._dir.glob(f"*{LATEST_SUFFIX}")):
                key = found.name[: -len(LATEST_SUFFIX)]
                if key not in keys:
                    keys.append(key)
        except OSError as exc:  # pragma: no cover - unreadable model dir
            log.warning("could not scan %s: %s", self._dir, exc)
        return [self.get(key).describe() for key in keys]

    def runtime(self) -> dict[str, Any]:
        """
        Library versions of the RUNNING process.

        Compared against the artifact's `libraries` block, this is what explains a
        model that loads but predicts differently than it did in training. A joblib
        pickle is not version-portable; sklearn says so in its own docs and warns
        on a cross-version load. requirements.txt pins exact versions for this
        reason, and this endpoint is how you check the pin actually held.

        Imports are guarded so /health survives a partial install — the case where
        you most want a working health endpoint.
        """
        out: dict[str, Any] = {
            "python": platform.python_version(),
            "platform": f"{platform.system()} {platform.release()}",
            "executable": sys.executable,
        }
        for name, module_name in (
            ("sklearn", "sklearn"),
            ("numpy", "numpy"),
            ("pandas", "pandas"),
            ("joblib", "joblib"),
        ):
            try:
                module = __import__(module_name)
                out[name] = getattr(module, "__version__", "unknown")
            except Exception:  # pragma: no cover - partial install
                out[name] = None
        return out


#: Process-wide registry. One instance, so the cache is shared across requests.
registry = ModelRegistry()


__all__ = (
    "KNOWN_MODELS",
    "LATEST_SUFFIX",
    "STATUS_READY",
    "STATUS_NOT_LOADED",
    "STATUS_INCOMPATIBLE",
    "STATUS_ERROR",
    "LoadedModel",
    "ModelRegistry",
    "registry",
)
