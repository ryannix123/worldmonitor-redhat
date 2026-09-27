#!/bin/sh
# Seed loop for the `seeders` container — verbatim from podman/compose.local.yml.
cd /app || exit 1
if [ -f /app/srh-compat-shim.cjs ]; then
  export NODE_OPTIONS="--require /app/srh-compat-shim.cjs"
  echo "[seeders] SRH shim preloaded"
else
  echo "[seeders] WARN: /app/srh-compat-shim.cjs absent - running without it"
fi
while true; do
  echo "[seeders] starting pass at $(date -u +%FT%TZ)"
  sh scripts/run-seeders.sh || echo "[seeders] pass exited non-zero (per-seeder SKIP/FAIL is expected)"
  echo "[seeders] pass complete; sleeping 1h"
  sleep 3600
done
