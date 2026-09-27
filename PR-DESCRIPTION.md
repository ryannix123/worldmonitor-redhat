## Follow upstream `main` safely: relay auth, self-host digest budget, stale-tag fixes, NUC appliance

Findings from running the 2026-09-24 build (`158fd6f`) locally and on the Developer Sandbox.

### Containerfile
- **Digest budget made env-tunable** (`DIGEST_RESPONSE_LIMIT_MS`, `DIGEST_ADOPTION_BUDGET_MS`). Upstream hard-codes a 10 s feed-fetch budget derived from Vercel's 25 s edge ceiling; a single self-hosted sidecar can't fetch 245 feeds in 10 s, so every digest rebuild aborted (`deadline_aborted=true`) and the footer read "stale". Guarded `sed` fails the build if upstream moves the constants. Unset = identical to upstream. (Candidate for an upstream PR.)

### podman/
- **`deploy.sh -update` never updated an existing tag.** The docker-compose provider honours `pull_policy: missing` on `compose pull` and reports *"Skipped — image is already present locally"*, so `relay-latest` / `redis-rest-latest` stayed on the Aug-30 build while `-update` reported success. Now pulls every compose image with `podman pull` (always compares digests) before `up -d`.
- New `deploy.sh -version`: prints the upstream commit each image was built from (`org.opencontainers.image.revision`) and warns when app and relay drift.
- `WORLDMONITOR_RELAY_KEY` on **both** app and relay: since upstream #3541 the gateway validates the relay's `X-WorldMonitor-Key` against its own `WORLDMONITOR_RELAY_KEY` with no Origin-trust fallback.
- Digest knobs on the app service (inert until the patched image ships).

### base/ (OpenShift)
- `imagePullPolicy: Always` on `ais-relay` and the seeder CronJob — the Quay overlay maps them to `relay-latest`, which does **not** get Kubernetes' implicit `Always` (only a tag literally named `latest` does), so nodes kept a cached image across rollout restarts. Explicit on `worldmonitor` too for consistency.
- `WORLDMONITOR_RELAY_KEY` added to the app from the same Secret key as the relay (the existing `VALID_KEYS` mapping is kept; least-privilege cleanup noted in a comment).
- Digest knobs in `worldmonitor-config`.
- Redis `7-alpine` → `8-alpine`, matching Podman; CVE-2026-66373 (RESTORE double-free) fixed in 8.8.0+.

### nuc/ (new)
Self-updating appliance for a spare Fedora box: rootless Podman + Quadlet units mirroring `compose.local.yml`, `podman-auto-update` nightly with **healthcheck-gated rollback** (`Notify=healthy`), `dnf-automatic`, weekly reboot, optional GNOME/Firefox kiosk, one-page office card. Digest-based, so it can't be fooled by a stale tag.

### Verified
- Security Advisories: seeder went from `13 countries with levels` (stale relay image, pre-Sept-15 code, index built from the 15-per-source capped list) to `207 countries` after the relay actually updated.
- CI runs on this PR without pushing (`if: github.event_name != 'pull_request'` on Push/manifest), so the Containerfile change is proven before it can reach `latest`.
