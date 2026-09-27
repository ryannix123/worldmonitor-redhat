#!/bin/bash
# =============================================================================
# World Monitor appliance installer — Fedora + rootless Podman + Quadlet
# =============================================================================
# Run ONCE, as root, from this directory, on a fresh Fedora box:
#
#   sudo ./install.sh                     # prompts for the OpenRouter key
#   sudo ./install.sh --env /path/.env    # reuse an existing podman/.env
#
# What it sets up:
#   * an unprivileged service user `wm` (rootless containers, no root daemon)
#   * the five containers as systemd user units (Quadlet), started at boot
#     with no login required (loginctl linger)
#   * podman-auto-update: nightly pull of new images with automatic rollback
#     if an updated container fails its healthcheck
#   * dnf-automatic for OS security updates + a weekly reboot window
#   * firewall: port 3000/tcp (dashboard) + mDNS (so http://wm-armory.local works)
#
# Re-running is safe: every step is idempotent.
# =============================================================================
set -euo pipefail

WM_USER=wm
HOSTNAME_NEW=wm-armory
TZ_NEW=America/Indiana/Indianapolis
ENV_SRC=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_SRC="$2"; shift 2 ;;
    --user) WM_USER="$2"; shift 2 ;;
    --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
    --tz) TZ_NEW="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh)"
grep -qi fedora /etc/os-release || die "this installer targets Fedora"
for f in quadlet/worldmonitor.container quadlet/redis.container seed-loop.sh env.example \
         systemd/podman-auto-update.timer.override.conf systemd/wm-weekly-reboot.timer; do
  [ -f "$HERE/$f" ] || die "missing $f — run from the nuc/ directory"
done

# ---- 1. packages ------------------------------------------------------------
log "Installing packages"
dnf install -y -q podman openssl curl avahi >/dev/null
# dnf5 (Fedora 41+) ships the automatic plugin under a new name; older is dnf-automatic.
dnf install -y -q dnf5-plugin-automatic >/dev/null 2>&1 || dnf install -y -q dnf-automatic >/dev/null
PODMAN_VER="$(podman --version | awk '{print $3}')"
[ "${PODMAN_VER%%.*}" -ge 5 ] || warn "podman $PODMAN_VER — Quadlet Notify=healthy needs >= 4.9; Fedora 40+ is fine"

# ---- 2. host identity -------------------------------------------------------
log "Hostname → $HOSTNAME_NEW, timezone → $TZ_NEW"
hostnamectl set-hostname "$HOSTNAME_NEW"
timedatectl set-timezone "$TZ_NEW"
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true

# ---- 3. service user ---------------------------------------------------------
if ! id "$WM_USER" >/dev/null 2>&1; then
  log "Creating service user $WM_USER"
  useradd -m -s /bin/bash "$WM_USER"
fi
WM_UID="$(id -u "$WM_USER")"
WM_HOME="$(getent passwd "$WM_USER" | cut -d: -f6)"
loginctl enable-linger "$WM_USER"
# The user's systemd instance starts with linger; wait for its bus.
for _ in $(seq 1 30); do [ -S "/run/user/$WM_UID/bus" ] && break; sleep 1; done
[ -S "/run/user/$WM_UID/bus" ] || die "user manager for $WM_USER did not start"
as_wm() { runuser -u "$WM_USER" -- env XDG_RUNTIME_DIR="/run/user/$WM_UID" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WM_UID/bus" "$@"; }

# ---- 4. firewall ------------------------------------------------------------
if systemctl is-active -q firewalld; then
  log "Opening 3000/tcp and mDNS in firewalld"
  firewall-cmd -q --permanent --add-port=3000/tcp
  firewall-cmd -q --permanent --add-service=mdns
  firewall-cmd -q --reload
fi

# ---- 5. files ---------------------------------------------------------------
CFG="$WM_HOME/.config/worldmonitor"
QDIR="$WM_HOME/.config/containers/systemd"
UDIR="$WM_HOME/.config/systemd/user"
log "Installing Quadlet units → $QDIR"
install -d -o "$WM_USER" -g "$WM_USER" -m 700 "$CFG" "$WM_HOME/.config/containers" "$QDIR" \
        "$UDIR/podman-auto-update.timer.d"
install -o "$WM_USER" -g "$WM_USER" -m 644 "$HERE"/quadlet/* "$QDIR/"
install -o "$WM_USER" -g "$WM_USER" -m 755 "$HERE/seed-loop.sh" "$CFG/seed-loop.sh"
install -o "$WM_USER" -g "$WM_USER" -m 644 "$HERE/systemd/podman-auto-update.timer.override.conf" \
        "$UDIR/podman-auto-update.timer.d/override.conf"

# ---- 6. secrets / keys -------------------------------------------------------
ENV_FILE="$CFG/.env"
if [ -n "$ENV_SRC" ]; then
  [ -f "$ENV_SRC" ] || die "--env file not found: $ENV_SRC"
  log "Using existing env file $ENV_SRC"
  install -o "$WM_USER" -g "$WM_USER" -m 600 "$ENV_SRC" "$ENV_FILE"
elif [ ! -f "$ENV_FILE" ]; then
  log "Creating $ENV_FILE"
  install -o "$WM_USER" -g "$WM_USER" -m 600 "$HERE/env.example" "$ENV_FILE"
fi
setvar() {  # setvar NAME VALUE — set or append, never duplicate
  if grep -qE "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; fi
}
getvar() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
# Generated secrets — same formats as podman/deploy.sh; only filled if empty.
[ -n "$(getvar REDIS_PASSWORD)" ]          || setvar REDIS_PASSWORD "$(openssl rand -hex 32)"
[ -n "$(getvar REDIS_TOKEN)" ]             || setvar REDIS_TOKEN "$(openssl rand -hex 32)"
[ -n "$(getvar WM_SESSION_SECRET)" ]       || setvar WM_SESSION_SECRET "$(openssl rand -hex 32)"
[ -n "$(getvar WORLDMONITOR_VALID_KEYS)" ] || setvar WORLDMONITOR_VALID_KEYS "wm_$(openssl rand -hex 24)"
[ -n "$(getvar RELAY_SHARED_SECRET)" ]     || setvar RELAY_SHARED_SECRET "$(openssl rand -hex 32)"
# Derived values (Quadlet cannot expand ${VAR} in Environment= lines).
setvar SRH_TOKEN                "$(getvar REDIS_TOKEN)"
setvar SRH_CONNECTION_STRING    "redis://:$(getvar REDIS_PASSWORD)@redis:6379"
setvar UPSTASH_REDIS_REST_TOKEN "$(getvar REDIS_TOKEN)"
setvar WORLDMONITOR_RELAY_KEY   "$(getvar RELAY_SHARED_SECRET)"
if [ -z "$(getvar OPENROUTER_API_KEY)" ]; then
  printf '\n  OpenRouter API key (for the AI briefs — use a dedicated, spend-capped key):\n  > '
  read -r key </dev/tty
  [ -n "$key" ] && setvar OPENROUTER_API_KEY "$key" || warn "no OpenRouter key — AI panels will show UNAVAILABLE until one is set in $ENV_FILE"
fi
chown "$WM_USER:$WM_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"

# ---- 7. pull + start ----------------------------------------------------------
log "Pulling images as $WM_USER (first time only — a few minutes)"
for img in quay.io/ryan_nix/worldmonitor-openshift:latest \
           quay.io/ryan_nix/worldmonitor-openshift:relay-latest \
           quay.io/ryan_nix/worldmonitor-openshift:redis-rest-latest \
           docker.io/library/redis:8-alpine; do
  as_wm podman pull -q "$img" >/dev/null
done
log "Starting the stack"
as_wm systemctl --user daemon-reload
as_wm systemctl --user start worldmonitor.service seeders.service
as_wm systemctl --user enable --now podman-auto-update.timer >/dev/null

# ---- 8. OS updates + weekly reboot -------------------------------------------
log "Enabling automatic OS updates and the Sunday 04:30 reboot window"
if [ -f /etc/dnf/automatic.conf ]; then
  sed -i 's/^apply_updates *=.*/apply_updates = yes/; s/^upgrade_type *=.*/upgrade_type = security/' /etc/dnf/automatic.conf
fi
systemctl enable --now dnf5-automatic.timer >/dev/null 2>&1 \
  || systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
  || warn "could not enable a dnf automatic timer — check 'systemctl list-timers'"
install -m 644 "$HERE/systemd/wm-weekly-reboot.service" "$HERE/systemd/wm-weekly-reboot.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now wm-weekly-reboot.timer >/dev/null

# ---- 9. report --------------------------------------------------------------
echo
log "Done. Waiting for the dashboard to answer…"
for _ in $(seq 1 60); do curl -fsS -o /dev/null http://127.0.0.1:3000/ && break; sleep 2; done
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<REPORT

  World Monitor is up.

    On this box:   http://localhost:3000
    On the LAN:    http://$HOSTNAME_NEW.local:3000   or   http://${IP:-<ip>}:3000

  Panels fill in over 2–3 minutes; market/economic panels after the first
  seed pass (~15–20 min). Status any time:

    sudo -u $WM_USER XDG_RUNTIME_DIR=/run/user/$WM_UID systemctl --user status worldmonitor ais-relay redis-rest redis seeders
    sudo -u $WM_USER XDG_RUNTIME_DIR=/run/user/$WM_UID podman auto-update --dry-run   # what tonight would pull

  Keys live in: $ENV_FILE  (edit, then: systemctl --user restart worldmonitor seeders)
  Optional wall-display mode:  sudo ./kiosk/setup-kiosk.sh
REPORT
