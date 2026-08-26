r"""
SportLynk ML service  —  FastAPI application  —  S.3 Wave A

WHAT THIS PROCESS IS
The third tier of SportLynk (SRS CON-5). Flutter talks to Node; Node talks to
Postgres and, for model-backed features, to this. It serves scikit-learn models
trained by the scripts in training/. It owns no database connection, holds no
session, and stores nothing — given features, it returns a prediction. That
statelessness is what makes it safe to restart mid-demo and what will make it safe
to deploy as a second Render service in S.7.

WHY A SEPARATE PYTHON PROCESS AT ALL
The alternative is exporting to ONNX and running inference inside Node, which
removes a moving part. It was rejected for this project:

  * The FYP requires a defensible training story — a reproducible training script,
    metrics, and a model card. Training is Python (scikit-learn, pandas). Keeping
    training and serving in ONE language means the SAME feature-engineering code
    runs in both, which is the only real defence against train/serve skew. An ONNX
    export re-implements feature building in JavaScript, and that second
    implementation is where the drift would live.
  * A joblib artifact of an sklearn Pipeline carries its own preprocessing. An ONNX
    graph of the estimator alone does not, so the encoders and imputers would have
    to be reproduced by hand in Node.
  * The failure mode is already handled. mlClient.js degrades to a heuristic when
    this process is unreachable, so "extra moving part" costs a label change on the
    dashboard, not an outage.

TRUST BOUNDARY
Every request except /health must carry the shared secret in `X-API-Key`. This
process is not a public API and has no user model, no JWT, no roles — the single
legitimate caller is the Node backend. Three consequences, all enforced below:

  * Comparison is `hmac.compare_digest`, not `==`. Python's `==` on str short
    circuits at the first differing byte, so response timing leaks a prefix; that is
    a practical remote attack on a secret, and the fix is one import.
  * The service REFUSES TO START without a key. An unauthenticated pricing engine
    is not a degraded service, it is an open one.
  * It binds 127.0.0.1 by default (core/config.py). In development nothing outside
    this machine has any business reaching it.

/health IS PUBLIC, AND ONLY REPORTS NON-SECRETS
It has to be reachable without the key so that "is the service up" and "is my key
right" are separately answerable — otherwise a 401 means both and you debug the
wrong one. It returns model statuses, versions and library versions. It does not
return the key; the fingerprint field is a sha256 prefix, which is how you compare
backend/.env against ml-service/.env without either process printing a secret.

RESPONSE ENVELOPE
EVERY error — 401, 422, 503, an unhandled exception, FastAPI's own validation
failure — leaves as `{success: false, message, code}`, matching golden rule 5 and
every existing SportLynk endpoint. That is the shape mlClient.js has to parse when
things go wrong, and there is exactly one of it.

Successful bodies come in two flavours, on purpose. /health and /features/spec use
the same `{success, data, message}` envelope as the Node API. The prediction
endpoints return their typed pydantic model BARE, because that is what puts a real
schema in /docs for the Flutter and Node work to be written against — wrapping them
would reduce OpenAPI to `data: object`. mlClient.js reads `body.data ?? body`, so
one reader covers both and neither side needs to remember which is which.

RUN IT
    cd ml-service
    .\.venv\Scripts\Activate.ps1
    uvicorn app.main:app --port 8000        (or: .\run_dev.ps1)
"""
# NOTE: this module's docstring is a raw string (r""") purely so the Windows
# activate path above does not read as an invalid \. escape. Without it Python
# emits a SyntaxWarning on every single boot, and a boot log that cries wolf is a
# boot log nobody reads.

from __future__ import annotations

import hmac
import logging
import sys
from contextlib import asynccontextmanager
from typing import Any, Awaitable, Callable

from fastapi import FastAPI, Request
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.responses import JSONResponse

from .core import config
from .core.registry import registry
from .routers import pricing, sentiment

# ─────────────────────────────────────────────────────────────────────────────
# Startup guards — these run at IMPORT time, before uvicorn binds a port
# ─────────────────────────────────────────────────────────────────────────────
#
# Deliberately at import rather than in the lifespan handler. A misconfigured
# service must never reach the point of accepting a connection: a process that is
# listening looks healthy to anything watching the port.

logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL.upper(), logging.INFO),
    format="%(asctime)s %(levelname)-7s %(name)s  %(message)s",
)
log = logging.getLogger("sportlynk.ml")

try:
    API_KEY: str = config.require_api_key()
except config.ConfigError as exc:
    # Printed rather than raised bare, because uvicorn would otherwise bury the
    # actionable instructions under an import traceback.
    print("\n  ML SERVICE WILL NOT START\n", file=sys.stderr)
    for line in str(exc).splitlines():
        print(f"  {line}", file=sys.stderr)
    print("", file=sys.stderr)
    raise SystemExit(78) from exc  # EX_CONFIG, sysexits.h

#: Precomputed once. compare_digest wants bytes, and encoding per request would be
#: pointless work on the hot path.
_API_KEY_BYTES = API_KEY.encode("utf-8")

#: Paths reachable without the key. Kept as an exact-match set rather than a prefix
#: check: a prefix rule (`path.startswith('/health')`) would also exempt a future
#: `/health/secrets`, and an auth bypass that arrives by accident is the kind
#: nobody reviews.
PUBLIC_PATHS = frozenset(
    {
        "/health",
        "/",
        "/docs",
        "/docs/oauth2-redirect",
        "/redoc",
        "/openapi.json",
    }
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Boot banner and shutdown line.

    Models are NOT eagerly loaded here. registry.get() loads on first use and
    caches, which keeps `uvicorn --reload` fast during development and means a
    corrupt artifact surfaces as a 503 on one endpoint instead of a process that
    will not start. The inventory is still read once at boot so the banner tells
    the truth about what is on disk.
    """
    config.ensure_dirs()
    inventory = registry.inventory()
    log.info(
        "%s v%s ready on http://%s:%s  (api-key fp=%s)",
        config.SERVICE_NAME,
        config.SERVICE_VERSION,
        config.HOST,
        config.PORT,
        config.key_fingerprint(API_KEY),
    )
    for entry in inventory:
        log.info(
            "  model %-10s %-14s %s",
            entry["key"],
            entry["status"],
            entry.get("modelVersion") or entry.get("reason") or "",
        )
    if all(e["status"] != "ready" for e in inventory):
        # Loud, because between Wave A and Wave B this is the EXPECTED state, and
        # the Node client answering with heuristic prices must never look like the
        # model working.
        log.warning("no model is loaded — /predict/* will answer 503 model_not_loaded")
        log.warning("the Node backend will fall back to its heuristic (source='heuristic')")
    yield
    log.info("%s shutting down", config.SERVICE_NAME)


app = FastAPI(
    title="SportLynk ML Service",
    version=config.SERVICE_VERSION,
    description=(
        "Serves SportLynk's trained scikit-learn models. Called only by the Node "
        "backend, authenticated with a shared X-API-Key. No CORS: no browser is a "
        "legitimate caller."
    ),
    lifespan=lifespan,
)

# No CORSMiddleware, on purpose. CORS would only matter if a browser called this
# directly, and a browser calling it directly would mean the shared secret had been
# shipped to a client — which is the thing this design is arranged to prevent.


# ─────────────────────────────────────────────────────────────────────────────
# Error envelope
# ─────────────────────────────────────────────────────────────────────────────


def envelope(message: str, *, code: str | None = None, **extra: Any) -> dict[str, Any]:
    """`{success: false, message}` plus an optional machine-readable code."""
    body: dict[str, Any] = {"success": False, "message": message}
    if code:
        body["code"] = code
    body.update(extra)
    return body


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    """
    Normalise HTTPException into the SportLynk envelope.

    Routers raise `detail={"code": ..., "message": ...}`; FastAPI's own internals
    raise a plain string. Both land here and leave looking identical, so the Node
    client never has to guess which one it received.
    """
    detail = exc.detail
    if isinstance(detail, dict):
        message = str(detail.get("message") or "Request failed")
        code = detail.get("code")
        extra = {k: v for k, v in detail.items() if k not in ("message", "code")}
    else:
        message = str(detail) if detail else "Request failed"
        code = None
        extra = {}
    return JSONResponse(
        status_code=exc.status_code,
        content=envelope(message, code=code, **extra),
        headers=getattr(exc, "headers", None),
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """
    422 for a malformed body, in the house envelope, naming the offending fields.

    FastAPI's default is `{"detail": [ ... ]}` with a list of error objects — a
    third shape mlClient.js would otherwise have to parse. The field names are kept
    (they are the whole diagnostic value) but flattened into one sentence.
    """
    parts: list[str] = []
    for err in exc.errors()[:6]:  # bounded: a wrong-typed body can produce dozens
        location = ".".join(str(p) for p in err.get("loc", ()) if p != "body")
        parts.append(f"{location or 'body'}: {err.get('msg', 'invalid')}")
    return JSONResponse(
        status_code=422,
        content=envelope(
            "Invalid request: " + "; ".join(parts), code="invalid_request"
        ),
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """
    Last line of defence, mirroring backend/src/server.js's global handler: log
    everything, return one fixed sentence. Nothing derived from the exception
    crosses the wire — a stack trace or a pickle path is information the caller has
    no use for and an attacker does.
    """
    log.exception("unhandled error [%s %s]", request.method, request.url.path)
    return JSONResponse(
        status_code=500, content=envelope("Internal server error", code="internal_error")
    )


# ─────────────────────────────────────────────────────────────────────────────
# API-key middleware
# ─────────────────────────────────────────────────────────────────────────────


@app.middleware("http")
async def api_key_middleware(
    request: Request, call_next: Callable[[Request], Awaitable[Any]]
) -> Any:
    """
    Reject anything that is not the Node backend.

    Two properties worth stating explicitly:

    1. CONSTANT TIME. `hmac.compare_digest` takes the same time whether the first
       byte differs or the last. `==` does not, and over enough requests that
       difference recovers the key one byte at a time.
    2. MISSING AND WRONG ARE THE SAME 401, with the same body. Distinguishing them
       would confirm to a caller that a key exists and it merely has the wrong one,
       which is free information. The one concession to debuggability is the
       `WWW-Authenticate` header naming the header to send — useful to a developer,
       useless to an attacker who already knows.

    The key itself is never logged. A rejected request logs its method, path and
    whether a header was present at all.
    """
    if request.url.path in PUBLIC_PATHS:
        return await call_next(request)

    supplied = request.headers.get(config.API_KEY_HEADER)
    if not supplied or not hmac.compare_digest(supplied.encode("utf-8"), _API_KEY_BYTES):
        log.warning(
            "401 %s %s (%s header %s)",
            request.method,
            request.url.path,
            config.API_KEY_HEADER,
            "mismatched" if supplied else "absent",
        )
        return JSONResponse(
            status_code=401,
            content=envelope("Unauthorized", code="invalid_api_key"),
            headers={"WWW-Authenticate": config.API_KEY_HEADER},
        )

    return await call_next(request)


# ─────────────────────────────────────────────────────────────────────────────
# Health
# ─────────────────────────────────────────────────────────────────────────────


@app.get("/health", summary="Service and model inventory (public)")
def health() -> dict[str, Any]:
    """
    Wave requirement #1: report loaded model versions.

    `success` is true whenever the PROCESS is healthy, including when no model is
    loaded — those are different questions and conflating them would make an
    unhealthy-looking service out of a correctly-running one that simply has not
    been trained yet. Whether any model can actually serve is `modelsReady`, and
    per-model detail is in `models[]` with a `reason` on anything not ready.

    `runtime` carries the sklearn/numpy/pandas versions of THIS process. Compared
    against the `libraries` block inside an artifact, that is what explains a model
    which loads but predicts differently than it did during training — joblib
    pickles are not version-portable, which is why requirements.txt pins exact
    versions.
    """
    models = registry.inventory()
    return {
        "success": True,
        "data": {
            **config.describe(),
            "modelsReady": sum(1 for m in models if m["status"] == "ready"),
            "modelsTotal": len(models),
            "models": models,
            "featureSpec": pricing.features.spec(),
            "normSpec": sentiment.text_norm.spec(),
            "runtime": registry.runtime(),
        },
        "message": "SportLynk ML service is healthy",
    }


@app.get("/", include_in_schema=False)
def root() -> dict[str, Any]:
    """Signpost. Anyone who lands here by accident should learn where to go next."""
    return {
        "success": True,
        "data": {
            "service": config.SERVICE_NAME,
            "version": config.SERVICE_VERSION,
            "health": "/health",
            "docs": "/docs",
        },
        "message": "SportLynk ML service",
    }


app.include_router(pricing.router)
app.include_router(sentiment.router)


# ─────────────────────────────────────────────────────────────────────────────
# 404
# ─────────────────────────────────────────────────────────────────────────────
# Registered LAST so it cannot shadow a real route. FastAPI's own 404 body is
# `{"detail": "Not Found"}`; the HTTPException handler above already rewrites that
# into the house envelope, so no extra catch-all route is needed here — noted
# because its absence looks like an omission next to backend/src/server.js, which
# does need an explicit one.


if __name__ == "__main__":  # pragma: no cover - convenience only
    # `python -m app.main` works, but run_dev.ps1 / uvicorn is the documented path.
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=config.HOST,
        port=config.PORT,
        log_level=config.LOG_LEVEL,
        reload=False,
    )
