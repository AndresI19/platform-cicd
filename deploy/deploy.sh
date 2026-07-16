#!/usr/bin/env bash
# deploy.sh <component> <version> [src] — roll one component to one version, via Helm.
#
# Runs INSIDE the runner container, as the `deployer` ServiceAccount. Two things changed with the
# chart split, and they are the whole shape of this script:
#
#   * ONE RELEASE PER COMPONENT. The umbrella `platform` release rendered every app from one
#     `.Values.apps` map, so a per-component deploy had to say `--reuse-values` to avoid wiping its
#     siblings' image tags. That flag is gone, and with it a whole class of bug: --reuse-values carries
#     the RELEASE's stored values forward, so the chart's own values.yaml stopped being the source of
#     truth. A key deleted from the chart lived on in release state forever (fvt-traffic was still
#     rendered into the cluster for a day after it was removed from the chart, purely this way), and a
#     key ADDED to the chart never reached an existing release. Now: the component's values come from
#     its own repo, in full, on every deploy — the file IS the state, and nothing accumulates.
#   * NO --wait. The runner is a single, ephemeral, serialized worker: every second it spends watching
#     a rollout is a second the next release sits in GitHub's queue. So the upgrade returns as soon as
#     the manifests are applied and a Job (rollout-check.yaml) watches the rollout IN THE CLUSTER,
#     where the watching is free. See "what success means" below — the semantics genuinely change.
#
# WHAT SUCCESS MEANS HERE. Exit 0 now means APPLIED AND BEING WATCHED, not "rolled out". Kubernetes'
# RollingUpdate is what makes that safe rather than reckless: a new image that never becomes ready does
# not displace the healthy old pods, so a failed deploy degrades to "the old version is still serving"
# — never to an outage. The Job turns that silent stall into a loud, reverted one, and pings Discord.
# release.yml's message says "deploying" for exactly this reason: the ✅ is the apply, and the ❌ that
# may follow comes from the Job, minutes later.
#
# Still true: no kubeconfig repoint (this container is ON minikube's network, so the native apiserver
# address minikube wrote is simply correct), and the image is PULLED from registry:5000 (no side-load).
# fvt-traffic is NOT a chart app — it runs on the host, and release.yml never calls this script for it.
set -Eeuo pipefail

COMPONENT="${1:?usage: deploy.sh <component> <version> [src]}"
VERSION="${2:?usage: deploy.sh <component> <version> [src]}"
SRC="${3:-src}"
NS=platform
# The release IS the component now — which is also why rollout-check.yaml can `helm rollback ${COMPONENT}`.
RELEASE="$COMPONENT"
# The generic service chart, checked out by release.yml from platform-orchestration@main. It carries no
# per-service values at all; everything specific comes from the app repo's file below.
CHART="${CHART:-orchestration/charts/service}"
# The component's Deployment/Service spec, owned by the repo that ships the component. This is the half
# of the split that moved OUT of orchestration: the team that changes the service changes its resources.
VALUES="${VALUES:-${SRC}/deploy/${COMPONENT}.values.yaml}"
IMAGE="registry:5000/${COMPONENT}:${VERSION}"
# kubectl + helm in one small image for the check Job. Pinned to the cluster's own minor: `kubectl
# rollout status` is the entire point of that Job, and version skew is not a thing to discover there.
K8S_IMAGE="${K8S_IMAGE:-alpine/k8s:1.35.1}"
# Under activeDeadlineSeconds (420) in rollout-check.yaml, so the timeout is what fires, not the kill.
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"

say() { echo "    $*"; }

# --- 1. refuse to deploy an image that is not really there --------------------------------------
# A bad tag would patch the Pod spec, sit in ImagePullBackOff, and surface as a rollout-check failure
# five minutes later rather than "you deployed a typo". Ask the registry first. Check the TAGS LIST, not
# the manifest endpoint: a manifest request pins an Accept media type and a registry answers 404 (not
# 406) for a type it does not have stored — docker 28 pushes OCI, so asking for schema2 reads a present
# image as missing. The tags list has no such ambiguity.
echo "==> Verifying ${IMAGE} exists"
curl -fsS --cacert /certs/ca.crt "https://registry:5000/v2/${COMPONENT}/tags/list" \
  | grep -q "\"${VERSION}\"" \
  || { echo "FATAL: ${IMAGE} is not in the registry — nothing was deployed" >&2; exit 1; }
say "present"

# --- 2. refuse to deploy a component that ships no values ---------------------------------------
# Without this the helm upgrade would still "succeed" — against the chart's own defaults, which describe
# no real service — and quietly deploy a component-shaped nothing. A repo that adds a component and
# forgets its values file should be told, at the top, in one line.
[ -f "$VALUES" ] || {
  echo "FATAL: ${COMPONENT} has no deploy values at ${VALUES} — nothing was deployed" >&2
  echo "       the repo that ships ${COMPONENT} must commit that file (see platform-orchestration/charts/service)" >&2
  exit 1
}
say "values: ${VALUES}"

# --- 3. vendor the library subchart ---------------------------------------------------------------
# charts/service declares a `platform-lib` dependency (file://../lib) that holds the shared platform.app
# helper, and orchestration gitignores `charts/*/charts/` — the vendored copy is BUILT, never committed.
# So the fresh checkout release.yml just made has a chart that cannot render until this runs; without it
# every deploy dies on "found in Chart.yaml, but missing in charts/ directory". It resolves from the
# adjacent path, so it needs no network and no repo to be added.
helm dependency build "$CHART" >/dev/null 2>&1 \
  || { echo "FATAL: could not vendor ${CHART}'s platform-lib dependency" >&2; exit 1; }

# --- 4. remember what we are replacing ----------------------------------------------------------
# So the check Job's failure message can NAME what it reverted to, rather than saying "rolled back".
PREVIOUS="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
say "currently running ${PREVIOUS}"

# --- 5. the deploy ------------------------------------------------------------------------------
# --install: the first per-component deploy CREATES this release (the umbrella owned these objects).
# --take-ownership: and adopts the objects the umbrella release still holds — without it Helm refuses to
#   touch a resource annotated for another release. It stays on afterwards for the same reason
#   --force-conflicts does: CI is authoritative, and a manual hotfix must never make the next deploy fail.
# --force-conflicts: legacy field managers (`kubectl set image`, the old umbrella) own fields Helm 4's
#   server-side apply must be told to take. The chart/release IS the source of truth.
# No --wait: step 6 launches the watcher. No --reuse-values: see the header.
echo "==> helm upgrade ${RELEASE}: ${COMPONENT} → ${VERSION}"
if ! helm upgrade --install "$RELEASE" "$CHART" -n "$NS" -f "$VALUES" \
      --set "image.repo=registry:5000/${COMPONENT}" \
      --set "image.tag=${VERSION}" \
      --set "version=${VERSION}" \
      --take-ownership --force-conflicts; then
  echo "FATAL: ${COMPONENT} ${VERSION} was not applied; ${PREVIOUS} is still running" >&2
  exit 1
fi
say "applied"

# --- 6. verify the SPEC, then hand the ROLLOUT to the cluster ------------------------------------
# Read the spec back rather than trusting the command that set it — every silent failure this platform
# has had was a step that reported success without being checked. This asserts what helm just wrote; it
# says nothing about readiness, which is deliberately the Job's job and not the runner's.
LIVE="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$LIVE" = "$IMAGE" ] || { echo "FATAL: expected ${IMAGE}, cluster says ${LIVE}" >&2; exit 1; }

# sed, not envsubst, for two reasons. The runner image has no gettext-base (so no envsubst) and
# runner.service brings the container up with `compose up -d` — never `--build` — so a deploy script
# that needed a new package would fail on the next release and keep failing until someone rebuilt the
# image by hand. sed is in every image there will ever be.
#
# Substituting an EXPLICIT five is load-bearing either way: rollout-check.yaml's container script reads
# $WEBHOOK at runtime, INSIDE the pod, from a secret. Anything that substitutes every name it knows
# would replace that with the runner's empty value and silently disable the alert.
echo "==> Launching ${COMPONENT}-rollout-check (${ROLLOUT_TIMEOUT})"
sed -e "s|\${COMPONENT}|${COMPONENT}|g" \
    -e "s|\${IMAGE}|${IMAGE}|g" \
    -e "s|\${PREVIOUS}|${PREVIOUS}|g" \
    -e "s|\${K8S_IMAGE}|${K8S_IMAGE}|g" \
    -e "s|\${ROLLOUT_TIMEOUT}|${ROLLOUT_TIMEOUT}|g" \
    deploy/rollout-check.yaml \
  | kubectl -n "$NS" replace --force -f - >/dev/null
say "watching in-cluster; runner is free"

# Surface what happened, so the workflow can report it without re-deriving it. GITHUB_OUTPUT is only
# set when running under Actions; skipped for a hand-run.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "component=${COMPONENT}"
    echo "version=${VERSION}"
    echo "previous=${PREVIOUS}"
    echo "image=${IMAGE}"
  } >> "$GITHUB_OUTPUT"
fi

echo "==> Deploying ${COMPONENT} ${VERSION}  (was: ${PREVIOUS})"
