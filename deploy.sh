#!/usr/bin/env bash
# =============================================================================
# World Monitor — deploy / teardown
# =============================================================================
# Default: generate secrets, apply the overlay, build if needed, wait.
# With -d: tear down everything the overlay created (see --keep-secrets).
# Idempotent — re-running deploy will not clobber existing secrets.
# =============================================================================
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options]

  -e KEY=VALUE     Set an API key. Repeatable.
                   e.g. -e OPENROUTER_API_KEY=sk-or-v1-... -e GROQ_API_KEY=gsk_...
  -E KEY           Read the value for KEY from stdin (prompt, no echo).
                   Safer than -e: nothing lands in shell history or `ps`.
  -o OVERLAY       Overlay path (default: overlays/sno).
  -d               Delete (tear down) what the overlay created, then exit.
                   Prompts for confirmation unless --yes is given.
      --keep-secrets   With -d, keep the generated secrets (Redis creds, relay
                       secret, API keys). Recommended — regenerating Redis
                       credentials causes a password mismatch on next deploy.
      --yes            Skip the confirmation prompt (for scripted teardown).
  -h               This help.

Environment:
  OVERLAY          Same as -o.
  MODEL            Ollama model to pull on SNO (default: llama3.2:3b).

Notes on -e:
  A value passed with -e is visible in your shell history and in `ps` output
  while the script runs. For a personal homelab that is usually fine. For a
  shared box or a screen-shared demo, prefer -E, or prefix the command with a
  space if your shell has HISTCONTROL=ignorespace.

Examples:
  ./deploy.sh -o overlays/sandbox -E OPENROUTER_API_KEY
  ./deploy.sh -o overlays/sandbox -e OPENROUTER_API_KEY=sk-or-v1-...
  ./deploy.sh -o overlays/sandbox-quay -d --keep-secrets   # tear down, keep creds
  ./deploy.sh -o overlays/sandbox-quay -d --yes            # tear down everything
USAGE
}

declare -a CLI_KEYS=()
DO_DELETE=false
KEEP_SECRETS=false
ASSUME_YES=false

# getopts handles only short options; pull the long ones out of argv first.
declare -a ARGV=()
for a in "$@"; do
  case "$a" in
    --keep-secrets) KEEP_SECRETS=true ;;
    --yes)          ASSUME_YES=true ;;
    *)              ARGV+=("$a") ;;
  esac
done
set -- "${ARGV[@]}"

while getopts ":e:E:o:dh" opt; do
  case "$opt" in
    e)
      [[ "$OPTARG" == *=* ]] || { echo "-e expects KEY=VALUE, got: $OPTARG"; exit 1; }
      CLI_KEYS+=("$OPTARG")
      ;;
    E)
      [[ "$OPTARG" == *=* ]] && { echo "-E expects just KEY (no =VALUE)"; exit 1; }
      # Prefer /dev/tty so the prompt works even when the script is piped.
      # With no controlling terminal (CI, `sh deploy.sh < /dev/null`) fall back
      # to plain stdin so this degrades to a readable error instead of a crash.
      # `[[ -r /dev/tty ]]` is true even where opening it fails (containers with
      # no controlling terminal), so probe with an actual write.
      if { : > /dev/tty; } 2>/dev/null; then
        printf 'Value for %s: ' "$OPTARG" > /dev/tty
        IFS= read -rs _val < /dev/tty
        printf '\n' > /dev/tty
      else
        IFS= read -rs _val || true
      fi
      [[ -n "${_val:-}" ]] || {
        echo "No value read for $OPTARG. With no terminal available, pipe it in:"
        echo "  echo 'sk-or-v1-...' | ./deploy.sh -E $OPTARG"
        exit 1
      }
      CLI_KEYS+=("${OPTARG}=${_val}")
      unset _val
      ;;
    o) OVERLAY="$OPTARG" ;;
    d) DO_DELETE=true ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
    :) echo "-$OPTARG requires an argument"; usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# Overlay selects the target profile. Namespace is whatever `oc` is already
# pointed at — nothing here creates or switches namespaces, so this works
# identically on a self-managed cluster and on Developer Sandbox.
OVERLAY="${OVERLAY:-overlays/sno}"
SECRETS="${OVERLAY}/secrets"

info() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }

command -v oc >/dev/null || { echo "oc not found in PATH"; exit 1; }
oc whoami >/dev/null || { echo "Not logged in. Run: oc login ..."; exit 1; }

NS="$(oc project -q)"
[[ -d "$OVERLAY" ]] || { echo "No such overlay: $OVERLAY"; exit 1; }

# --- Teardown (-d) -----------------------------------------------------------
if [[ "$DO_DELETE" == true ]]; then
  echo "About to delete everything the overlay '$OVERLAY' created in namespace"
  echo "'$NS':"
  echo
  # Show exactly what will go. `oc delete -k --dry-run` lists the targeted
  # objects without touching them — no surprises.
  oc delete -k "$OVERLAY" --dry-run=client 2>/dev/null \
    | sed 's/^/  would delete: /' || true
  echo

  if [[ "$KEEP_SECRETS" == true ]]; then
    echo "Secrets will be KEPT (--keep-secrets)."
  else
    echo "Secrets WILL be deleted. Re-deploying will generate NEW Redis"
    echo "credentials — fine for a fresh start, but any kept PVC data becomes"
    echo "unreadable. Use --keep-secrets to avoid this."
  fi
  echo

  if [[ "$ASSUME_YES" != true ]]; then
    if { : > /dev/tty; } 2>/dev/null; then
      printf 'Type the namespace name (%s) to confirm: ' "$NS" > /dev/tty
      IFS= read -r _confirm < /dev/tty
    else
      IFS= read -r _confirm || true
    fi
    [[ "${_confirm:-}" == "$NS" ]] || { echo "Confirmation did not match. Aborted."; exit 1; }
    unset _confirm
  fi

  # `oc delete -k` removes only the objects the kustomization declares — not
  # other things sharing the namespace. Secrets are generated objects, so they
  # are part of that set; to keep them, delete everything else by label instead.
  if [[ "$KEEP_SECRETS" == true ]]; then
    # secretGenerator output does NOT carry the base's part-of label (the label
    # transformer runs on base resources, not overlay-generated ones), so a
    # label-scoped delete of everything-but-secrets naturally leaves them alone.
    # Delete each concrete kind the overlay creates, excluding Secret.
    oc delete deployment,service,route,configmap,pvc,networkpolicy \
      -l app.kubernetes.io/part-of=worldmonitor -n "$NS" --ignore-not-found
    KEPT="$(oc get secret worldmonitor-redis worldmonitor-relay worldmonitor-apikeys \
             -n "$NS" -o name 2>/dev/null | wc -l | tr -d ' ')"
    echo "Kept ${KEPT} secret(s)."
  else
    oc delete -k "$OVERLAY" --ignore-not-found
  fi

  echo
  echo "Teardown complete. Remaining worldmonitor objects (should be empty or"
  echo "secrets-only):"
  oc get all,pvc,secret,configmap -l app.kubernetes.io/part-of=worldmonitor -n "$NS" 2>/dev/null || true
  exit 0
fi

# --- Secrets -----------------------------------------------------------------
mkdir -p "$SECRETS"

if [[ -f "${SECRETS}/redis.env" ]] && ! grep -q REPLACE_ME "${SECRETS}/redis.env"; then
  info "Redis secrets already generated"
else
  info "Generating Redis secrets"
  RP="$(openssl rand -hex 32)"
  RT="$(openssl rand -hex 32)"
  cat > "${SECRETS}/redis.env" <<EOF
REDIS_PASSWORD=${RP}
REDIS_TOKEN=${RT}
SRH_CONNECTION_STRING=redis://:${RP}@redis:6379
EOF
fi

# Generated internal secrets. Each is APPENDED only if absent, rather than
# treating the file as all-or-nothing: an existing relay.env from an older
# revision would otherwise be left untouched and any newly-required key would
# be missing from the Secret, so the app pod fails with
# CreateContainerConfigError on an unresolvable secretKeyRef.
touch "${SECRETS}/relay.env"
[[ -s "${SECRETS}/relay.env" ]] && grep -q REPLACE_ME "${SECRETS}/relay.env" && : > "${SECRETS}/relay.env"

ensure_secret() {   # ensure_secret KEY VALUE DESCRIPTION
  local key="$1" val="$2" desc="$3"
  if grep -qE "^${key}=..*" "${SECRETS}/relay.env" 2>/dev/null; then
    return 0
  fi
  # Drop any empty-valued line for this key, then append a real one.
  if [[ -s "${SECRETS}/relay.env" ]]; then
    grep -vE "^${key}=" "${SECRETS}/relay.env" > "${SECRETS}/relay.env.tmp" || true
    mv "${SECRETS}/relay.env.tmp" "${SECRETS}/relay.env"
  fi
  printf '%s=%s\n' "$key" "$val" >> "${SECRETS}/relay.env"
  info "Generated ${key} (${desc})"
}

# Relay <-> app shared secret for the relay's own auth header.
ensure_secret RELAY_SHARED_SECRET "$(openssl rand -hex 32)" "relay auth"
# Dedicated relay->app warm-ping key. The app allowlists it via
# WORLDMONITOR_VALID_KEYS; the relay presents it as X-WorldMonitor-Key.
# wm_ prefix matches upstream's documented generation format.
ensure_secret WORLDMONITOR_RELAY_KEY "wm_$(openssl rand -hex 24)" "warm-ping key"
# Signs the lightweight wm-session cookie. Without it the app cannot issue a
# browser session, so key-gated panels (Country Instability, cable health)
# return 401 "API key required" to the browser and render as UNAVAILABLE.
ensure_secret WM_SESSION_SECRET "$(openssl rand -hex 32)" "browser session signing"

# Provider keys are optional — every feature degrades gracefully without them.
#
# IMPORTANT: secrets/ is gitignored, so it exists only locally and is wiped by
# anything that re-extracts the repo. Creating a blank apikeys.env here and
# applying it would silently overwrite populated keys already in the cluster —
# which is exactly how a working deployment loses its credentials and the relay
# starts CrashLoopBackOff'ing on a missing AISSTREAM_API_KEY.
#
# So when the local file is absent, hydrate it from the live Secret first.
if [[ ! -f "${SECRETS}/apikeys.env" ]]; then
  if oc get secret worldmonitor-apikeys -n "$NS" >/dev/null 2>&1; then
    info "apikeys.env missing locally — restoring from the cluster Secret"
    # Reconstruct KEY=VALUE lines from the existing Secret so nothing is lost.
    oc get secret worldmonitor-apikeys -n "$NS" -o json \
      | python3 -c "
import base64, json, sys
data = json.load(sys.stdin).get('data', {}) or {}
for k in sorted(data):
    try: v = base64.b64decode(data[k]).decode()
    except Exception: v = ''
    print(f'{k}={v}')
" > "${SECRETS}/apikeys.env"
    RESTORED="$(grep -c '=..*' "${SECRETS}/apikeys.env" 2>/dev/null || echo 0)"
    info "restored ${RESTORED} populated key(s) from the cluster"
  else
    cat > "${SECRETS}/apikeys.env" <<'EOF'
# Optional. Each key enables one feature; the dashboard runs without any of them.
GROQ_API_KEY=
FINNHUB_API_KEY=
FRED_API_KEY=
EIA_API_KEY=
NASA_FIRMS_API_KEY=
AISSTREAM_API_KEY=
ACLED_EMAIL=
ACLED_PASSWORD=
EOF
  fi
fi

# Merge any -e / -E keys into apikeys.env. Existing keys are replaced in place
# rather than appended, so the file stays readable after repeated runs.
# Values are passed to python via argv, never interpolated into a shell string —
# an API key containing /, &, quotes, or spaces is handled correctly.
if (( ${#CLI_KEYS[@]} > 0 )); then
  for kv in "${CLI_KEYS[@]}"; do
    python3 - "${kv%%=*}" "${kv#*=}" "${SECRETS}/apikeys.env" <<'PY'
import os, re, sys
key, val, path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines() if os.path.exists(path) else []
pat = re.compile(rf"^{re.escape(key)}=")
if any(pat.match(ln) for ln in lines):
    lines = [f"{key}={val}" if pat.match(ln) else ln for ln in lines]
else:
    lines.append(f"{key}={val}")
open(path, "w").write("\n".join(lines) + "\n")
PY
    info "Set ${kv%%=*}"
  done
  unset CLI_KEYS kv
fi

chmod 600 "${SECRETS}"/*.env

info "Deploying into namespace: $NS"

# --- Preflight: PVC size conflicts -------------------------------------------
# PVC storage requests are immutable downward. Switching from the SNO overlay
# (2Gi) to the sandbox overlay (1Gi) makes `oc apply` fail with:
#   spec.resources.requests.storage: Forbidden: field can not be less than
#   status.capacity
# Detect it and say what to do rather than letting the apply die mid-way.
WANT="$(${KUSTOMIZE:-oc kustomize} "$OVERLAY" 2>/dev/null \
  | awk '/^kind: PersistentVolumeClaim/{p=1} p&&/name: redis-data/{f=1} f&&/storage:/{print $2; exit}')"
HAVE="$(oc get pvc redis-data -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true)"

if [[ -n "$HAVE" && -n "$WANT" && "$HAVE" != "$WANT" ]]; then
  # Compare as bytes so 1Gi vs 1024Mi does not read as a conflict.
  to_bytes() { python3 -c "
import sys,re
v=sys.argv[1]; m=re.match(r'^(\d+)([EPTGMK]i?)?$',v)
u={'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}
print(int(m.group(1))*u.get(m.group(2) or '',1))" "$1"; }
  if (( $(to_bytes "$WANT") < $(to_bytes "$HAVE") )); then
    cat >&2 <<MSG

  PVC size conflict: redis-data exists at ${HAVE}, this overlay wants ${WANT}.
  Kubernetes cannot shrink a bound PVC, so the apply would fail.

  Redis is a cache here — nothing is lost by recreating it:

      oc delete deploy/redis --ignore-not-found
      oc delete pvc redis-data
      $0 $*

  Or keep the existing volume by removing the PersistentVolumeClaim block
  from ${OVERLAY}/patch-resources.yaml.

MSG
    exit 1
  fi
fi

# --- Apply -------------------------------------------------------------------
info "Applying manifests"
oc apply -k "$OVERLAY"

# --- Build -------------------------------------------------------------------
# The frontend build is the long pole: npm ci on the full graph, then
# build-handlers, two corpus builders, tsc, and Vite. Expect 15-25 min on SNO.
# Builds run sequentially when the namespace is tight on CPU — two concurrent
# builds will simply queue, and the parallel form makes failures harder to read.
# A re-run while an earlier build is still going leaves redundant builds queued
# behind it, each rebuilding the same commit. Cancel them first.
RUNNING="$(oc get builds -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
PENDING="$(oc get builds -o jsonpath='{range .items[?(@.status.phase=="New")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
STALE="$(printf '%s\n%s\n' "$RUNNING" "$PENDING" | grep -v '^$' || true)"
if [[ -n "$STALE" ]]; then
  info "Cancelling in-flight builds: $(echo $STALE | tr '\n' ' ')"
  # shellcheck disable=SC2086
  oc cancel-build $STALE >/dev/null 2>&1 || true
fi

# Overlays that deploy a prebuilt image (e.g. sandbox-quay) have no
# BuildConfig. Only build when one exists; otherwise the deployment just pulls
# from the external registry.
if oc -n "$NS" get bc/worldmonitor >/dev/null 2>&1; then
  info "Starting app build (this takes a while — the Vite build is heavy)"
  oc -n "$NS" start-build worldmonitor --wait \
    || { echo "App build failed. Logs: oc -n $NS logs -f bc/worldmonitor"; exit 1; }
else
  info "No BuildConfig — using prebuilt image from the registry"
fi

if oc -n "$NS" get bc/worldmonitor-ais-relay >/dev/null 2>&1 \
   && [[ "$(oc -n "$NS" get deploy/ais-relay -o jsonpath='{.spec.replicas}' 2>/dev/null)" != "0" ]]; then
  info "Starting relay build"
  oc -n "$NS" start-build worldmonitor-ais-relay --wait \
    || { echo "Relay build failed. Logs: oc -n $NS logs -f bc/worldmonitor-ais-relay"; exit 1; }
else
  info "Skipping relay build (relay scaled to 0)"
fi

# --- Wait --------------------------------------------------------------------
info "Waiting for rollouts"
for d in redis redis-rest ollama ais-relay worldmonitor; do
  oc -n "$NS" get "deploy/$d" >/dev/null 2>&1 || continue
  # A deployment scaled to 0 (ais-relay in the sandbox overlay) never reports
  # a completed rollout, so treat it as done.
  if [[ "$(oc -n "$NS" get deploy/"$d" -o jsonpath='{.spec.replicas}')" == "0" ]]; then
    info "Skipping $d (scaled to 0)"
    continue
  fi
  oc -n "$NS" rollout status "deploy/$d" --timeout=15m
done

ROUTE="$(oc -n "$NS" get route worldmonitor -o jsonpath='{.spec.host}')"
info "Deployed: https://${ROUTE}"

# --- Pull a model (SNO overlay only) -----------------------------------------
if oc -n "$NS" get deploy/ollama >/dev/null 2>&1; then
  MODEL="${MODEL:-llama3.2:3b}"
  info "Pulling ${MODEL} into Ollama"
  OLLAMA_POD="$(oc -n "$NS" get pod -l app.kubernetes.io/name=ollama -o name | head -1)"
  oc -n "$NS" exec "$OLLAMA_POD" -- ollama pull "$MODEL"
fi

# --- Kick off an initial seed ------------------------------------------------
# The seeder CronJob only fires on its schedule (17 * * * *), so a fresh deploy
# sits with an empty Redis cache until the top of the next hour — every seeded
# panel reads "No data / Retrying" until then. Trigger one immediate run so the
# dashboard populates within minutes of deploy instead of within an hour.
#
# Fire-and-forget: the full pass is ~20 min (150+ sequential seeders). We do NOT
# --wait — the deploy is done once the app is up; seeding fills panels in the
# background. Named with a timestamp so repeated deploys never collide on an
# existing Job object (Jobs are immutable; a fixed name would fail on re-run).
# Only runs after the rollout wait above, so the app API the seeders call
# (WM_API_BASE_URL) is live before they start.
if oc -n "$NS" get cronjob/worldmonitor-seeders >/dev/null 2>&1; then
  SEED_JOB="seeders-init-$(date +%Y%m%d-%H%M%S)"
  if oc -n "$NS" create job --from=cronjob/worldmonitor-seeders "$SEED_JOB" >/dev/null 2>&1; then
    info "Started initial seed job ${SEED_JOB} (background, ~20 min to fully populate)"
    info "  watch:  oc logs -f job/${SEED_JOB} | grep '→ seed-'"
  else
    info "Could not start seed job — panels will populate at the next cron tick (:17)"
  fi
else
  info "No seeder CronJob in this overlay — skipping initial seed"
fi

info "Done."
