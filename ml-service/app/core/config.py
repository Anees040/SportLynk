"""
Settings for the ML service

WHY A MODULE AND NOT `os.environ` AT THE CALL SITE
Two rules have to hold everywhere, and scattering `os.getenv` through the code is
how one of them eventually does not:

  1. THE SERVICE MUST NOT START WITHOUT AN API KEY. An ml-service running with
     authentication disabled is a pricing engine any process on the machine can
     query and, once it is deployed as a second Render service (S.7), that any
     host on the internet can query. Failing at import time is loud and happens on
     a developer's terminal; a `None` key silently compared as equal is discovered
     by someone else. So `require_api_key()` raises during startup, not on the
     first request.
  2. THE KEY MUST NEVER BE LOGGED OR RETURNED. Nothing here has a __repr__ that
     includes it, `describe()` reports only its length and a fingerprint, and the
     one place that touches its value is the constant-time comparison in main.py.

`.env` is read from the ml-service root — the same convention backend/src/server.js
uses (`dotenv.config({ path: ... })` with an explicit absolute path rather than a
cwd-relative lookup), so `uvicorn` started from any directory still finds it.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

#: ml-service/ — this file is app/core/config.py, so three parents up.
SERVICE_ROOT = Path(__file__).resolve().parents[2]

# override=False: a real environment variable (Render's dashboard, a CI secret, a
# `$env:ML_API_KEY` set for one shell) must win over the committed-adjacent .env
# file. The opposite would mean a stale local .env quietly overrides production
# configuration — the exact failure doc/claude.md records for DATABASE_URL, where
# a leftover localhost line in .env sent a script at the wrong database.
load_dotenv(SERVICE_ROOT / ".env", override=False)

#: Header the Node backend authenticates with. Named in the spec.
API_KEY_HEADER = "X-API-Key"

#: Minimum acceptable key length. 16 chars is not cryptography, it is a typo
#: guard: it rejects `ML_API_KEY=changeme` and `ML_API_KEY=x` before they reach a
#: deployment. .env.example ships a 64-hex-char key generated from os.urandom.
MIN_API_KEY_LENGTH = 16

#: Paths a model or artifact can live at. Created on import so a fresh clone (git
#: does not track empty directories) does not fail on a missing folder — each
#: also carries a committed README.md, which keeps them in git as a side effect.
MODEL_DIR = Path(os.getenv("ML_MODEL_DIR") or (SERVICE_ROOT / "models")).resolve()
DATA_DIR = Path(os.getenv("ML_DATA_DIR") or (SERVICE_ROOT / "data")).resolve()
REPORT_DIR = Path(os.getenv("ML_REPORT_DIR") or (SERVICE_ROOT / "reports")).resolve()

#: uvicorn defaults. 127.0.0.1, deliberately — see README.md. Only the Node
#: backend, on the same machine, is a legitimate caller in development.
HOST = os.getenv("ML_HOST") or "127.0.0.1"
PORT = int(os.getenv("ML_PORT") or 8000)
LOG_LEVEL = (os.getenv("ML_LOG_LEVEL") or "info").lower()

#: Reported by /health so a mismatched pair of deployments is visible at a glance.
SERVICE_NAME = "sportlynk-ml"
SERVICE_VERSION = "0.1.0"


class ConfigError(RuntimeError):
    """Configuration is missing or unusable. Raised at startup, never at request time."""


def api_key() -> str | None:
    """The configured key, or None. Read live so tests can monkeypatch the env."""
    raw = os.getenv("ML_API_KEY")
    if raw is None:
        return None
    key = raw.strip()
    return key or None


def require_api_key() -> str:
    """
    The configured key, or a startup failure.

    The error message names the file to edit and the command that generates a key,
    because the person hitting this is usually setting the project up for the first
    time and does not yet know either.
    """
    key = api_key()
    if not key:
        raise ConfigError(
            "ML_API_KEY is not set. The service will not start without it.\n"
            f"  1. copy {SERVICE_ROOT / '.env.example'} to {SERVICE_ROOT / '.env'}\n"
            '  2. generate a key:  python -c "import secrets; print(secrets.token_hex(32))"\n'
            "  3. put the SAME value in backend/.env as ML_API_KEY"
        )
    if len(key) < MIN_API_KEY_LENGTH:
        raise ConfigError(
            f"ML_API_KEY is only {len(key)} characters; at least {MIN_API_KEY_LENGTH} "
            'are required. Generate one with:  python -c "import secrets; print(secrets.token_hex(32))"'
        )
    return key


def key_fingerprint(key: str) -> str:
    """
    First 8 hex chars of sha256(key) — safe to print.

    This exists for exactly one job: telling someone that backend/.env and
    ml-service/.env hold DIFFERENT keys without either process printing a secret.
    Two fingerprints side by side answer that in one glance; two 401s do not, and
    "check they match" costs an hour when the difference is a trailing space that
    a text editor does not show.
    """
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:8]


def ensure_dirs() -> None:
    """Create models/, data/ and reports/ if absent. Idempotent."""
    for directory in (MODEL_DIR, DATA_DIR, REPORT_DIR):
        directory.mkdir(parents=True, exist_ok=True)


def describe() -> dict[str, Any]:
    """
    Non-secret configuration, for /health and the startup banner.

    `apiKeyFingerprint` is a digest, never the key. `apiKeyConfigured` is separate
    from it so a service running without a key (which cannot happen after
    require_api_key, but could if that call were ever removed) reports the fact
    rather than an absent field nobody notices.
    """
    key = api_key()
    return {
        "service": SERVICE_NAME,
        "version": SERVICE_VERSION,
        "modelDir": str(MODEL_DIR),
        "apiKeyConfigured": bool(key),
        "apiKeyFingerprint": key_fingerprint(key) if key else None,
    }


__all__ = (
    "API_KEY_HEADER",
    "MIN_API_KEY_LENGTH",
    "SERVICE_ROOT",
    "MODEL_DIR",
    "DATA_DIR",
    "REPORT_DIR",
    "HOST",
    "PORT",
    "LOG_LEVEL",
    "SERVICE_NAME",
    "SERVICE_VERSION",
    "ConfigError",
    "api_key",
    "require_api_key",
    "key_fingerprint",
    "ensure_dirs",
    "describe",
)
