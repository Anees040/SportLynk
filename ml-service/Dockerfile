# SportLynk ML service — container image
#
# WHY A DOCKERFILE RATHER THAN RENDER'S NATIVE PYTHON RUNTIME
# A joblib artifact is a pickle of live scikit-learn objects, so the interpreter and
# the library versions that load one must match the versions that wrote it — the
# reason every pin in requirements.txt is exact rather than a range. Render's native
# Python runtime selects a version family, not a patch level, and that selection can
# move underneath a service between builds. Pinning the base image pins the
# interpreter for the life of the deployment, which is what keeps the four released
# artifacts under models/ loadable.
#
# The tag is the exact version of the virtualenv these artifacts were trained in
# (3.14.4, recorded in .venv/pyvenv.cfg). Should that patch tag ever be unavailable,
# `python:3.14-slim` is the correct substitution rather than relaxing a pin: the
# cp314 ABI is stable across 3.14.x, so the pinned wheels continue to apply.
FROM python:3.14.4-slim

# PYTHONUNBUFFERED is a requirement, not a preference. Without it the boot banner and
# the model inventory sit in a buffer while the service starts, Render's log view
# stays empty, and a correct slow start is indistinguishable from a hung deploy.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# The service binds 127.0.0.1 by default (app/core/config.py), which inside a
# container means nothing can reach it and Render's health check fails against a
# process that is running correctly. HOST is read only for the startup banner and the
# __main__ path — the bind address comes from the command below — but a banner that
# disagrees with the real bind address is how an hour is spent on the wrong question.
ENV ML_HOST=0.0.0.0

WORKDIR /srv/sportlynk-ml

# Dependencies are installed before the application is copied so that editing a
# router reuses the cached dependency layer. The install is the expensive step —
# scikit-learn, pandas and numpy are large wheels — and it should change only when a
# pin changes.
#
# The image carries no C compiler. A pin without a published manylinux wheel for
# cp314 therefore fails the build with a clear message instead of starting a source
# build that would exhaust the build timeout.
COPY requirements.txt ./
RUN pip install -r requirements.txt

# The serving surface, and nothing more.
#
# The artifacts are named by glob rather than copying models/ wholesale because that
# directory also holds every timestamped training candidate — 63 files, ~524 MB, of
# which the registry loads exactly these four. The candidates are gitignored, so a
# Render build would not see them in any case; the glob makes a local `docker build`
# produce the same image as the deployed one.
#
# data/ and reports/ are deliberately absent: nothing under app/ reads either at
# serve time. The area gazetteer is read out of models/reco_latest.joblib, and the
# dataset provenance /health reports comes from each artifact's own metadata.
COPY app ./app
COPY models/*_latest.joblib ./models/

# config.ensure_dirs() creates MODEL_DIR, DATA_DIR and REPORT_DIR at import time, so
# data/ and reports/ must exist or be creatable by the running user. They are created
# here and the tree is handed to an unprivileged account: the service needs no root
# privilege at any point, and a public endpoint that runs as root is one more thing a
# future vulnerability could be worth.
RUN mkdir -p data reports \
 && useradd --create-home --uid 10001 --shell /usr/sbin/nologin sportlynk \
 && chown -R sportlynk:sportlynk /srv/sportlynk-ml
USER sportlynk

# Documentation and the development default. Render injects PORT and the command
# below honours it; EXPOSE publishes nothing by itself.
EXPOSE 8000

# `exec` is load-bearing: without it uvicorn runs as a child of the shell that
# expanded PORT, and the SIGTERM Render sends on a redeploy reaches the shell rather
# than the server, so every deploy waits out the kill timeout before shutting down.
#
# One worker, deliberately. Each worker is a separate process that loads its own copy
# of the four artifacts, and the free tier's 512 MB does not hold two.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1"]
