<p align="center">
  <img src="docs/assets/banner.svg" alt="World Monitor on OpenShift or Podman" width="100%">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/worldmonitor-redhat/actions/workflows/build.yml">
    <img src="https://github.com/ryannix123/worldmonitor-redhat/actions/workflows/build.yml/badge.svg" alt="Build status"></a>
  <img src="https://img.shields.io/badge/base-UBI%2010-EE0000?logo=redhat&logoColor=white" alt="UBI 10">
  <img src="https://img.shields.io/badge/platform-OpenShift-EE0000?logo=redhatopenshift&logoColor=white" alt="OpenShift">
  <img src="https://img.shields.io/badge/local-Podman-892CA0?logo=podman&logoColor=white" alt="Podman">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2dd4bf" alt="Multi-arch">
  <img src="https://img.shields.io/badge/SBOM-SPDX-2dd4bf" alt="SBOM SPDX">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-informational" alt="AGPL-3.0">
</p>

# World Monitor on OpenShift or Podman

Run a live, real-time global intelligence platform on your own cluster —
built on Red Hat UBI, published through a security-scanned pipeline, and
deployed with a single command.

[World Monitor](https://github.com/koala73/worldmonitor) turns public data —
markets, trade, conflict, energy, infrastructure, aviation, maritime, and 500+
news feeds — into a live operating picture of the world. A dark map, live
tickers, chokepoint analysis, vessel and flight tracking, AI-assisted briefs.
It's the kind of dashboard people reach for "open-source Palantir" to describe,
though [its author pushes back on that](https://www.worldmonitor.app/blog/posts/worldmonitor-is-not-palantir/):
Palantir makes *your institution's private data* operational; World Monitor
assembles *the public world's data* and shows its own cracks in the open. This
repo is about running that second thing, well, on infrastructure you control.

**What this repo adds:** the upstream project ships as an Alpine container aimed
at Vercel and Railway. This repo rebuilds it the way you'd run it in an
enterprise — on Red Hat's UBI 10 base images, hardened for OpenShift's
`restricted-v2` security context, built by a multi-arch CI pipeline that
generates SPDX SBOMs and scans every build, and deployed through Kustomize
overlays with one command.

So there are two halves:

1. **Build** — a nightly multi-arch (amd64 + arm64) pipeline that rebuilds both
   the app and its data relay on UBI 10, generates SPDX SBOMs, scans every build
   with Grype (published to the run summary and retained as an artifact), and
   publishes to Quay.
2. **Deploy** — Kustomize overlays for OpenShift Developer Sandbox (free tier),
   Single Node OpenShift with a GPU for local LLM inference, or plain Podman on
   a laptop. One script, namespace-portable, with a teardown path.

The result: the same live intelligence platform — vessels moving on the map,
chokepoint flows, conflict zones, market data, all seeding through Redis — but
running on images you built, scanned, and can audit end to end.

**Two targets, one image.** The same UBI 10 images run two ways. Reach for
**OpenShift** when you want the platform to *enforce* the security posture — SCC,
RBAC-scoped Secrets, IP-allowlisted Routes, self-healing workloads — and
**Podman** when you want the lightest path to a running instance on a single
machine, no cluster required. The OpenShift section below argues for the enforced
posture; the Podman path trades that enforcement for a two-command start on a
laptop. Same app, you pick the amount of platform.

> **On the image name.** This project started as OpenShift-only, so the images
> live at `quay.io/ryan_nix/worldmonitor-openshift`. The local Podman path was
> added later and pulls those same images — the `-openshift` in the name is
> historical, not a constraint. Keeping the name stable means every overlay and
> compose reference keeps working; renaming it would buy nothing but churn.

## Engineering highlights

The interesting parts aren't "it runs" — it's *how* it was made to run safely
and repeatably:

- **UBI 10, not Alpine.** Both images rebuilt on Red Hat's supported base
  (`ubi10/nodejs-24`, `ubi-minimal`), matching the app's Node 24 requirement
  with no version compromise.
- **No init system.** The upstream image runs supervisord to babysit nginx and a
  Node sidecar. This replaces it with a 40-line signal-handling shell entrypoint
  — smaller image, fewer CVEs, and a documented reason (`exec nginx` as PID 1
  silently orphans the sidecar on shutdown; the shell stays PID 1 instead).
- **Arbitrary-UID clean.** Runs under OpenShift's `restricted-v2` SCC with no
  privileged access — group-0 ownership, no baked-in root.
- **A real security supply chain.** Multi-arch build, SPDX SBOM per image, and a
  Grype scan on every build, published to the run summary and retained as an
  artifact. Images rebuild nightly so base-image patches land without waiting on
  an upstream release.
- **Namespace-portable deploy.** Nothing hardcodes a namespace; the same
  overlays run on any cluster the current `oc` context points at, from a free
  Developer Sandbox to a GPU-equipped Single Node OpenShift.
- **Claude wired in.** Live LLM-assisted briefs via OpenRouter, with a preflight
  that verifies the model is actually reachable rather than silently falling back.

---

## Why deploy World Monitor on OpenShift?

World Monitor is an open-source dashboard that ships a `docker-compose.yml`. You
*can* run it that way — a VM, four containers, a `.env` file, and `restart:
unless-stopped`. It works. The reason to put it on OpenShift instead isn't that
the app needs a Kubernetes distribution; it's that every property you'd
otherwise have to *remember to configure* becomes something the platform
*refuses to run without*.

That's the whole argument in one line: **on a VM these are things you intend to
do; on OpenShift they're things the platform enforces.** The difference between a
security intention and a security posture.

### Same app, two postures

| Concern | `docker compose` on a VM | This repo on OpenShift |
|---|---|---|
| Container user | root, or whatever the image ships | arbitrary non-root UID, enforced by SCC |
| Redis REST proxy | hiett SRH — path-style GET 404s | upstream proxy, UBI-rebuilt, full command set |
| Image provenance | whatever's on Docker Hub, unscanned | UBI base, SBOM + Grype per build, nightly rebuild |
| Access control | host firewall, hand-managed | Route + IP allowlist annotation, edge TLS |
| Secrets | `.env` on disk, in the compose file | Secret objects, mounted, RBAC-scoped |
| Recovery when a container dies | `restart: unless-stopped` | rescheduled, probed, rolled out declaratively |

### The layers aren't a checklist — they're nested

Each control assumes the one outside it might fail. A request clears the Route's
IP allowlist before it reaches anything; the workload can't read a Secret it
isn't RBAC-bound to; and the SCC forbids the entire pod from running as root
regardless of what any Containerfile tries to do. Defense in depth, where every
layer is a manifest in this repo — so removing one is a reviewable diff, not a
firewall rule someone forgot.

**1. Route — IP allowlist + edge TLS.** A public conflict dashboard usually
shouldn't be genuinely public. Rather than stand up an auth proxy, restrict the
Route to known CIDRs and let the router terminate TLS:

```bash
oc annotate route/worldmonitor \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.0/24 198.51.100.7"
```

Space-separated CIDRs or bare IPs. On the Developer Sandbox this is the cleanest
way to keep the dashboard reachable only from where you want it.

**2. Restricted SCC — non-root, enforced.** Both images already declare `USER
1001` and the arbitrary-UID `chgrp -R 0 && chmod -R g=u` pattern. On a plain VM
nothing makes an image honor that. OpenShift's `restricted-v2` SCC assigns an
arbitrary UID in group 0, drops all Linux capabilities, and rejects any
container that tries to run as root. The CI smoke test asserts `USER 1001` on
every build, so the non-root claim is verified rather than assumed — which is
the honest version of the guarantee.

**3. Secrets — RBAC-scoped, never in the image.** `apikeys`, `redis`, and
`relay` are Secret objects mounted into the pods, not baked into a layer or
committed to a compose file. A workload reads only the Secrets its service
account is bound to.

**4. Self-healing workloads.** A crashed pod is rescheduled and re-probed
against its readiness gate, and rollouts are declarative — the running state
converges to what the manifests say rather than to whatever a `docker restart`
left behind. (See the Redis REST proxy story below for a case where a readiness
race looked exactly like a credential failure until the platform's own restart
behavior surfaced it.)

---

## 🆓 Red Hat Developer Sandbox

The [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) is a **free** OpenShift environment perfect for testing World Monitor:

- **Free tier** — No credit card required, no setup, no cluster to install
- **Generous resources** — 3 CPU cores, 14 GB RAM, and 40 GB storage per user — plenty to run this entire stack
- **Latest OpenShift** — Always running a recent version (4.18+)
- **Auto-hibernation** — Deployments scale to zero after 12 hours of inactivity

> 💡 **New to OpenShift?** The Sandbox is the fastest way to try the platform — you get a real, current OpenShift cluster in your browser in minutes, with zero install. This entire World Monitor stack is designed to deploy there on the free tier. [Grab a free Sandbox](https://developers.redhat.com/developer-sandbox) and run `sh deploy.sh`.

Confirm your own namespace's quota at any time:

```bash
oc describe resourcequota
```

### Waking Up Your Deployment

When you return after the sandbox has hibernated, your pods will be scaled down. Run this command to bring everything back up:

```bash
# Scale all deployments back to 1 replica
oc scale deployment --all --replicas=1

# Or specify your namespace explicitly
oc scale deployment --all --replicas=1 -n $(oc project -q)
```

Your data persists in the PVCs — only the pods are stopped during hibernation.

---

## Layout

```
.github/workflows/   Nightly multi-arch build + weekly upstream-sync PR
ci/                  Scan-summary helper for the build
containers/          Containerfile.ubi10 + entrypoint (the image)
upstream.env         Pinned upstream commit SHA

base/                Kustomize base: 4 Deployments, Route, NetworkPolicy
addons/builds/       BuildConfigs + ImageStreams (in-cluster build path only)
overlays/
  sandbox/           Developer Sandbox, builds in-cluster
  sandbox-quay/      Developer Sandbox, pulls the prebuilt Quay image
  sno/               Single Node OpenShift, GPU Ollama for local LLM
deploy.sh            One-shot deploy: ./deploy.sh -o <overlay> -E OPENROUTER_API_KEY
podman/              Local Podman path (arm64 prebuilt; x86 with a compose edit)
```

## Two ways to get the image onto a cluster

**Prebuilt from Quay (recommended for demos).** CI has already built it; the
overlay just pulls it. Fastest, and the same artifact every time.

```bash
oc login --token=... --server=https://api.sandbox-....openshiftapps.com:6443
./deploy.sh -o overlays/sandbox-quay -E OPENROUTER_API_KEY
```

**Build in-cluster.** No external registry needed; OpenShift builds from source
in ~5 minutes. Useful on SNO or when you want everything self-contained.

```bash
./deploy.sh -o overlays/sandbox -E OPENROUTER_API_KEY   # or overlays/sno
```

`-E` prompts for the key without echoing. Use `-e KEY=VALUE` for the inline
form, or omit both to deploy without AI features. See `overlays/*/README.md` for
per-target detail.

## Local Podman

No cluster, no `oc`, no Kustomize — the lightest path to a running instance on a
single machine. This runs the same UBI 10 images as the OpenShift path, without
the SCC / RBAC / Route enforcement layer; you get the app, not the enforced
posture. Good for a demo on a laptop, offline tinkering, or seeing the dashboard
before standing up a cluster. Rootless by default, and the images already assume
non-root (UID 1001), so local behavior matches what the cluster enforces.

```bash
git clone https://github.com/ryannix123/worldmonitor-redhat.git
cd worldmonitor-redhat/podman
./deploy.sh
```

First run prompts for API keys (only `OPENROUTER_API_KEY` is needed for AI
briefs; the rest are optional), writes a `.env`, and starts four containers.
Open <http://localhost:3000> — the map loads immediately, the conflict and market
panels fill in over 2–3 minutes as the feeds catch up.

> **Apple Silicon by default.** Images are pulled prebuilt for arm64 and the
> compose file pins `platform: linux/arm64`. On Intel/AMD, remove those `platform:`
> lines (or set them to `linux/amd64`) and it runs natively — the images are
> multi-arch.

See **[README-podman-local.md](./README-podman-local.md)** for everyday commands
(`-stop`, `-reset`), the full key table, and troubleshooting.

## Data source API keys

Every key is optional and every panel degrades gracefully without one. Pass
them at deploy time with `-E KEY` (prompts, no echo) or `-e KEY=VALUE` (inline,
for non-secret values like an email):

```bash
./deploy.sh -o overlays/sandbox-quay \
  -e ACLED_EMAIL=you@example.com \
  -E ACLED_PASSWORD \
  -E AISSTREAM_API_KEY \
  -E FINNHUB_API_KEY \
  -E OPENROUTER_API_KEY \
  -E UCDP_ACCESS_TOKEN
```

Where to get each (all free tiers):

| Key | Powers | Free tier | Get it at |
|---|---|---|---|
| `OPENROUTER_API_KEY` | AI briefs (route to Claude) | 50 req/day | <https://openrouter.ai/keys> |
| `FINNHUB_API_KEY` | Stock quotes, market data | 60 req/min | <https://finnhub.io/register> |
| `UCDP_ACCESS_TOKEN` | Armed-conflict events + CII floor | 5,000 req/day | free token — <https://ucdp.uu.se/apidocs/> |
| `ACLED_EMAIL` / `ACLED_PASSWORD` | Second conflict source | free for researchers | <https://acleddata.com/register/> |
| `AISSTREAM_API_KEY` | Live vessel positions | free | <https://aisstream.io/apikeys> |

They land in `overlays/<target>/secrets/apikeys.env`, which is gitignored and
becomes the `worldmonitor-apikeys` Secret. Both the app and the relay mount it
via `envFrom`, so a key added here reaches whichever process needs it.

### Finnhub — stock quotes & market data

`FINNHUB_API_KEY` feeds the market panels — real-time stock quotes and the
finance composite. The free tier allows 60 requests per minute, which is
comfortable for the seed cadence. Register at <https://finnhub.io/register>; the
key is shown on the dashboard immediately after signup, no approval wait.

> Upstream is [evaluating a move](https://github.com/koala73/worldmonitor/issues/2055)
> to Alpha Vantage as the primary market source, with Finnhub kept as a fallback.
> Finnhub is current today; watch that issue if the market panels change behavior
> after an upstream sync.

### UCDP — armed conflict events

`UCDP_ACCESS_TOKEN` feeds the ARMED CONFLICT EVENTS panel and the conflict floor
in the Country Instability Index. Without it that panel sits at zero and CII
reports `degraded`. The conflict family in CII's health-coverage signal is
satisfied by either UCDP or ACLED, so running one source keeps coverage green;
running both adds cross-validation, not a hard requirement.

The Uppsala Conflict Data Program publishes a free REST API at
`ucdpapi.pcr.uu.se`, documented at <https://ucdp.uu.se/apidocs/>. Anonymous
access works but is capped: 5,000 requests per day, 1,000 rows per page, and
paging is mandatory — a full Georeferenced Event Dataset pull is ~418 pages, so
a handful of seed cycles will exhaust the daily quota. A free access token
lifts both the paging requirement and the download limit, which is what you
want for anything that re-seeds on a loop. Request one from the API maintainer
(`ucdp@pcr.uu.se`); the apidocs page has the current process.

What the token buys you is *reliable seeding*, not a deeper history window. The
token removes the API-side paging and quota limits, but the relay retains at
most 2,000 mapped events from a ~365-day trailing slice (the seed fetches the
newest few pages, not the full dataset). CII classifies conflict per country
over a nominal 2-year window, but live scoring is bounded by that ~1-year
retention slice — so the token keeps the panel fed and current, rather than
extending how far back the conflict floor can see. If you need a longer window,
that's a relay retention change (page depth + Redis payload size), not a
token-tier change.

UCDP sends the token as an `x-ucdp-access-token` header rather than a bearer
token. The relay handles that — `scripts/ais-relay.cjs` reads
`UCDP_ACCESS_TOKEN` (falling back to `UC_DP_KEY`) and sets the header itself.
Nothing to configure beyond the deploy flag.

Confirm it took after deploying:

```bash
oc logs deploy/ais-relay | grep -i ucdp
# [UCDP] Version 26.1, 418 total pages
# [UCDP] Seeded 2000 events (raw: 5968, failed pages: 0, redis: OK)
```

`failed pages: 0` means the token authenticated. `redis: OK` means the write
landed — a `redis: FAIL` there points at the cache proxy, not at UCDP.

### ACLED — conflict events (second source)

`ACLED_EMAIL` and `ACLED_PASSWORD` cover the same panel family from a different
source, and either UCDP or ACLED satisfies CII's conflict-coverage health check
on its own — so ACLED is a valid primary if you'd rather not run UCDP, not only
a redundant second feed. ACLED registration is at <https://acleddata.com/>. Note
that ACLED has moved auth models more than once; if the relay logs
`ACLED API error: 403`, check whether your account now needs an API key rather
than email and password.

## The image

`containers/Containerfile.ubi10` rebuilds upstream's Alpine image on
`ubi10/ubi-minimal` + `nodejs24`, replaces supervisord with a shell entrypoint,
and supports OpenShift's arbitrary UID. `.nvmrc` pins Node 24 and `ubi10/nodejs-24`
is GA, so there was no version compromise.

It stays a **single container** deliberately: nginx and the Node sidecar share a
per-start random `LOCAL_API_TOKEN`, and splitting them would force that into a
long-lived Secret. See `containers/` and the note in the CI section below.

### Why no supervisord / s6 / tini

Two processes, one of which exists only to serve static files and proxy `/api/`.
The entrypoint runs them as shell-managed children: `wait -n` exits with
whichever dies first, SIGTERM is forwarded to both. Note that `exec nginx` as
PID 1 was tried and rejected — it discards the trap and orphans the sidecar on
shutdown. The shell stays PID 1 for correct signal handling.

## CI

Nightly at 07:00 UTC (02:00 CDT), plus on push and manual dispatch:

- Resolves one upstream SHA for the whole run, so every arch and image builds
  from identical source
- Builds three images, each on both arches, and assembles a manifest list per
  image:
  - the app (`build`, `Containerfile.ubi10`) — smoke test hits the health
    endpoint, the SPA fallback, and asserts non-root UID
  - the relay (`build-relay`, `Containerfile.ubi10-relay`)
  - the Redis REST proxy (`build-redis-rest`, `Containerfile.redis-rest`) —
    smoke test writes via POST and reads back via path-style GET, the exact call
    hiett's SRH 404s on, plus an unauthenticated-request check
- Syft SBOM + Grype scan per image, published to the run summary and retained as
  an artifact. No severity gate — the scan reports, it doesn't block
- Pushes `<sha>`, `relay-<sha>`, `redis-rest-<sha>` and their `latest` tags to
  `quay.io/ryan_nix/worldmonitor-openshift`

`upstream-sync.yml` opens a bump PR every Monday, since upstream ships from
`main` and stopped tagging ~5 months ago. It flags changes to build-relevant
files so a bump is reviewed, not blindly merged.

### CI secrets

| Secret | Purpose |
|---|---|
| `QUAY_USERNAME` | Quay robot account, e.g. `ryan_nix+worldmonitor_ci` |
| `QUAY_PASSWORD` | That robot's token (needs Write on the repo) |

## Wiring Claude

The app has no Anthropic provider — its LLM layer speaks OpenAI-compatible,
`groq`, `openrouter`, or `ollama`. OpenRouter is the route to Claude, and the
overlays set the model routing. Before relying on it, run
`scripts/verify-openrouter.sh` (in the deploy bundle) to confirm the app's
forced provider-routing constant doesn't exclude Anthropic models. See any
overlay's notes for the profile/model detail.

## Cost note

Upstream caps AviationStack spend but has no LLM ceiling, and the seeders run on
cron across 500+ feeds. The overlays enable `USAGE_TELEMETRY` and leave the
fan-out pipelines (`AI_DIGEST_ENABLED`, `BRIEF_COMPOSE_ENABLED`) off. Prepay a
small OpenRouter balance and enable pipelines one at a time.


## Known-empty panels (upstream architecture)

Both deployments (OpenShift and local Podman) will show some panels empty no
matter how they're configured. These are consequences of upstream's deployment
architecture, not misconfiguration — documented here so nobody burns an evening
rediscovering them.

They fall into three root causes: **starved news pipeline** (standalone
GDELT-fed seeders that a single egress IP can't complete — takes down Live
Intelligence, AI Insights, and Security Advisories together), **SSRF-blocked
relay path** (Force Posture, parts of Escalation Monitor), and **missing upstream
microservices / weekly data** (Consumer Prices, COT). None is fixable with API
keys or by waiting; each needs an upstream change or infrastructure the
self-host doesn't have.

**The news pipeline (Live Intelligence, AI Insights, and the news feed)** — three
panels share one root cause, so they fail together. The chain is: standalone news
seeders write headlines to Redis → the relay's `[Classify]` loop tags them via
the LLM providers → AI Insights summarizes the tagged set. If step one produces
nothing, the whole chain is starved.

Step one is `seed-gdelt-intel` and its siblings — ~43 standalone Railway seed
crons upstream runs separately from the app + relay (`scripts/railway-services.json`
in the upstream repo lists them; their runbook calls them "standalone seed crons,
not bundled"). They're self-hostable in principle — they need only Redis
credentials and GDELT's free DOC API — but GDELT rate-limits per-IP aggressively
enough that a single-address self-host cannot complete the multi-topic sweep
before the limit trips. It runs fine from upstream's Railway IP space; on a home
or single-egress deployment the news headlines never land.

Downstream of that, **AI Insights renders UNAVAILABLE** not because the LLM chain
is broken but because it has nothing to summarize. The tell is in the relay log:
`[Classify]` shows `providers:openrouter,groq` with no auth errors, yet every
cycle reports `0 titles, 0 classified` across every topic — healthy providers,
empty input. **Live Intelligence** ("No recent articles for this topic") is the
same starvation one step earlier in the chain. Adding LLM keys does nothing here;
the missing piece is the news headlines, which need an egress IP GDELT hasn't
rate-limited.

**Force Posture and parts of Escalation Monitor** — the app fetches live
military data through the relay (`WS_RELAY_URL`), but the sidecar's SSRF guard
blocks private origins and only allowlists `UPSTASH_REDIS_REST_URL`'s origin in
docker mode. `WS_RELAY_URL`'s origin never gets the same treatment, and the
allowlist is deliberately env-free (no operator override). Every direct
relay fetch fails with `SSRF blocked: Hostname resolves to a private/reserved
IP` — visible only in logs; the UI just shows the panels empty or stuck on
"Connecting to ADS-B". AI Strategic Posture still populates because the relay's
own theater-posture seed loop writes to Redis, bypassing the blocked path. The
fix is a one-line upstream change (allowlist `WS_RELAY_URL`'s origin alongside
the Upstash one); until it lands, these panels are partial on any
self-hosted deployment.

**Security Advisories** — another standalone Railway seeder; same category as the
news pipeline above (starved on a single-egress self-host).

**Consumer Prices** — the authoritative writer is upstream's separate
`consumer-prices-core` microservice (a scrape → aggregate → publish pipeline),
which isn't part of this image. The bundled `seed-consumer-prices.mjs` is only a
manual fallback: it hard-requires a `--force` flag (a deliberate guard so it
can't stomp `consumer-prices-core`'s 26h TTLs with its own 10–60min ones) and
its own `CONSUMER_PRICES_CORE_BASE_URL` endpoint, which the seed runner doesn't
even pass through. So this seeder self-aborts under automation — an *expected*
`FAIL` in the seeder log, not an error — and the panel stays on "Pending data".
Not fixable with an API key; it needs a service upstream didn't open-source.

**24/7 Positioning (COT) and Liquidity Shifts** — driven by CFTC Commitment-of-
Traders data, which publishes weekly and computes over accumulated history. The
panel shows "Building baselines… over the next hour" / "No COT rows available"
until enough history seeds. On a fresh deploy this can stay sparse for a while;
it is timing, not misconfiguration.

## Self-hosting fixes in this repo

Three gaps that stop a self-hosted deployment from working, none of them
documented upstream. Each is fixed here and verified against a running cluster:

**1. Hardcoded production RPC URLs.** The relay's warm-ping and RPC targets are
string constants pointing at `api.worldmonitor.app` with no env override, so a
self-hosted relay authenticates against upstream's production gateway and 401s.
Fixed with a fetch-layer preload (`WM_INTERNAL_API_BASE`) that rewrites the
origin — see `containers/Containerfile.ubi10-relay`.

**2. Undocumented auth requirements.** Key-gated endpoints need
`WORLDMONITOR_VALID_KEYS` on the app (allowlisting the relay's
`X-WorldMonitor-Key`) and `WM_SESSION_SECRET` so the app can mint browser
sessions. Without the latter, every browser request to a gated endpoint returns
401 "API key required" and the panels render UNAVAILABLE even though the API
computes the data correctly. Both are generated by `deploy.sh`.

**3. SRH path-style GET incompatibility.** `readCachedJson()` reads Redis with
`GET ${UPSTASH_REDIS_REST_URL}/get/<key>`. Upstash's hosted API serves that;
`hiett/serverless-redis-http`, the usual self-hosted stand-in, implements only
the POST-command forms and 404s every path-style route. The 404 is treated as a
cache miss, so Redis-backed panels show "no data" while the data sits in Redis
— Security Advisories had 219 records stored and displayed 0, and UCDP had
2,000 events in a 757 KB key while the panel read `{"events":[]}`.

The failure is near-silent by design: the handlers catch and return an empty
result rather than an error, and the only log line is a bare
`[redis] getCachedJson failed: Redis HTTP 404` with no key name. Everything
downstream looks healthy — the seed loops report `redis: OK` because writes use
the POST form, which SRH does implement.

A `--require` preload shim on the app image was the first attempt and is not
enough: it patches `globalThis.fetch`, but the API handlers are loaded through
`await import()` and resolve `fetch` as an ES module binding the patch never
reaches. The working fix is to stop using SRH. Upstream ships its own proxy at
`docker/redis-rest-proxy.mjs`, which handles `GET /{cmd}/{args}`, `POST /`,
`POST /pipeline` and `POST /multi-exec` — the full set the app uses.
`containers/Containerfile.redis-rest` rebuilds it on UBI 10 (upstream's
Dockerfile uses `node:24-alpine` and runs as root, which restricted SCC
rejects), CI publishes it, and `base/redis-rest.yaml` points at it.

The first and third are one-line upstream fixes (make the constants
configurable; use the POST form or document the SRH requirement) and are worth
upstreaming.

## Troubleshooting: every panel empty, relay logs `ECONNREFUSED …:80`

If the whole dashboard renders empty and `oc logs deploy/ais-relay` shows seed
lines ending in `redis: FAIL` / `redis: PARTIAL` alongside
`ECONNREFUSED <redis-rest-clusterIP>:80`, the relay can't reach the Redis REST
proxy — the seeders fetch fine but can't persist, and every Redis-backed panel
reads empty.

The cause is a **named-`targetPort` resolution trap** on the `redis-rest`
Service. The proxy runs as a non-root arbitrary UID and can't bind privileged
:80, so its container listens on **8080** (`PORT=8080`, `containerPort: 8080`).
The Service must forward to that. `base/redis-rest.yaml` therefore pins the
literal:

```yaml
ports:
  - name: http
    port: 80
    targetPort: 8080   # literal, NOT the name "http"
```

Why literal and not `targetPort: http`: a *named* targetPort is resolved once
and is **not** re-resolved when only the container's port value changes on an
already-existing Service. If an earlier revision had the container on :80 and a
later one moved it to :8080, `oc apply` on the unchanged `targetPort: http`
string is a no-op — the live Service keeps its stale :80 mapping, and every
relay write dies with `ECONNREFUSED …:80`. The symptom is indistinguishable from
missing API keys or slow seeding, which is what makes it eat an afternoon.

If you hit a stale live Service (endpoints show `:8080` but the Service still
targets `:80`), force the correction once:

```bash
oc patch svc redis-rest --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
```

Then confirm `oc get endpoints redis-rest` reads `…:8080` and watch the relay's
`redis:` lines flip to `OK`. The manifest already carries the literal, so a
clean deploy never hits this — it only bites when mutating an existing Service.