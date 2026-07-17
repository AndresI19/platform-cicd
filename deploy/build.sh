#!/usr/bin/env bash
# build.sh <component> <version> <source-dir> — build the image and publish it to the registry.
#
# The build runs through the docker socket mounted into the runner, so colima's daemon does the work.
# The layer cache lives in that daemon, NOT this container, so --ephemeral costs no build time. That
# daemon already trusts our CA (k8s/registry.sh installs it), so `docker push` needs no cert here (the
# curl in deploy.sh does, which is why /certs is mounted).
set -Eeuo pipefail

# Force BuildKit. Without buildx the legacy builder reads only the root .dockerignore, ignoring
# per-Dockerfile ignore files. fvt-traffic depends on those: the root .dockerignore strips README.md and
# Dockerfile.fvt.dockerignore un-strips it, so the legacy builder fails its `COPY README.md`.
export DOCKER_BUILDKIT=1

COMPONENT="${1:?usage: build.sh <component> <version> <source-dir>}"
VERSION="${2:?}"
SRC="${3:?}"   # the app repo, checked out at the tag. May hold ONE component or several.

# The in-cluster registry every image is pushed to and deploy.sh pulls from. Overridable for a
# hand-run against an alternate registry; the default is the only one CI ever uses.
REGISTRY="${REGISTRY:-registry:5000}"
IMAGE="${REGISTRY}/${COMPONENT}:${VERSION}"
LATEST="${REGISTRY}/${COMPONENT}:latest"   # the human pointer tag, retagged and pushed below
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="$(git -C "$SRC" rev-parse --short HEAD)"

# The three OCI args every image takes. VERSION has teeth: the Dockerfile writes it to a VERSION file
# the app reads at startup and serves from /version, so the running container can say what it is.
BUILD_ARGS=(--build-arg "VERSION=${VERSION}"
            --build-arg "GIT_SHA=${GIT_SHA}"
            --build-arg "BUILD_DATE=${BUILD_DATE}")

# The component registry — the single place that knows how each component is built: WHERE its context
# sits in the checkout, and any quirk (a build-arg, an alternate Dockerfile). This is what lets one repo
# hold two components (project-platform = home + platform-auth; rs-mcp-server = server + fvt-traffic).
# The component name derives all of it, which is why the payload carries only the name.
CONTEXT="$SRC"          # build context, defaults to the repo root
DOCKERFILE=""           # explicit -f Dockerfile, empty = the context's own Dockerfile
EXTRA_ARGS=()           # per-component build-args
case "$COMPONENT" in
  home)          CONTEXT="$SRC/portfolio-home" ;;
  platform-auth) CONTEXT="$SRC/platform-auth" ;;
  # BASE_PATH must be identical at build time and run time: Vite bakes the prefix into asset URLs at
  # build, Express mounts the routes beneath it at run. A mismatch gives a page whose assets all 404.
  quiz)          EXTRA_ARGS=(--build-arg BASE_PATH=/cloud-developer-quiz/) ;;
  vmcp)          : ;;  # repo root, no quirks
  rs-mcp-server) : ;;  # repo root, the production Dockerfile
  # The traffic generator ships from rs-mcp-server's repo off a separate Dockerfile — deliberately not
  # the production image (no test deps in the thing that serves MCP).
  fvt-traffic)   DOCKERFILE="$SRC/Dockerfile.fvt" ;;
  *) echo "FATAL: unknown component '${COMPONENT}' — add it to the registry in build.sh" >&2; exit 1 ;;
esac
[ -n "$DOCKERFILE" ] && BUILD_ARGS+=(-f "$DOCKERFILE")

echo "==> Building ${IMAGE}  (context: ${CONTEXT}${DOCKERFILE:+, -f ${DOCKERFILE##*/}})"
docker build -t "$IMAGE" "${BUILD_ARGS[@]}" "${EXTRA_ARGS[@]}" "$CONTEXT"

# :latest is a POINTER FOR HUMANS. Nothing deploys it — a mutable tag is the exact bug this deploy was
# rewritten to kill (`:latest` + IfNotPresent → kubelet never looks for a newer image, Pod spec never
# changes, `apply` sees nothing to do).
docker tag "$IMAGE" "$LATEST"

echo "==> Pushing"
docker push -q "$IMAGE"
docker push -q "$LATEST"
echo "    ${IMAGE}"
