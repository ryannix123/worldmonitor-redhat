# World Monitor — run it locally with Podman

A live global-situation dashboard — armed conflict, military activity, aviation,
shipping, markets, and AI-written briefs — running entirely on your own machine.
No cluster, no cloud, no account. One script brings the whole stack up.

This is the local path for anyone who'd rather run containers with **Podman**
than Docker. If you're deploying to OpenShift instead, see the main
[README](./README.md).

> **Arm64 by default.** On Apple Silicon (M-series Macs) the prebuilt images
> pull and run with no changes. On Intel/AMD it's a one-line compose edit — see
> [Intel / AMD](#intel--amd-x86-64) at the end.

---

## Why Podman for this?

Podman does the same job as Docker here, but a few of its design choices matter
for a stack like this one:

- **No root daemon.** Docker runs everything through a single root-owned daemon;
  if it's compromised, so is the host. Podman is daemonless and runs your
  containers as *your* user, rootless by default. For a dashboard that pulls
  from the open internet all day, a smaller blast radius is the right default.
- **The containers already assume non-root.** These images run as an
  unprivileged user (UID 1001, the same restricted pattern OpenShift enforces).
  Podman's rootless model matches that exactly — what you run locally behaves
  like what runs in production, instead of "works as root on my laptop, breaks
  under the cluster's security policy."
- **No background service to babysit.** Nothing runs when you're not using it.
  The one Podman machine (a small Linux VM on macOS) starts when you want it and
  stops when you don't — no always-on daemon sitting in the background.
- **Same commands, drop-in.** `podman` is CLI-compatible with `docker`, and
  `podman compose` reads the same compose files. Nothing to relearn.

None of this requires Docker to be uninstalled — Podman coexists fine. It's just
the better fit for running a public-facing dashboard safely on a personal
machine.

---

## What you get

Five containers on a private network:

- `worldmonitor` — the dashboard (nginx + Node), on <http://localhost:3000>
- `ais-relay` — runs ~35 seeders *inline* on its own loops (UCDP, live market,
  aviation, AIS) and proxies the live ADS-B / AIS streams
- `seeders` — the missing scheduler: runs the other ~120 standalone
  `seed-*.mjs` scripts once on startup, then hourly. Without this, the panels
  those seeders feed (most of the market, economic, and energy widgets) render
  "no data" even with the right keys set. See [Seeding](#seeding) below.
- `redis` — the cache
- `redis-rest` — the Upstash-compatible REST proxy the app reads through

All prebuilt and pulled from Quay. Nothing compiles on your machine.

> **Why a separate seeders container?** The images ship ~156 seed scripts but
> nothing in the app or relay invokes the full set — upstream drives them with
> ~43 hosted cron jobs that a self-hosted deploy doesn't have. On OpenShift a
> CronJob fills that gap; here the `seeders` service does, using the relay image
> (which carries the scripts) with a `cd /app && sh scripts/run-seeders.sh`
> loop.

---

## Setup

### 1. Install Podman

```bash
brew install podman podman-compose
```

(Installing `podman-compose` gives `podman compose` a provider to use. If you
already have `docker-compose`, that works too — either satisfies it.)

### 2. Start Podman's engine

macOS runs containers in a small Linux VM. Create and start it once:

```bash
podman machine init
podman machine start
```

> **"only one VM can be active at a time"** just means you already have a Podman
> machine running. That's fine — skip `podman machine start` and continue.

### 3. Run it

```bash
cd podman
./deploy.sh
```

First run prompts for your API keys (only OpenRouter is needed for AI briefs;
the rest are optional and can be skipped with Enter), writes a `.env`, then
starts the stack. Later runs skip straight to starting.

Open <http://localhost:3000> once it's up. The map and news load immediately;
the conflict, military, and market panels fill in over 2–3 minutes as the feeds
catch up.

---

## Everyday use

```bash
./deploy.sh          # start (prompts for keys the first time)
./deploy.sh -stop    # stop, keeping your cached data
./deploy.sh -reset   # re-enter your keys from scratch
```

After a reboot the Podman engine stops too — `podman machine start`, then
`./deploy.sh`.

---

## Seeding

The `seeders` container runs one full pass on startup, then repeats hourly. A
full pass is ~150 sequential scripts and takes **15–20 minutes**, so panels fill
in gradually rather than all at once. Watch it:

```bash
podman compose -f compose.local.yml logs -f seeders | grep -E 'OK|SKIP|FAIL|Done:'
```

- **`OK`** — wrote to Redis; the panel will populate.
- **`SKIP`** — the seeder's API key isn't set, or a lock is held, or the feed is
  intentionally off. Expected and harmless.
- **`FAIL (Failed gracefully …)`** — the upstream didn't answer. Many feeds are
  rate-limited or single-egress-IP-blocked and simply can't be seeded from one
  home IP; this is the app's design, not a local bug.
- The pass ends with a `Done: X ok, Y skipped, Z failed, W timed out` summary.

Seeders whose key you didn't set self-skip, so a big `SKIP` count is normal.
What stays empty regardless of keys: the hosted-cron feeds (GDELT intel,
portwatch, global tenders) and a few dead upstreams (BTC regime, Yahoo sector
heatmap) — none of those are fixable locally.

### The climate-bundle hang

One known rough edge: `seed-bundle-climate.mjs` spawns a
`seed-climate-zone-normals` child that can hang on an unreachable upstream.
Bundle seeders are **exempt** from the per-seeder timeout (they self-cap
per-section), so a hung child blocks the whole sequential pass behind it —
every panel alphabetically after "climate" waits.

If the pass stalls (the `OK`/`FAIL` count stops climbing and the last line is a
`seed-bundle-climate` with no result), free it by killing the stuck child:

```bash
podman exec podman-seeders-1 sh -c \
  'kill $(for p in /proc/[0-9]*/cmdline; do grep -q climate-zone-normals "$p" && \
   echo "${p%/cmdline}" | sed "s|/proc/||"; done) 2>/dev/null'
```

The pass then continues on its own. This recurs on each fresh run until the
bundle runner is fixed to cap that child; it's a known upstream issue, not a
misconfiguration.

---

## Getting the API keys

All optional except OpenRouter (for AI briefs). Every panel degrades gracefully
without its key.

| Key | What it powers | Where |
|---|---|---|
| `OPENROUTER_API_KEY` | AI briefs (the route to Claude) | <https://openrouter.ai> |
| `FRED_API_KEY` | Macro Stress, rates, breadth history, most FRED-derived econ panels | <https://fred.stlouisfed.org/docs/api/api_key.html> |
| `FINNHUB_API_KEY` | Earnings calendar, market metrics, metals/commodity quotes | <https://finnhub.io/register> |
| `GROQ_API_KEY` | Fast LLM inference for select brief/synthesis seeders | <https://console.groq.com> |
| `UCDP_ACCESS_TOKEN` | Armed-conflict events | free token — see main README |
| `AISSTREAM_API_KEY` | Live vessel positions | <https://aisstream.io> |
| `ACLED_EMAIL` / `ACLED_PASSWORD` | Second conflict source | <https://acleddata.com> |

Optional extras the seed pass will use if present (skipped cleanly if not):
`NASA_FIRMS_API_KEY` (fire detections), `CLOUDFLARE_API_TOKEN` (internet
outages), `EIA_API_KEY` (US petroleum). Everything still degrades gracefully
without them.

The two Redis values (`REDIS_PASSWORD`, `REDIS_TOKEN`) are generated for you —
you never type them.

> **A note on where keys go.** `deploy.sh` prompts for keys and writes them to
> `.env`; both the app and the `seeders` container read from there. Prefer the
> prompt over passing keys as command-line args — args land in your shell
> history and the process table in plaintext.

---

## If something looks wrong

**Panels stuck on "Temporarily unavailable."** Give the relay 2–3 minutes on
first run. Still stuck? Restart: `./deploy.sh -stop && ./deploy.sh`.

**Market / economic panels stay empty after several minutes.** Those are fed by
the `seeders` container, not the relay — a full seed pass takes 15–20 minutes.
Check progress with the `logs -f seeders` command under [Seeding](#seeding). If
the seed count has stopped climbing, it's likely the climate-bundle hang — see
that section for the one-line fix.

**Seeder log shows lots of `SKIP` / `FAIL`.** Normal. `SKIP` means a key isn't
set or a lock is held; `FAIL (Failed gracefully)` means an upstream is
unreachable from a home IP. Neither stops the pass. Only a `Done:` line with
zero `ok` would be a real problem.

**Nothing at localhost:3000.** Check all five containers are up with
`podman ps`. If not, run `./deploy.sh` again and watch for red error text.

**Curious what it's doing?**
`podman compose -f compose.local.yml logs -f worldmonitor` (Ctrl-C stops
watching, not the app).

---

## Intel / AMD (x86-64)

The images are multi-arch, so `podman compose` will pull the right one. The
compose file pins `platform: linux/arm64`; on an x86 machine, remove those five
`platform:` lines (or change them to `linux/amd64`) and it runs natively.
