#!/bin/sh
# Boot Odysseus on Railway.
#
# Deliberately much smaller than upstream's entrypoint. That one drops
# privileges to PUID/PGID and recursively chowns every mounted path on each
# start, which exists to stop a root container from writing root-owned files
# into a host bind mount. Railway has no host user: the volume belongs to the
# container alone, and the ownership walk would just cost boot time on a large
# data directory for a problem that cannot occur here.
set -e

# Railway persists exactly one directory per service, and for this service that
# is /app/data. Anything written outside it is lost on the next deploy, so the
# embedding model cache is redirected onto the volume. Otherwise fastembed
# re-downloads its ONNX model on every single deploy and burns the first
# minutes of the health check window doing it.
export ODYSSEUS_DATA_DIR="${ODYSSEUS_DATA_DIR:-/app/data}"
export FASTEMBED_CACHE_PATH="${FASTEMBED_CACHE_PATH:-/app/data/fastembed}"
mkdir -p "$ODYSSEUS_DATA_DIR" "$FASTEMBED_CACHE_PATH" /app/logs

# Creates the data directories, the SQLite schema and the first admin account.
# Idempotent: it skips auth.json and .env when they already exist, so it is a
# near no-op on every boot after the first. Never allowed to block startup,
# matching upstream's own entrypoint.
python /app/setup.py || true

exec python /app/railway_serve.py
