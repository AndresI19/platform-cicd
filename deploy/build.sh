#!/usr/bin/env bash
# build.sh <component> <version> <source-dir> — build the image and publish it to the registry.
#
# The build runs through the docker socket mounted into the runner, so it is colima's daemon doing the
# work. Two consequences worth knowing:
#   * the layer cache lives in that daemon, NOT in this container — so destroying the runner after
#     every job (--ephemeral) costs no build time at all.
#   * that daemon already trusts our CA (k8s/registry.sh installs it), so `docker push` needs no
#     certificate here. The curl in deploy.sh does, which is why /certs is mounted.
set -Eeuo pipefail

COMPONENT="${1:?usage: build.sh <component> <version> <source-dir>}"
VERSION="${2:?}"
SRC="${3:?}"

IMAGE="registry:5000/${COMPONENT}:${VERSION}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="$(git -C "$SRC" rev-parse --short HEAD)"

# The same three OCI args every image in this platform takes. VERSION is the one with teeth: the
# Dockerfile writes it to a VERSION file that the app reads at startup and serves from /version — so
# the running container can say what it is, and the home page can ask.
args=(--build-arg "VERSION=${VERSION}"
      --build-arg "GIT_SHA=${GIT_SHA}"
      --build-arg "BUILD_DATE=${BUILD_DATE}")

echo "==> Building ${IMAGE}"
case "$COMPONENT" in
  # BASE_PATH must be identical at build time and run time: Vite bakes the prefix into asset URLs at
  # build, Express mounts the routes beneath it at run. A mismatch gives a page whose assets all 404.
  quiz) docker build -t "$IMAGE" "${args[@]}" --build-arg BASE_PATH=/cloud-developer-quiz/ "$SRC" ;;
  *)    docker build -t "$IMAGE" "${args[@]}" "$SRC" ;;
esac

# :latest is a POINTER FOR HUMANS and nothing else. Nothing deploys it — a mutable tag is the exact
# bug this platform's deploy was rewritten to kill (`:latest` + IfNotPresent means the kubelet never
# looks for a newer image, and the Pod spec never changes, so `apply` sees nothing to do).
docker tag "$IMAGE" "registry:5000/${COMPONENT}:latest"

echo "==> Pushing"
docker push -q "$IMAGE"
docker push -q "registry:5000/${COMPONENT}:latest"
echo "    ${IMAGE}"
