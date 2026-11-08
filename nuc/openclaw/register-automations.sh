#!/bin/bash
# Register (add-or-edit by name) the agent's scheduled jobs against the running
# gateway, and prune jobs we used to manage that are no longer declared.
# Port of the "Register automations" task in ryannix123/openclaw-on-openshift's
# playbook: same CLI, same "[managed]" display-name marker, same JS.
#
# Runs as a user oneshot after openclaw.service (see openclaw-automations.service).
# Jobs persist in the openclaw-config volume, so this is idempotent and cheap.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TZ_LOCAL="${WM_TZ:-America/Indiana/Indianapolis}"   # West Lafayette

# Wait for the gateway CLI (up to 2 minutes; the unit already waited for health).
for i in $(seq 1 60); do
  podman exec openclaw node dist/index.js automations list >/dev/null 2>&1 && break
  sleep 2
  [ "$i" = 60 ] && { echo "gateway not ready for CLI after 120s" >&2; exit 1; }
done

# The spec: one job today. The prompt file is the same one the OpenShift
# deployment uses; edit it there and copy, or edit here for the Armory only.
SPEC="$(python3 - "$HERE/wm-hourly-sitrep.txt" "$TZ_LOCAL" <<'PY'
import json, sys
prompt = open(sys.argv[1], encoding="utf-8").read().strip()
print(json.dumps({
  "wm-hourly-sitrep": {
    "schedule": "7 * * * *",      # :07 — after World Monitor's own hourly seed pass starts, not on it
    "tz": sys.argv[2],
    "timeout_seconds": 600,
    "prompt": prompt,
    "delivery": {}                # no channel: the SITREP lands in the workspace + the Control UI history
  }
}))
PY
)"

printf '%s' "$SPEC" | podman exec -i openclaw node - <<'JS'
const { execFileSync } = require("child_process");
const spec  = JSON.parse(require("fs").readFileSync(0, "utf8"));
const prune = true;
const cli   = (...a) => execFileSync("node", ["dist/index.js", "automations", ...a], { encoding: "utf8" });
let existing = [];
try { const r = JSON.parse(cli("list", "--all", "--json")); existing = Array.isArray(r) ? r : (r.jobs || []); } catch (e) { existing = []; }
const byName = Object.fromEntries(existing.map(j => [j.name, j]));
const MARK = "[managed]";
for (const [name, j] of Object.entries(spec)) {
  const args = ["--name", name, "--display-name", `${name} ${MARK}`, "--cron", j.schedule];
  if (j.tz) args.push("--tz", j.tz);
  if (j.model) args.push("--model", j.model);
  if (j.timeout_seconds != null) args.push("--timeout-seconds", String(j.timeout_seconds));
  const d = j.delivery || {};
  if (d.webhook) args.push("--webhook", d.webhook);
  else if (d.channel) { args.push("--announce", "--channel", d.channel); if (d.to) args.push("--to", String(d.to)); }
  else args.push("--no-deliver");
  if (byName[name]) { cli("edit", byName[name].id, ...args, "--message", j.prompt); console.log("EDITED " + name); }
  else              { cli("add", ...args, "--message", j.prompt);                   console.log("ADDED " + name); }
}
if (prune) for (const j of existing) {
  const label = j.displayName || j.display_name || "";
  if (label.endsWith(MARK) && !spec[j.name]) { cli("remove", j.id); console.log("REMOVED " + j.name); }
}
JS
