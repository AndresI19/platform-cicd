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

# Force BuildKit. The runner's docker CLI has no buildx plugin, so a bare `docker build` falls back to
# the LEGACY builder — which reads only the root .dockerignore and ignores per-Dockerfile ignore files
# (`<Dockerfile>.dockerignore`). fvt-traffic depends on exactly that: the root .dockerignore strips
# README.md, and Dockerfile.fvt.dockerignore un-strips it, so the legacy builder fails its
# `COPY README.md` with "file not found". BuildKit (which colima's daemon supports) reads the
# per-Dockerfile ignore file and builds it correctly — and it is also how the host's deploy.sh always
# built, which is why this only broke once the build moved to the runner.
export DOCKER_BUILDKIT=1

COMPONENT="${1:?usage: build.sh <component> <version> <source-dir>}"
VERSION="${2:?}"
SRC="${3:?}"   # the app repo, checked out at the tag. May hold ONE component or several.

IMAGE="registry:5000/${COMPONENT}:${VERSION}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="$(git -C "$SRC" rev-parse --short HEAD)"

# The same three OCI args every image in this platform takes. VERSION is the one with teeth: the
# Dockerfile writes it to a VERSION file that the app reads at startup and serves from /version — so
# the running container can say what it is, and the home page can ask.
args=(--build-arg "VERSION=${VERSION}"
      --build-arg "GIT_SHA=${GIT_SHA}"
      --build-arg "BUILD_DATE=${BUILD_DATE}")

# The component registry — the single place that knows how each component is built. Two facts per
# component: WHERE its build context sits inside the checkout, and any quirk (a build-arg, an alternate
# Dockerfile). This is what lets one repo hold two components: project-platform is home + platform-auth
# in two subdirectories, and rs-mcp-server is the server plus the fvt-traffic generator off a second
# Dockerfile. The component name is enough to derive all of it, which is why the payload carries only
# the name.
CTX="$SRC"          # build context, defaults to the repo root
DFILE=""            # explicit -f Dockerfile, empty = the context's own Dockerfile
EXTRA=()            # per-component build-args
case "$COMPONENT" in
  home)          CTX="$SRC/portfolio-home" ;;
  platform-auth) CTX="$SRC/platform-auth" ;;
  # BASE_PATH must be identical at build time and run time: Vite bakes the prefix into asset URLs at
  # build, Express mounts the routes beneath it at run. A mismatch gives a page whose assets all 404.
  quiz)          EXTRA=(--build-arg BASE_PATH=/cloud-developer-quiz/) ;;
  vmcp)          : ;;  # repo root, no quirks
  rs-mcp-server) : ;;  # repo root, the production Dockerfile
  # The traffic generator ships from the SAME repo as rs-mcp-server, off a separate Dockerfile — it is
  # deliberately not the production image (no test deps in the thing that serves MCP).
  fvt-traffic)   DFILE="$SRC/Dockerfile.fvt" ;;
  *) echo "FATAL: unknown component '${COMPONENT}' — add it to the registry in build.sh" >&2; exit 1 ;;
esac
[ -n "$DFILE" ] && args+=(-f "$DFILE")

echo "==> Building ${IMAGE}  (context: ${CTX}${DFILE:+, -f ${DFILE##*/}})"
docker build -t "$IMAGE" "${args[@]}" "${EXTRA[@]}" "$CTX"

# :latest is a POINTER FOR HUMANS and nothing else. Nothing deploys it — a mutable tag is the exact
# bug this platform's deploy was rewritten to kill (`:latest` + IfNotPresent means the kubelet never
# looks for a newer image, and the Pod spec never changes, so `apply` sees nothing to do).
docker tag "$IMAGE" "registry:5000/${COMPONENT}:latest"

echo "==> Pushing"
docker push -q "$IMAGE"
docker push -q "registry:5000/${COMPONENT}:latest"
echo "    ${IMAGE}"
