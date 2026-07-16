#!/usr/bin/env bash
# deploy.sh <component> <version> — roll one component to one version, via Helm.
#
# Runs INSIDE the runner container, as the `deployer` ServiceAccount. What changed with the platform's
# move off kustomize:
#
#   * The deploy is `helm upgrade`, not `kubectl set image`. Image tags live in the Helm RELEASE
#     (server-side state), so there is nothing in a committed file for a later `apply` to revert — the
#     old kustomize pins-vs-set-image conflict is gone. Every deploy is a versioned, rollback-able
#     release revision, and the version-writer hook refreshes platform-version.json on EVERY one (the
#     kubectl-set-image path never did, so /version silently drifted from what was running).
#   * --rollback-on-failure replaces the hand-rolled `rollout undo`: a failed upgrade rolls the release back to the
#     previous revision on its own. Because each component is its own upgrade, that reverts only the
#     failing component, not ones already deployed earlier in the same release batch.
#   * --reuse-values keeps every OTHER component's last-deployed image, so a per-component deploy leaves
#     the release complete and the version spec accurate.
#   * --force-conflicts: a legacy `kubectl set image` leaves field-manager `kubectl-set` owning the
#     image field, and Helm 4's server-side apply must be told to take it. The chart/release IS the
#     source of truth, so forcing is correct — and it keeps CI authoritative over any manual hotfix.
#
# Still true: no kubeconfig repoint (this container is ON minikube's network, so the native apiserver
# address minikube wrote is simply correct), and the image is PULLED from registry:5000 (no side-load).
set -Eeuo pipefail

COMPONENT="${1:?usage: deploy.sh <component> <version>}"
VERSION="${2:?usage: deploy.sh <component> <version>}"
NS=platform
RELEASE=platform
# The chart, checked out by release.yml from platform-orchestration@main into ./orchestration.
# Overridable for a hand-run.
CHART="${CHART:-orchestration/chart}"
IMAGE="registry:5000/${COMPONENT}:${VERSION}"

say() { echo "    $*"; }

# --- 1. refuse to deploy an image that is not really there --------------------------------------
# A bad tag would patch the Pod spec, sit in ImagePullBackOff, and surface as a --wait timeout two
# minutes later rather than "you deployed a typo". Ask the registry first. Check the TAGS LIST, not the
# manifest endpoint: a manifest request pins an Accept media type and a registry answers 404 (not 406)
# for a type it does not have stored — docker 28 pushes OCI, so asking for schema2 reads a present image
# as missing. The tags list has no such ambiguity.
echo "==> Verifying ${IMAGE} exists"
curl -fsS --cacert /certs/ca.crt "https://registry:5000/v2/${COMPONENT}/tags/list" \
  | grep -q "\"${VERSION}\"" \
  || { echo "FATAL: ${IMAGE} is not in the registry — nothing was deployed" >&2; exit 1; }
say "present"

# --- 2. remember what we are replacing ----------------------------------------------------------
# So the failure message can NAME what --rollback-on-failure reverted to, rather than saying "rolled back".
PREVIOUS="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
say "currently running ${PREVIOUS}"

# --- 3. the deploy ------------------------------------------------------------------------------
# --reuse-values keeps the other components' images; only this one's repo/tag/version change. The chart
# app key IS the component name (home, quiz, vmcp, rs-mcp-server, platform-auth). fvt-traffic is NOT a
# chart app — it runs on the host, and release.yml never calls this script for it.
echo "==> helm upgrade ${RELEASE}: ${COMPONENT} → ${VERSION}"
if ! helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
      --set "apps.${COMPONENT}.image.repo=registry:5000/${COMPONENT}" \
      --set "apps.${COMPONENT}.image.tag=${VERSION}" \
      --set "apps.${COMPONENT}.version=${VERSION}" \
      --wait --rollback-on-failure --force-conflicts --timeout 5m; then
  echo "FATAL: ${COMPONENT} ${VERSION} failed to roll out; --rollback-on-failure reverted to ${PREVIOUS}" >&2
  exit 1
fi
say "rolled out"

# --- 4. what is actually running now ------------------------------------------------------------
# Read it back rather than trusting the command that set it — every silent failure this platform has
# had was a step that reported success without being checked.
LIVE="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$LIVE" = "$IMAGE" ] || { echo "FATAL: expected ${IMAGE}, cluster says ${LIVE}" >&2; exit 1; }

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

echo "==> Deployed ${COMPONENT} ${VERSION}  (was: ${PREVIOUS})"
