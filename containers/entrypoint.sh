#!/bin/bash
# =============================================================================
# World Monitor — container entrypoint (supervisord replacement)
# =============================================================================
# Upstream runs supervisord to manage two processes. This does the same job in
# shell, dropping the Python runtime and its dependency tree from the image.
#
# Process model:
#   PID 1  = this script, then exec'd into nginx (foreground)
#   child  = node local-api-server.mjs, bound to 127.0.0.1:$LOCAL_API_PORT
#
# Why nginx gets to be PID 1: it owns the listening socket on 8080. If nginx
# dies the container is useless, so its exit should be the container's exit.
# The sidecar is watched and its death is fatal too (see below) — the pod
# restarts, which is the OpenShift-native supervisor.
#
# Preserved from upstream's entrypoint.sh:
#   - /run/secrets → env bridge
#   - per-start random LOCAL_API_TOKEN
#   - render of /tmp/nginx-realip.conf (WM_TRUSTED_PROXY_CIDRS)
#   - envsubst of nginx.conf.template
#   - WM_SESSION_SECRET length check (warn-only here; see below)
#
# That random-token-per-start is a genuinely good design: nginx injects it on
# the private 127.0.0.1 hop to the sidecar, and it never outlives the process.
# Keeping both processes in one container is what allows it to stay ephemeral.
# =============================================================================
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# --- Docker secrets → env bridge --------------------------------------------
# Kept for docker-compose parity. On OpenShift, Secrets arrive as env vars or
# mounted files and this loop simply finds nothing.
if [ -d /run/secrets ]; then
  for secret_file in /run/secrets/*; do
    [ -f "$secret_file" ] || continue
    key="$(basename "$secret_file")"
    # Only bridge plausible env var names — a stray file like ..data (which
    # Kubernetes creates in projected volumes) must not become an export.
    case "$key" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) continue ;;
    esac
    value="$(tr -d '\n' < "$secret_file")"
    export "$key=$value"
  done
fi

# --- Sidecar token ----------------------------------------------------------
export LOCAL_API_PORT="${LOCAL_API_PORT:-46123}"
if [ -z "${LOCAL_API_TOKEN:-}" ]; then
  LOCAL_API_TOKEN="$(node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))")"
  export LOCAL_API_TOKEN
fi

# --- Session secret ---------------------------------------------------------
# Upstream's entrypoint runs docker/validate-session-secret.mjs and exits 1 if
# WM_SESSION_SECRET is shorter than 32 chars. We WARN instead of failing so an
# existing deployment that predates the variable keeps running; set it (32+
# random chars) in the OpenShift Secret / compose .env, then feel free to make
# this fatal to match upstream.
if [ "${#WM_SESSION_SECRET}" -lt 32 ]; then
  log "WARN: WM_SESSION_SECRET is unset or shorter than 32 chars — upstream requires it; set it in your Secret/.env"
fi

# --- nginx real-IP include --------------------------------------------------
# nginx.conf `include`s /tmp/nginx-realip.conf (upstream change, ~Sep 2026).
# Upstream's entrypoint renders it from WM_TRUSTED_PROXY_CIDRS: set_real_ip_from
# + real_ip_header X-Forwarded-For when set, a comment-only file when unset.
# On OpenShift, set WM_TRUSTED_PROXY_CIDRS to the router/pod network so per-IP
# rate limits see the real client rather than the router. Must run before
# nginx starts; the file is written to /tmp, which is already writable.
node /app/render-nginx-realip.mjs

# --- nginx config -----------------------------------------------------------
# Only these two are substituted. A bare `envsubst` with no argument would
# expand every $var in the file and destroy nginx's own $remote_addr,
# $proxy_add_x_forwarded_for, $uri and friends.
envsubst '$LOCAL_API_PORT $LOCAL_API_TOKEN' \
  < /etc/nginx/nginx.conf.template \
  > /tmp/nginx.conf

# --- Start the sidecar ------------------------------------------------------
log "starting sidecar on 127.0.0.1:${LOCAL_API_PORT}"
# --require the SRH compatibility shim: the sidecar's Redis reads use a
# path-style GET that SRH does not implement (see Containerfile.ubi10).
node --require /app/srh-compat-shim.cjs /app/local-api-server.mjs &
SIDECAR_PID=$!

# Fail fast rather than letting nginx serve 502s for the pod's whole lifetime.
for _ in $(seq 1 50); do
  kill -0 "$SIDECAR_PID" 2>/dev/null || { log "sidecar exited during startup"; exit 1; }
  if node -e "
    require('node:net').connect(${LOCAL_API_PORT}, '127.0.0.1')
      .on('connect', () => process.exit(0))
      .on('error', () => process.exit(1));
  " 2>/dev/null; then
    log "sidecar is listening"
    break
  fi
  sleep 0.2
done

# --- Supervise --------------------------------------------------------------
# The shell stays PID 1 rather than exec'ing into nginx.
#
# `exec nginx` was the obvious first design and it is wrong: exec REPLACES the
# shell, discarding the trap with it, so SIGTERM reaches nginx but never the
# sidecar. The sidecar is then orphaned and only dies at the end of the grace
# period via SIGKILL — every `oc delete pod` costs 30 seconds and an unclean
# shutdown. Verified experimentally, not assumed.
#
# Staying PID 1 costs one extra process and buys correct signal forwarding
# plus reaping of both children.
log "starting nginx on :8080"
nginx -c /tmp/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

shutdown() {
  log "shutting down"
  kill -TERM "$NGINX_PID"   2>/dev/null || true
  kill -TERM "$SIDECAR_PID" 2>/dev/null || true
  # Bounded wait so a wedged child cannot outlast the pod grace period.
  for _ in $(seq 1 100); do
    kill -0 "$NGINX_PID" 2>/dev/null || kill -0 "$SIDECAR_PID" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$NGINX_PID"   2>/dev/null || true
  kill -KILL "$SIDECAR_PID" 2>/dev/null || true
}
trap 'shutdown; exit 0' TERM INT

# Wait for EITHER child. `wait -n` returns on the first to exit, so whichever
# process dies takes the container down and the pod restarts — which is the
# behavior supervisord was configured to provide, minus supervisord.
#
# `wait -n` is interrupted by a trapped signal, so the loop re-waits until a
# child actually exits or the trap calls exit.
while :; do
  if wait -n "$NGINX_PID" "$SIDECAR_PID"; then
    STATUS=0
  else
    STATUS=$?
  fi
  # 128+N means a signal interrupted the wait, not a child exiting.
  if [ "$STATUS" -gt 128 ]; then
    kill -0 "$NGINX_PID" 2>/dev/null && kill -0 "$SIDECAR_PID" 2>/dev/null && continue
  fi
  break
done

kill -0 "$NGINX_PID"   2>/dev/null || log "nginx exited (status ${STATUS})"
kill -0 "$SIDECAR_PID" 2>/dev/null || log "sidecar exited (status ${STATUS})"
shutdown
exit "${STATUS}"
