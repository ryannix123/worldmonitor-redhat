#!/bin/bash
# =============================================================================
# Optional: turn the appliance into a wall display (Fedora Workstation / GNOME)
# =============================================================================
# Run as root AFTER install.sh:   sudo ./kiosk/setup-kiosk.sh
#
#   * GDM auto-logs-in the `wm` user at boot
#   * Firefox opens full-screen in kiosk mode on the dashboard
#   * screen blanking, lock, and sleep are disabled
#   * Firefox first-run pages, telemetry, and update nags are disabled by policy
#
# Requires a GNOME session (Fedora Workstation). On Fedora Server, install one
# first: dnf group install -y "Workstation" && systemctl set-default graphical.
# =============================================================================
set -euo pipefail
WM_USER="${WM_USER:-wm}"
WM_HOME="$(getent passwd "$WM_USER" | cut -d: -f6)"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -n "$WM_HOME" ] || { echo "user $WM_USER not found — run install.sh first"; exit 1; }
command -v gdm >/dev/null 2>&1 || [ -d /etc/gdm ] || { echo "GDM not found — this needs Fedora Workstation (GNOME)"; exit 1; }

dnf install -y -q firefox >/dev/null

# --- GDM autologin ------------------------------------------------------------
python3 - "$WM_USER" <<'PY'
import configparser, sys, pathlib
p = pathlib.Path('/etc/gdm/custom.conf'); c = configparser.ConfigParser(); c.optionxform = str
if p.exists(): c.read(p)
if not c.has_section('daemon'): c.add_section('daemon')
c['daemon']['AutomaticLoginEnable'] = 'True'
c['daemon']['AutomaticLogin'] = sys.argv[1]
c['daemon']['InitialSetupEnable'] = 'False'
with p.open('w') as f: c.write(f)
PY

# --- Firefox policies: no first-run page, no telemetry, no update prompts -------
install -d -m 755 /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<'JSON'
{ "policies": {
    "OverrideFirstRunPage": "", "OverridePostUpdatePage": "",
    "DisableTelemetry": true, "DontCheckDefaultBrowser": true,
    "DisableAppUpdate": true, "NoDefaultBookmarks": true,
    "DisableFirefoxStudies": true, "PromptForDownloadLocation": false
} }
JSON

# --- kiosk launcher -----------------------------------------------------------
CFG="$WM_HOME/.config/worldmonitor"
install -d -o "$WM_USER" -g "$WM_USER" -m 700 "$CFG" "$WM_HOME/.config/autostart"
install -o "$WM_USER" -g "$WM_USER" -m 755 "$(dirname "$0")/kiosk.sh" "$CFG/kiosk.sh"
cat > "$WM_HOME/.config/autostart/worldmonitor-kiosk.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=World Monitor kiosk
Exec=$CFG/kiosk.sh
X-GNOME-Autostart-enabled=true
DESK
chown "$WM_USER:$WM_USER" "$WM_HOME/.config/autostart/worldmonitor-kiosk.desktop"

# --- never blank, never lock, never sleep --------------------------------------
runuser -u "$WM_USER" -- dbus-run-session -- sh -c '
  gsettings set org.gnome.desktop.session idle-delay 0
  gsettings set org.gnome.desktop.screensaver lock-enabled false
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
  gsettings set org.gnome.settings-daemon.plugins.power power-button-action "nothing"
'
systemctl set-default graphical.target >/dev/null
echo
echo "Kiosk configured. Reboot to start it:  sudo systemctl reboot"
echo "Change the dashboard layout in:        $CFG/kiosk.sh  (KIOSK_URL)"
