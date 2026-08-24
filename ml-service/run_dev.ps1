# run_dev.ps1 — start the SportLynk ML service for development.
#
# WHY THIS FILE EXISTS
# The uvicorn command is short, but the two things around it are what get forgotten:
# activating the venv (so it runs against the pinned dependencies instead of the
# system Python) and running from ml-service/ (so `app.main` resolves and .env is
# found). On demo day, "it worked yesterday" is almost always one of those two.
#
# Same reasoning as the existing backend/sync_to_supabase.ps1 — a documented one-liner
# is a command you can hand to someone; a remembered one is not.
#
#   .\run_dev.ps1
#   .\run_dev.ps1 -Port 8001            # if 8000 is taken (change ML_SERVICE_URL too)
#   .\run_dev.ps1 -LogLevel debug
#
# Ctrl+C stops it. Deliberately NOT --reload: that needs the optional `watchfiles`
# package, and a documented command should not depend on something requirements.txt
# does not install. Restart manually after editing app/.

param(
    [int]$Port = 8000,
    [string]$BindHost = '127.0.0.1',
    [ValidateSet('trace', 'debug', 'info', 'warning', 'error')]
    [string]$LogLevel = 'info'
)

$ErrorActionPreference = 'Stop'

# Run from this script's own directory, whatever the caller's cwd was.
Set-Location -LiteralPath $PSScriptRoot

# ── venv ─────────────────────────────────────────────────────────────────
$venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host ''
    Write-Host '  No virtual environment found at ml-service\.venv' -ForegroundColor Yellow
    Write-Host '  Create it first:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      python -m venv .venv'
    Write-Host '      .\.venv\Scripts\Activate.ps1'
    Write-Host '      pip install -r requirements.txt'
    Write-Host ''
    exit 1
}

# ── .env ─────────────────────────────────────────────────────────────────
# app/core/config.py refuses to start without ML_API_KEY, and its error message is
# good. This check exists to catch the earlier mistake — no .env file at all — and
# to name the backend/.env pairing, which the Python side has no way to know about.
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.env'))) {
    Write-Host ''
    Write-Host '  ml-service\.env is missing.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      Copy-Item .env.example .env'
    Write-Host '      python -c "import secrets; print(secrets.token_hex(32))"'
    Write-Host ''
    Write-Host '  Put that key in BOTH ml-service\.env and backend\.env as ML_API_KEY' -ForegroundColor Yellow
    Write-Host '  — byte-identical, or every call from Node gets a 401 and the' -ForegroundColor Yellow
    Write-Host '  dashboard silently falls back to heuristic prices.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host "  SportLynk ML service  ->  http://${BindHost}:${Port}" -ForegroundColor Cyan
Write-Host "  health: http://${BindHost}:${Port}/health    docs: http://${BindHost}:${Port}/docs"
Write-Host '  Ctrl+C to stop.'
Write-Host ''

# The venv's python -m uvicorn, not a bare `uvicorn` from PATH: a globally installed
# uvicorn would run the SYSTEM interpreter and import the system's scikit-learn,
# which defeats the exact pinning in requirements.txt. That failure is quiet — the
# service starts and serves — and it is the reason a joblib artifact can load fine on
# one machine and warn on another.
& $venvPython -m uvicorn app.main:app --host $BindHost --port $Port --log-level $LogLevel
