# The self-hosted runner: the only consumer that can reach the registry and the cluster.
#
# It runs as a CONTAINER rather than natively under its own unix user, and the reason is the colima
# mount. The VM mounts exactly one host directory, so a container here cannot see ~/.ssh, the
# Cloudflare tunnel token in .env, or the sealed-secrets master key — those paths do not exist inside
# the VM at all. That boundary is what makes a container acceptable without a dedicated unix account.
FROM ubuntu:24.04

# Keep current. GitHub deprecates old runner versions SERVER-SIDE: a runner too far behind connects,
# is told "deprecated and cannot receive messages", and exits — jobs then queue forever with no
# runner able to accept them. Because we build with --disableupdate (the runner must never rewrite its
# own bin/), staying current is this ARG's job. Bump it when GitHub starts rejecting the pinned one.
ARG RUNNER_VERSION=2.335.1
ENV DEBIAN_FRONTEND=noninteractive

# curl/jq: fetch the registration token. git: check the app repo out. gosu: drop root after fixing the
# docker socket's group (the runner refuses to run as root, and rightly).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq git gosu tar gzip libicu74 \
 && rm -rf /var/lib/apt/lists/*

# The docker CLI only — NOT a daemon. It talks to colima's daemon over the mounted socket, which is
# also what gives builds a warm layer cache that survives this container being destroyed after every
# job. Ephemerality therefore costs no build time.
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-28.0.1.tgz \
      | tar -xz -C /usr/local/bin --strip-components=1 docker/docker

# kubectl, to talk to the apiserver at its NATIVE address (192.168.49.2:8443) — reachable from this
# container because it joins minikube's docker network, and unreachable from the host, which is the
# whole reason three scripts on the host exist to repoint kubeconfig.
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl

# buildx — the BuildKit builder, installed as a docker CLI plugin. The static docker CLI above ships
# NO build plugins, and modern `docker build` requires buildx: the legacy builder is gone, so a bare
# build (or DOCKER_BUILDKIT=1) errors with "buildx component is missing". buildx is needed for its own
# sake too — it honors per-Dockerfile ignore files (Dockerfile.fvt.dockerignore), which the legacy
# builder never read, and which fvt-traffic's `COPY README.md` depends on. The "default" builder it
# uses is backed by colima's daemon over the mounted socket, so builds land in that daemon and push.
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL "https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64" \
      -o /usr/local/lib/docker/cli-plugins/docker-buildx \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

RUN useradd -m -u 1001 runner
WORKDIR /home/runner

RUN curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      | tar -xz \
 && ./bin/installdependencies.sh \
 && chown -R runner:runner /home/runner

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
