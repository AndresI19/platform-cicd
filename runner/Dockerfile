# The self-hosted runner: the only consumer that can reach the registry and the cluster.
#
# It runs as a CONTAINER rather than natively under its own unix user, and the reason is the colima
# mount. The VM mounts exactly one host directory, so a container here cannot see ~/.ssh, the
# Cloudflare tunnel token in .env, or the sealed-secrets master key — those paths do not exist inside
# the VM at all. That boundary is what makes a container acceptable without a dedicated unix account.
FROM ubuntu:24.04

ARG RUNNER_VERSION=2.328.0
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

RUN useradd -m -u 1001 runner
WORKDIR /home/runner

RUN curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      | tar -xz \
 && ./bin/installdependencies.sh \
 && chown -R runner:runner /home/runner

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
