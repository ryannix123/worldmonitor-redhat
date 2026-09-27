#!/usr/bin/env bash
# =============================================================================
# World Monitor — one-command local runner for Apple Silicon
#
#   ./deploy.sh          first run prompts for keys, writes .env, starts the app
#                        later runs just start it
#   ./deploy.sh -stop    stop the app (your data is kept)
#   ./deploy.sh -reset    re-enter all the keys from scratch
#
# Open http://localhost:3000 once it's up.
# =============================================================================
set -euo pipefail

# Always run from the folder this script lives in, so paths work no matter
# where it's called from.
cd "$(dirname "$0")"

COMPOSE_FILE="compose.local.yml"
ENV_FILE=".env"
URL="http://localhost:3000"

# ---- pretty output ----------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }

# ---- preflight: is podman here and running? ---------------------------------
require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    warn "Podman isn't installed."
    info "Install it with:  brew install podman podman-compose"
    exit 1
  fi
  # Is the Podman machine running? (macOS runs containers in a small Linux VM.)
  if ! podman info >/dev/null 2>&1; then
    warn "Podman's engine isn't running. Starting it..."
    podman machine start 2>/dev/null || {
      warn "Couldn't start automatically. Run these once, then try again:"
      info "  podman machine init      (first time only)"
      info "  podman machine start"
      exit 1
    }
    ok "Podman engine started."
  fi
}

# ---- pick whichever compose engine is installed -----------------------------
# `podman compose` shells out to an external provider. podman-compose and
# docker-compose both satisfy it — either works.
compose() {
  podman compose -f "$COMPOSE_FILE" "$@"
}

# ---- which upstream commit is each image built from? ------------------------
# Every image carries org.opencontainers.image.revision = the koala73/worldmonitor
# commit it was built from. Printing it is the only reliable way to see whether
# `latest`, `relay-latest` and `redis-rest-latest` actually moved together —
# the tag names never change, so a stale one is invisible otherwise.
REPO_IMG="quay.io/ryan_nix/worldmonitor-openshift"
show_versions() {
  local tag rev
  for tag in latest relay-latest redis-rest-latest; do
    rev="$(podman image inspect "${REPO_IMG}:${tag}" \
            --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
    if [[ -n "$rev" ]]; then printf "  %-18s %s\n" "$tag" "${rev:0:12}"; else printf "  %-18s %s\n" "$tag" "not pulled yet"; fi
  done
}

# ---- prompt for a key, keeping any existing value ---------------------------
# Args: VAR_NAME  "human description"  required|optional
ask_key() {
  local var="$1" desc="$2" mode="$3" current="" val=""
  current="$(grep -E "^${var}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -n "$current" ]]; then
    return 0   # already set, leave it
  fi
  if [[ "$mode" == "optional" ]]; then
    printf "  %s (optional, press Enter to skip):\n  > " "$desc"
  else
    printf "  %s:\n  > " "$desc"
  fi
  read -r val
  # Escape any & and | so sed doesn't choke on pasted keys.
  val="$(printf '%s' "$val" | sed 's/[&|]/\\&/g')"
  if grep -qE "^${var}=" "$ENV_FILE"; then
    sed -i '' "s|^${var}=.*|${var}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$var" "$val" >> "$ENV_FILE"
  fi
}

# ---- build .env if it doesn't exist -----------------------------------------
setup_env() {
  if [[ -f "$ENV_FILE" ]] && grep -qE '^OPENROUTER_API_KEY=.+' "$ENV_FILE"; then
    ok "Keys already saved (.env). Delete it or run ./deploy.sh -reset to redo."
    return 0
  fi

  bold "First-time setup — let's save your keys."
  echo
  : > "$ENV_FILE"   # start fresh
  chmod 600 "$ENV_FILE"

  # Redis secrets + browser-session secrets: generated, never typed.
  {
    echo "REDIS_PASSWORD=$(openssl rand -hex 32)"
    echo "REDIS_TOKEN=$(openssl rand -hex 32)"
    echo "WM_SESSION_SECRET=$(openssl rand -hex 32)"
    echo "WORLDMONITOR_VALID_KEYS=wm_$(openssl rand -hex 24)"
    echo "RELAY_SHARED_SECRET=$(openssl rand -hex 32)"
  } >> "$ENV_FILE"
  ok "Generated the internal cache + session secrets (you don't need to know them)."
  echo

  info "Paste each key and press Enter. Paste each one when prompted."
  echo
  ask_key OPENROUTER_API_KEY "OpenRouter key (for the AI briefs)"  required
  ask_key UCDP_ACCESS_TOKEN  "UCDP token (armed-conflict data)"    optional
  ask_key AISSTREAM_API_KEY  "AISStream key (live ships)"          optional
  ask_key ACLED_EMAIL        "ACLED email"                         optional
  ask_key ACLED_PASSWORD     "ACLED password"                      optional
  ask_key FINNHUB_API_KEY    "Finnhub key (market data)"           optional
  ask_key FRED_API_KEY       "FRED key (economic data)"            optional
  ask_key GROQ_API_KEY       "Groq key (fast inference)"           optional
  echo
  ok "Saved to .env"
}

# ---- commands ---------------------------------------------------------------
do_start() {
  require_podman
  setup_env
  echo
  bold "Starting World Monitor..."
  info "First run downloads the containers — a few minutes. Then it's cached."
  compose up -d
  echo
  ok "Up. Open:  $URL"
  info "It fills in over 2–3 minutes as the data feeds catch up."
  info "Stop it later with:  ./deploy.sh -stop"
}

do_stop() {
  require_podman
  bold "Stopping World Monitor..."
  compose down
  ok "Stopped. Your data is kept. Start again with:  ./deploy.sh"
}

do_reset() {
  warn "This clears your saved keys and asks for them again."
  printf "  Continue? [y/N] "
  read -r yn
  case "$yn" in
    [Yy]*) rm -f "$ENV_FILE"; ok "Cleared. Run ./deploy.sh to set up again." ;;
    *)     info "Left everything as-is." ;;
  esac
}

do_update() {
  require_podman
  bold "Checking for a newer World Monitor build..."
  info "Before:"; show_versions
  info "Pulling the latest images from Quay (this is where nightly builds land)."
  # NOT `compose pull`: the docker-compose provider honours pull_policy: missing
  # and reports "Skipped — image is already present locally" for any tag that
  # exists on this machine, so a moved `latest` was never re-fetched (seen
  # 2026-09-27: relay-latest and redis-rest-latest stayed weeks stale while
  # `-update` reported success). `podman pull` always compares digests.
  local img
  for img in $(grep -E '^\s*image:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"' | sort -u); do
    podman pull -q "$img" >/dev/null && ok "pulled $img" || warn "could not pull $img (keeping the local copy)"
  done
  echo
  bold "Restarting onto the updated images..."
  compose up -d
  echo
  info "After:"; show_versions
  ok "Updated and running.  $URL"
  info "Seeder-fed panels refresh on the next hourly pass (or restart 'seeders' to run one now)."
  info "If something looks off after an update, the project is young and still"
  info "settling — you can keep running the version you had; updates are only"
  info "pulled when you run ./deploy.sh -update."
}

do_version() {
  require_podman
  bold "Image versions (upstream commit each was built from)"
  show_versions
  local a r
  a="$(podman image inspect "${REPO_IMG}:latest" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
  r="$(podman image inspect "${REPO_IMG}:relay-latest" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
  if [[ -n "$a" && -n "$r" && "$a" != "$r" ]]; then
    warn "app and relay images are from different upstream commits — run ./deploy.sh -update"
  fi
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
  ""|-start|start)   do_start   ;;
  -stop|stop)        do_stop    ;;
  -update|update)    do_update  ;;
  -version|version)  do_version ;;
  -reset|reset)      do_reset   ;;
  -h|--help|help)
    bold "World Monitor"
    info "./deploy.sh          start it (prompts for keys the first time)"
    info "./deploy.sh -update  pull the latest build, then restart"
    info "./deploy.sh -version show which upstream commit each image is built from"
    info "./deploy.sh -stop    stop it"
    info "./deploy.sh -reset   re-enter your keys"
    ;;
  *)
    warn "Don't know '$1'."
    info "Try:  ./deploy.sh   or   ./deploy.sh -update   or   ./deploy.sh -stop"
    exit 1 ;;
esac
