# Sandbox overlay — prebuilt Quay image

Deploys the UBI 10 image built by the nightly CI, instead of building in-cluster.
This is the overlay for a repeatable demo: no BuildConfig, no ImageStream, no
20-minute build, no build-pod memory quota to fit.

```bash
oc login --token=... --server=https://api.sandbox-....openshiftapps.com:6443
./deploy.sh -o overlays/sandbox-quay -E OPENROUTER_API_KEY
```

Or without the deploy script:

```bash
# secrets first (the deploy script does this for you)
oc apply -k overlays/sandbox-quay
```

## Private Quay repo

Quay repos are private by default. If yours is private, the pull fails with
`ImagePullBackOff` until you add a pull secret:

```bash
oc create secret docker-registry quay-pull \
  --docker-server=quay.io \
  --docker-username='ryan_nix+worldmonitor_ci' \
  --docker-password='<robot token>'
oc secrets link default quay-pull --for=pull
```

Making the repo public under Quay → Repository Settings avoids this entirely and
is fine for a public-data demo.

## Difference from overlays/sandbox

| | sandbox | sandbox-quay |
|---|---|---|
| Image source | in-cluster BuildConfig | quay.io/ryan_nix/worldmonitor |
| Build time | ~5 min | none (pull only) |
| ImageStream + trigger | yes | removed |
| Everything else | identical | identical |

## Updating

CI pushes a new `latest` (and a `<sha>` tag) nightly. To roll a deployment to
the newest image:

```bash
oc rollout restart deploy/worldmonitor
```

For reproducibility, pin a specific tag instead of `latest` by editing the
`newTag` in kustomization.yaml to the 7-char SHA from a CI run.


## The AIS relay requires a key to start

`ais-relay` hard-exits at startup without `AISSTREAM_API_KEY` — it does not
degrade gracefully, it CrashLoopBackOffs. If you scale the relay up, supply the
key first:

```bash
./deploy.sh -o overlays/sandbox-quay \
  -E OPENROUTER_API_KEY \
  -e AISSTREAM_API_KEY=<your aisstream key>
oc scale deploy/ais-relay --replicas=1
```

Get a free key at https://aisstream.io. Without the relay, the maritime,
Hormuz-tracker, and chokepoint-rate panels stay empty; everything else works.
