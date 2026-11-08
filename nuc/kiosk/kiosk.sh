#!/bin/bash
# Launched by GNOME autostart for the `wm` user. Waits for the local stack to
# answer, then opens Firefox full-screen in kiosk mode. If Firefox ever exits
# (crash, someone hits Alt-F4), it relaunches after 5s.
#
# Pinned layout: 2D global map, 24h window, the "crisis desk" layers. Edit the
# URL to change what the wall shows — build one in a normal browser, copy the
# address bar, paste it here.
KIOSK_URL='http://localhost:3000/?lat=20.0000&lon=0.0000&zoom=1.50&view=global&timeRange=24h&layers=conflicts%2Cbases%2Chotspots%2Csanctions%2Cweather%2Coutages'

# Second tab: the OpenClaw chat ("ask the wall"), only when OPENCLAW_UI=1 in
# openclaw.env. Ctrl-Tab switches between the wall and the chat. The gateway
# token is read from the env file so it never sits in this script.
OC_ENV="$HOME/.config/worldmonitor/openclaw.env"
CHAT_URL=""
if [ -f "$OC_ENV" ] && grep -qE '^OPENCLAW_UI=1' "$OC_ENV"; then
  TOKEN="$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$OC_ENV" | head -1 | cut -d= -f2-)"
  [ -n "$TOKEN" ] && CHAT_URL="http://localhost:18789/?token=$TOKEN"
fi

until curl -fsS -o /dev/null http://127.0.0.1:3000/; do sleep 3; done
sleep 5   # let the first panels populate before the screen lights up
while true; do
  # shellcheck disable=SC2086
  firefox --kiosk --no-remote --profile "$HOME/.wm-kiosk-profile" "$KIOSK_URL" $CHAT_URL
  sleep 5
done
