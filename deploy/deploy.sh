#!/usr/bin/env bash
# deploy.sh <component> <version> [src] — roll one component to one version, via Helm.
#
# Runs INSIDE the runner container, as the `deployer` ServiceAccount. Two facts from the chart split
# shape this script:
#
#   * ONE RELEASE PER COMPONENT. The old umbrella `platform` release rendered every app from one
#     `.Values.apps` map, so a per-component deploy needed `--reuse-values` to avoid wiping siblings'
#     image tags — which made the RELEASE, not the chart's values.yaml, the source of truth: a key
#     deleted from the chart lived on in release state forever, a key added never reached an existing
#     release. That flag is gone. The component's values now come from its own repo, in full, every
#     deploy — the file IS the state, nothing accumulates.
#   * NO --wait. The runner is a single, ephemeral, serialized worker: every second it watches a rollout
#     is a second the next release waits in the queue. So the upgrade returns once the manifests are
#     applied, and a Job (rollout-check.yaml) watches the rollout IN THE CLUSTER, where watching is free.
#
# WHAT SUCCESS MEANS: exit 0 means APPLIED AND BEING WATCHED, not "rolled out". RollingUpdate makes that
# safe — a new image that never becomes ready does not displace the healthy old pods, so a failed deploy
# degrades to "the old version is still serving", never an outage. The Job turns a silent stall into a
# loud, reverted one and pings Discord. release.yml says "deploying": the ✅ is the apply, the ❌ that may
# follow comes from the Job minutes later.
#
# No kubeconfig repoint (this container is ON minikube's network, so the native apiserver address is
# correct); the image is PULLED from registry:5000 (no side-load). fvt-traffic is NOT a chart app — it
# runs on the host, and release.yml never calls this script for it.
set -Eeuo pipefail

COMPONENT="${1:?usage: deploy.sh <component> <version> [src]}"
VERSION="${2:?usage: deploy.sh <component> <version> [src]}"
SRC="${3:-src}"
NAMESPACE=platform
# The release IS the component now — which is also why rollout-check.yaml can `helm rollback ${COMPONENT}`.
RELEASE="$COMPONENT"
# The generic service chart, checked out by release.yml from platform-orchestration@main. It carries no
# per-service values; everything specific comes from the app repo's file below.
CHART="${CHART:-orchestration/charts/service}"
# The component's Deployment/Service spec, owned by the repo that ships it — the half of the split that
# moved OUT of orchestration.
VALUES="${VALUES:-${SRC}/deploy/${COMPONENT}.values.yaml}"
# The in-cluster registry build.sh pushed to. Overridable for a hand-run, like CHART/VALUES above.
REGISTRY="${REGISTRY:-registry:5000}"
IMAGE="${REGISTRY}/${COMPONENT}:${VERSION}"
# The running-image field on a Deployment — read twice below (before and after the upgrade), so the
# jsonpath is written once here.
RUNNING_IMAGE_PATH='{.spec.template.spec.containers[0].image}'
# kubectl + helm in one small image for the check Job. Pinned to the cluster's own minor — `kubectl
# rollout status` is that Job's whole point, and version skew is not a thing to discover there.
K8S_IMAGE="${K8S_IMAGE:-alpine/k8s:1.35.1}"
# Under activeDeadlineSeconds (420) in rollout-check.yaml, so the timeout fires, not the kill.
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"

say() { echo "    $*"; }

# --- 1. refuse to deploy an image that is not really there --------------------------------------
# A bad tag would sit in ImagePullBackOff and surface as a rollout-check failure minutes later rather
# than "you deployed a typo". Check the TAGS LIST, not the manifest endpoint: a manifest request pins an
# Accept media type and a registry answers 404 (not 406) for a type it lacks — docker 28 pushes OCI, so
# asking for schema2 reads a present image as missing. The tags list has no such ambiguity.
echo "==> Verifying ${IMAGE} exists"
curl -fsS --cacert /certs/ca.crt "https://${REGISTRY}/v2/${COMPONENT}/tags/list" \
  | grep -q "\"${VERSION}\"" \
  || { echo "FATAL: ${IMAGE} is not in the registry — nothing was deployed" >&2; exit 1; }
say "present"

# --- 2. refuse to deploy a component that ships no values ---------------------------------------
# Without this the helm upgrade would "succeed" against the chart's bare defaults (no real service) and
# deploy a component-shaped nothing. A repo that adds a component and forgets its values file is told so.
[ -f "$VALUES" ] || {
  echo "FATAL: ${COMPONENT} has no deploy values at ${VALUES} — nothing was deployed" >&2
  echo "       the repo that ships ${COMPONENT} must commit that file (see platform-orchestration/charts/service)" >&2
  exit 1
}
say "values: ${VALUES}"

# --- 3. vendor the library subchart ---------------------------------------------------------------
# charts/service declares a `platform-lib` dependency (file://../lib), and orchestration gitignores
# `charts/*/charts/` — the vendored copy is BUILT, never committed. So the fresh checkout cannot render
# until this runs; without it every deploy dies on "found in Chart.yaml, but missing in charts/
# directory". It resolves from the adjacent path — no network, no repo to add.
helm dependency build "$CHART" >/dev/null 2>&1 \
  || { echo "FATAL: could not vendor ${CHART}'s platform-lib dependency" >&2; exit 1; }

# --- 4. remember what we are replacing ----------------------------------------------------------
# So the check Job's failure message can NAME what it reverted to.
PREVIOUS="$(kubectl -n "$NAMESPACE" get deploy "$COMPONENT" \
  -o jsonpath="$RUNNING_IMAGE_PATH" 2>/dev/null || echo '?')"
say "currently running ${PREVIOUS}"

# --- 5. the deploy ------------------------------------------------------------------------------
# --install: the first per-component deploy CREATES this release (the umbrella owned these objects).
# --take-ownership: adopts objects the umbrella release still holds — without it Helm refuses to touch a
#   resource annotated for another release.
# --force-conflicts: legacy field managers (`kubectl set image`, the old umbrella) own fields Helm 4's
#   server-side apply must be told to take. Both flags stay on: CI is authoritative, and a manual hotfix
#   must never make the next deploy fail.
# No --wait: step 6 launches the watcher. No --reuse-values: see the header.
echo "==> helm upgrade ${RELEASE}: ${COMPONENT} → ${VERSION}"
if ! helm upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" \
      --set "image.repo=${REGISTRY}/${COMPONENT}" \
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
# says nothing about readiness, which is deliberately the Job's job.
LIVE="$(kubectl -n "$NAMESPACE" get deploy "$COMPONENT" \
  -o jsonpath="$RUNNING_IMAGE_PATH")"
[ "$LIVE" = "$IMAGE" ] || { echo "FATAL: expected ${IMAGE}, cluster says ${LIVE}" >&2; exit 1; }

# sed, not envsubst: the runner image has no gettext-base, and runner.service brings the container up
# with `compose up -d` (never --build), so a script that needed a new package would fail every release
# until someone rebuilt the image by hand. sed is in every image there will ever be.
#
# Substituting EXACTLY these five is load-bearing: rollout-check.yaml's container reads $WEBHOOK at
# runtime, inside the pod, from a secret. A blanket substitution would replace it with the runner's empty
# value and silently disable the alert.
echo "==> Launching ${COMPONENT}-rollout-check (${ROLLOUT_TIMEOUT})"
sed -e "s|\${COMPONENT}|${COMPONENT}|g" \
    -e "s|\${IMAGE}|${IMAGE}|g" \
    -e "s|\${PREVIOUS}|${PREVIOUS}|g" \
    -e "s|\${K8S_IMAGE}|${K8S_IMAGE}|g" \
    -e "s|\${ROLLOUT_TIMEOUT}|${ROLLOUT_TIMEOUT}|g" \
    deploy/rollout-check.yaml \
  | kubectl -n "$NAMESPACE" replace --force -f - >/dev/null
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
