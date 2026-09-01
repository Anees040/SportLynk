"""
Smoke test for the sentiment endpoints  —  S.4 Wave B

WHY THIS EXISTS AS A SCRIPT AND NOT A pytest FILE
It is the same shape as the checks in `backend/src/scripts/`: something you run,
read, and believe. It exercises the real FastAPI app through TestClient -- real
middleware, real validation, real registry -- so a pass means the wire format is
actually what `mlClient.js` and the Flutter client will receive, not what a mock
said it would be.

HOW THE MODEL-LOADED PATH IS TESTED WITHOUT FAKING A RELEASE
`models/sentiment_latest.joblib` only exists once a training run passes its release
gates, and at time of writing none has. Copying a gate-failing artifact to that name
to make the test pass would defeat the entire purpose of the gate -- /health would
then report an unreleased model as ready.

So this script loads a REAL versioned artifact off disk and injects it into the
registry IN PROCESS, exactly the way `ModelRegistry._load` would. Nothing is written
to `models/`, the release gate is untouched, and the estimator under test is a
genuinely trained pipeline rather than a stub. If a released `sentiment_latest.joblib`
does exist, that is used instead and the injection is skipped.

Run:
    cd ml-service
    .\.venv\Scripts\python.exe training\smoke_sentiment_api.py
"""

from __future__ import annotations

import asyncio
import json as jsonlib
import sys
from pathlib import Path
from typing import Any

import joblib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import config, text_norm, toxicity  # noqa: E402
from app.core.registry import STATUS_READY, LoadedModel, registry  # noqa: E402
from app.main import app  # noqa: E402
from app.routers.sentiment import MAX_BATCH_ITEMS, MAX_TEXT_CHARS  # noqa: E402

PASS, FAIL = "  ok  ", " FAIL "
failures: list[str] = []


class Response:
    """Just enough of a response object for the checks below to read naturally."""

    __slots__ = ("status_code", "_body")

    def __init__(self, status_code: int, body: bytes) -> None:
        self.status_code = status_code
        self._body = body

    def json(self) -> Any:
        return jsonlib.loads(self._body or b"null")


class Client:
    """A ~40-line ASGI caller, used instead of `fastapi.testclient.TestClient`.

    TestClient would be the obvious choice, but starlette 1.6 requires an `httpx2`
    package that is not in this venv, and adding a dependency to a pinned,
    committee-facing environment to run a smoke test is the wrong trade: the lock
    file is evidence of a reproducible build, and every entry in it should be there
    because the SERVICE needs it.

    Driving the ASGI app directly loses nothing that matters here. The request still
    passes through the real middleware stack (so the API-key check is genuinely
    exercised), the real router, and real pydantic validation -- which is the whole
    point of an end-to-end smoke test. What it does not give is httpx's redirect and
    cookie handling, and this service uses neither.
    """

    def __init__(self, asgi_app: Any) -> None:
        self._app = asgi_app

    def request(
        self, method: str, path: str, *, json: Any = None, headers: dict[str, str] | None = None
    ) -> Response:
        body = b"" if json is None else jsonlib.dumps(json).encode("utf-8")
        raw = [(b"host", b"testserver")]
        if json is not None:
            raw.append((b"content-type", b"application/json"))
        for name, value in (headers or {}).items():
            raw.append((name.lower().encode("utf-8"), value.encode("utf-8")))

        query = b""
        if "?" in path:
            path, _, tail = path.partition("?")
            query = tail.encode("utf-8")

        scope = {
            "type": "http",
            "asgi": {"version": "3.0", "spec_version": "2.3"},
            "http_version": "1.1",
            "method": method.upper(),
            "scheme": "http",
            "path": path,
            "raw_path": path.encode("utf-8"),
            "query_string": query,
            "root_path": "",
            "headers": raw,
            "client": ("testclient", 50000),
            "server": ("testserver", 80),
        }

        sent: dict[str, Any] = {"status": 500, "chunks": []}

        async def receive() -> dict[str, Any]:
            return {"type": "http.request", "body": body, "more_body": False}

        async def send(message: dict[str, Any]) -> None:
            if message["type"] == "http.response.start":
                sent["status"] = message["status"]
            elif message["type"] == "http.response.body":
                sent["chunks"].append(message.get("body", b""))

        asyncio.run(self._app(scope, receive, send))
        return Response(int(sent["status"]), b"".join(sent["chunks"]))

    def get(self, path: str, **kw: Any) -> Response:
        return self.request("GET", path, **kw)

    def post(self, path: str, **kw: Any) -> Response:
        return self.request("POST", path, **kw)


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"{PASS if condition else FAIL}{name}{('  -- ' + detail) if detail else ''}")
    if not condition:
        failures.append(name)


def newest_artifact() -> Path | None:
    """The released artifact if there is one, else the newest versioned build."""
    released = registry.path_for("sentiment")
    if released.is_file():
        print(f"using RELEASED artifact: {released.name}")
        return released
    builds = sorted(released.parent.glob("sentiment_*.joblib"))
    if not builds:
        return None
    print(f"no released artifact; injecting newest build: {builds[-1].name}")
    return builds[-1]


def inject(path: Path) -> None:
    """Put a real artifact into the registry the way ModelRegistry._load does."""
    payload = joblib.load(path)
    entry = LoadedModel(
        "sentiment",
        path=path,
        status=STATUS_READY,
        estimator=payload["model"],
        meta={k: v for k, v in payload.items() if k != "model"},
    )
    original = registry.get

    def patched(key: str) -> LoadedModel:
        return entry if key == "sentiment" else original(key)

    registry.get = patched  # type: ignore[method-assign]


def main() -> int:
    client = Client(app)
    key = {config.API_KEY_HEADER: config.require_api_key()}

    print("\n=== auth + contract (no model needed) " + "=" * 30)

    r = client.post("/predict/sentiment", json={"text": "great turf"})
    check("401 without an API key", r.status_code == 401, f"got {r.status_code}")

    r = client.get("/sentiment/spec", headers=key)
    spec = r.json().get("data", {})
    check("/sentiment/spec is 200", r.status_code == 200, f"got {r.status_code}")
    check(
        "spec publishes the label set",
        list(spec.get("labels", [])) == list(text_norm.LABELS),
        str(spec.get("labels")),
    )
    check(
        "spec publishes the norm fingerprint",
        spec.get("normSpecFingerprint") == text_norm.norm_spec_fingerprint(),
        str(spec.get("normSpecFingerprint")),
    )

    r = client.get("/health")
    health = r.json().get("data", {})
    check("/health carries normSpec", "normSpec" in health)
    check("/health still carries featureSpec", "featureSpec" in health)

    r = client.post(
        "/predict/sentiment", json={"text": "good", "notAField": 1}, headers=key
    )
    check("unknown field is rejected", r.status_code == 422, f"got {r.status_code}")

    artifact = newest_artifact()
    if artifact is None:
        r = client.post("/predict/sentiment", json={"text": "great turf"}, headers=key)
        body = r.json()
        check(
            "503 model_not_loaded when no artifact exists",
            r.status_code == 503 and body.get("code") == "model_not_loaded",
            f"{r.status_code} {body.get('code')}",
        )
        print("\nno sentiment artifact on disk -- prediction paths not exercised.")
        return 1 if failures else 0

    inject(artifact)

    print("\n=== single prediction " + "=" * 46)

    r = client.post(
        "/predict/sentiment",
        json={"text": "ground bohot zabardast tha, dobara aaunga", "reviewId": "r-1"},
        headers=key,
    )
    body = r.json()
    check("positive Roman Urdu is 200", r.status_code == 200, str(body)[:160])
    check("label is positive", body.get("label") == "positive", str(body.get("label")))
    check("score is positive", (body.get("score") or 0) > 0, str(body.get("score")))
    check("reviewId echoes back", body.get("reviewId") == "r-1")
    check("calibrated is declared false", body.get("calibrated") is False)
    check("not flagged", body.get("needsReview") is False)
    check(
        "classScores sum to ~1",
        abs(sum((body.get("classScores") or {}).values()) - 1.0) < 0.02,
        str(body.get("classScores")),
    )
    check(
        "score == P(pos) - P(neg)",
        abs(
            body["score"]
            - (body["classScores"]["positive"] - body["classScores"]["negative"])
        )
        < 1e-6,
    )
    check(
        "confidence == winning class score",
        abs(body["confidence"] - body["classScores"][body["label"]]) < 1e-6,
    )
    check(
        "threshold came from the artifact",
        isinstance(body.get("negativeProbabilityThreshold"), float),
        str(body.get("negativeProbabilityThreshold")),
    )
    check("modelVersion is published", bool(body.get("modelVersion")))
    check(
        "modelMetrics carries the exam score",
        (body.get("modelMetrics") or {}).get("domainAccuracy") is not None,
        str(body.get("modelMetrics")),
    )

    r = client.post(
        "/predict/sentiment",
        json={"text": "worst ground in the city, staff ignored us for an hour"},
        headers=key,
    )
    body = r.json()
    check("angry clean English is negative", body.get("label") == "negative", str(body.get("label")))
    check("score is negative", (body.get("score") or 0) < 0, str(body.get("score")))
    check(
        "angry but CLEAN text is not toxic",
        body["toxicity"]["flagged"] is False,
        "this is the orthogonality that matters: negative != abusive",
    )

    term = sorted(toxicity.TERMS)[0]
    r = client.post(
        "/predict/sentiment", json={"text": f"{term} management, waste of money"}, headers=key
    )
    body = r.json()
    check("abusive text is flagged", body["toxicity"]["flagged"] is True)
    check("the matched term is named", term in body["toxicity"]["matched"])
    check("needsReview is true", body.get("needsReview") is True)
    check(
        "reviewReasons names abuse",
        "abusive_language" in (body.get("reviewReasons") or []),
        str(body.get("reviewReasons")),
    )

    r = client.post("/predict/sentiment", json={"text": "میدان بہت اچھا تھا"}, headers=key)
    body = r.json()
    check("Urdu script still answers 200", r.status_code == 200)
    check(
        "Urdu script is flagged out-of-distribution",
        body.get("outOfDistribution") is True,
        "corpus is Roman Urdu + English, so this is extrapolation",
    )

    # Every one of these normalises to placeholders only ("..." -> "<sep> <sep>"),
    # which is not the same as normalising to empty -- see routers/sentiment._scoreable.
    for bad in ("...", "___", "?!", "!!!", "2500"):
        r = client.post("/predict/sentiment", json={"text": bad}, headers=key)
        check(
            f"unusable text {bad!r} is 422 unusable_text",
            r.status_code == 422 and r.json().get("code") == "unusable_text",
            f"{r.status_code} {r.json().get('code')}",
        )

    # The deliberate exception: emoji are evidence, so an emoji-only review is scored.
    r = client.post("/predict/sentiment", json={"text": "\U0001f389\U0001f389"}, headers=key)
    check(
        "emoji-only review IS scored (emoji carry polarity)",
        r.status_code == 200,
        f"{r.status_code} {str(r.json())[:80]}",
    )

    print("\n=== batch " + "=" * 58)

    items = [
        {"text": "turf saaf tha, game achi rahi", "reviewId": "b-1"},
        {"text": "ground theek tha bas, kuch khaas nahi", "reviewId": "b-2"},
        {"text": f"{term} owner, refund kabhi nahi aya", "reviewId": "b-3"},
    ]
    r = client.post("/predict/sentiment/batch", json={"items": items}, headers=key)
    body = r.json()
    check("batch is 200", r.status_code == 200, str(body)[:160])
    check("count matches", body.get("count") == 3, str(body.get("count")))
    check("results are in request order", [x["reviewId"] for x in body["results"]] == ["b-1", "b-2", "b-3"])
    check("flaggedCount counts the abusive row", body.get("flaggedCount") == 1, str(body.get("flaggedCount")))
    check("metrics published once on the envelope", body.get("modelMetrics") is not None)
    check("and not repeated per row", body["results"][0].get("modelMetrics") is None)

    r = client.post(
        "/predict/sentiment/batch",
        json={"items": [{"text": "acha tha"}, {"text": "...", "reviewId": "bad"}]},
        headers=key,
    )
    body = r.json()
    check(
        "one unusable row fails the whole batch",
        r.status_code == 422 and body.get("code") == "unusable_text",
        f"{r.status_code} {body.get('code')}",
    )
    check("the failing row is identified", body.get("itemIndex") == 1, str(body.get("itemIndex")))

    r = client.post("/predict/sentiment/batch", json={"items": []}, headers=key)
    check("empty batch is rejected", r.status_code == 422, f"got {r.status_code}")

    r = client.post(
        "/predict/sentiment/batch",
        json={"items": [{"text": "acha"} for _ in range(MAX_BATCH_ITEMS + 1)]},
        headers=key,
    )
    check("over-size batch is rejected", r.status_code == 422, f"got {r.status_code}")

    # MAX_TEXT_CHARS is a Pydantic max_length, so the boundary is what needs pinning:
    # "very long text is rejected" passes just as well on a cap of 40 as on 4000, and a
    # cap that quietly tightened would break real reviews with no failing test. A
    # char_wb 2-6 vectoriser is superlinear in length, so this cap is the CPU-exhaustion
    # guard, not a cosmetic validation. The absolute value is asserted separately from
    # the boundary, because testing the boundary against the imported constant alone
    # would pass at any cap -- including one someone lowered to 40 by accident.
    check("the caps are the documented ones", (MAX_TEXT_CHARS, MAX_BATCH_ITEMS) == (4000, 200),
          f"{MAX_TEXT_CHARS} / {MAX_BATCH_ITEMS}")

    filler = "ground acha tha aur staff bhi theek tha. "
    exact = (filler * (MAX_TEXT_CHARS // len(filler) + 1))[:MAX_TEXT_CHARS]
    over = exact + "x"

    r = client.post("/predict/sentiment", json={"text": exact}, headers=key)
    check(
        f"text of exactly MAX_TEXT_CHARS ({MAX_TEXT_CHARS}) is accepted",
        r.status_code == 200,
        f"got {r.status_code}",
    )

    r = client.post("/predict/sentiment", json={"text": over}, headers=key)
    check(
        "text of MAX_TEXT_CHARS + 1 is rejected",
        r.status_code == 422,
        f"got {r.status_code}",
    )

    r = client.post(
        "/predict/sentiment/batch",
        json={"items": [{"text": "acha tha"}, {"text": over, "reviewId": "long"}]},
        headers=key,
    )
    check(
        "one over-long row fails the whole batch",
        r.status_code == 422,
        f"got {r.status_code}",
    )

    print("\n=== consistency with the estimator " + "=" * 33)

    entry = registry.get("sentiment")
    probe = [
        "ground bohot zabardast tha",
        "washroom ganda tha, use nahi kiya",
        "slot mil gaya, sab normal raha",
        "The floodlights failed during the match",
        "price theek tha, baaki average",
    ]
    direct = list(entry.estimator.predict(probe))
    r = client.post(
        "/predict/sentiment/batch",
        json={"items": [{"text": t} for t in probe]},
        headers=key,
    )
    served = [x["label"] for x in r.json()["results"]]
    check(
        "argmax(scores) == estimator.predict() for every probe",
        served == direct,
        f"served={served} direct={direct}",
    )

    print()
    if failures:
        print(f"FAILED  {len(failures)} check(s): " + "; ".join(failures))
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
