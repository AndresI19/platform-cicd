#!/usr/bin/env bash
# deploy.sh <component> <version> — roll one component to one version.
#
# Runs INSIDE the runner container, which changes everything about it compared to the host's deploy:
#
#   * No kubeconfig repoint. The host has to re-derive the forwarded apiserver port on every boot,
#     because docker lives in a colima VM and the node's address (192.168.49.2:8443) is unroutable
#     from outside it. This container is ON that network, so the address minikube wrote is simply
#     correct. The workaround three host scripts exist for does not apply here.
#   * No `minikube` CLI, and no side-load. The kubelet PULLS from registry:5000 — so publishing an
#     image is `docker push`, and deploying it is one `kubectl set image`.
#   * No admin credentials. It authenticates as the `deployer` ServiceAccount, which may patch
#     Deployments and create the version-spec writer Pod, and may NOT read Secrets.
set -Eeuo pipefail

COMPONENT="${1:?usage: deploy.sh <component> <version>}"
VERSION="${2:?usage: deploy.sh <component> <version>}"
NS=platform
IMAGE="registry:5000/${COMPONENT}:${VERSION}"

say() { echo "    $*"; }

# --- 1. refuse to deploy an image that is not really there --------------------------------------
# `kubectl set image` will happily accept a tag that does not exist: the Deployment is patched, the
# Pod is scheduled, and it sits in ImagePullBackOff — a failure that surfaces two minutes later as a
# rollout timeout rather than as "you deployed a typo". Ask the registry first.
echo "==> Verifying ${IMAGE} exists"
curl -fsS --cacert /certs/ca.crt \
  "https://registry:5000/v2/${COMPONENT}/manifests/${VERSION}" \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' -o /dev/null \
  || { echo "FATAL: ${IMAGE} is not in the registry — nothing was deployed" >&2; exit 1; }
say "present"

# --- 2. remember what we are replacing ----------------------------------------------------------
# The fallback version, made explicit. `kubectl rollout undo` can do this itself, but recording it
# means the failure message can NAME what it reverted to instead of saying "undone".
PREVIOUS="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
say "currently running ${PREVIOUS}"

# --- 3. the deploy ------------------------------------------------------------------------------
echo "==> Rolling ${COMPONENT} → ${VERSION}"
kubectl -n "$NS" set image "deploy/${COMPONENT}" "${COMPONENT}=${IMAGE}"

# The rollout is where a bad image actually announces itself. A failure here is not an error to
# report and walk away from — it is a site that is half-deployed, so it reverts.
if ! kubectl -n "$NS" rollout status "deploy/${COMPONENT}" --timeout=300s; then
  echo "!!! rollout failed — reverting to ${PREVIOUS}" >&2
  kubectl -n "$NS" rollout undo "deploy/${COMPONENT}"
  kubectl -n "$NS" rollout status "deploy/${COMPONENT}" --timeout=180s || true
  echo "FATAL: ${COMPONENT} ${VERSION} failed to roll out; reverted to ${PREVIOUS}" >&2
  exit 1
fi
say "rolled out"

# --- 4. what is actually running now ------------------------------------------------------------
# Read it back rather than trusting the command that set it. Every silent failure this platform has
# had — the units that were never installed, `minikube image load` no-oping, /version reporting
# "snapshot" forever — was a step that reported success without being checked.
LIVE="$(kubectl -n "$NS" get deploy "$COMPONENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$LIVE" = "$IMAGE" ] || { echo "FATAL: expected ${IMAGE}, cluster says ${LIVE}" >&2; exit 1; }

echo "==> Deployed ${COMPONENT} ${VERSION}"
