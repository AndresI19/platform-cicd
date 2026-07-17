#!/usr/bin/env bash
# Register with GitHub, take exactly one job, de-register, exit. compose restarts us and we do it again.
# Nothing carries between jobs.
#
# No job is lost in the gap between exit and restart: GitHub holds a DURABLE QUEUE. A job waits there
# until a runner with matching labels takes it — a missed moment costs latency, never work.
set -Eeuo pipefail

: "${GH_REPO:?set GH_REPO=owner/repo}"
: "${GH_PAT:?set GH_PAT — a fine-grained token, this repo only, Administration: read+write}"

# --- the docker socket ---------------------------------------------------------------------------
# Mounted from the colima VM, owned by a group whose GID is a property of that VM, not this image.
# Hard-coding the GID would break the day colima's base image changes it. So: read the GID off the
# socket and create a matching group here.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID="$(stat -c %g /var/run/docker.sock)"
  getent group "$SOCK_GID" >/dev/null || groupadd -g "$SOCK_GID" dockersock
  usermod -aG "$SOCK_GID" runner
fi

# --- the cluster credential ----------------------------------------------------------------------
# Passed as base64 in the environment, NOT bind-mounted — deliberately. The VM mounts exactly one host
# directory; adding a kubeconfig mount would widen the one window a CI job has into the host. An env
# var needs no window.
#
# The identity is the `deployer` ServiceAccount. The Helm migration granted it `secrets` (Helm keeps
# release state in a Secret), so a job here CAN read the app secrets — a deliberate trade on this
# single-dev machine. See docs/security.md.
if [ -n "${KUBECONFIG_B64:-}" ]; then
  install -d -o runner -g runner -m 700 /home/runner/.kube
  printf '%s' "$KUBECONFIG_B64" | base64 -d > /home/runner/.kube/config
  chown runner:runner /home/runner/.kube/config
  chmod 600 /home/runner/.kube/config
fi

# --- start from a clean slate --------------------------------------------------------------------
# restart: always reuses the SAME container, so the previous run's files are still here. A half-applied
# SELF-UPDATE (see --disableupdate below) leaves bin/ missing Runner.Listener, and every start then
# crash-loops with "No such file or directory". Remove the per-run state so each registration is
# pristine; bin/ and the runner package stay from the image, their only source.
rm -rf /home/runner/_work /home/runner/_diag \
       /home/runner/.runner /home/runner/.credentials* /home/runner/.env 2>/dev/null || true
chown -R runner:runner /home/runner

# --- register ------------------------------------------------------------------------------------
# A registration token lasts an hour and is spent on one registration. An ephemeral runner de-registers
# after every job, so a fresh token is needed on every start — which is why this holds a PAT and mints
# the token itself rather than being handed one that would go stale.
exec gosu runner bash -Eeuo pipefail -c '
  TOKEN="$(curl -fsS -X POST \
      -H "Authorization: Bearer '"$GH_PAT"'" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/'"$GH_REPO"'/actions/runners/registration-token" | jq -r .token)"
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "could not get a registration token — is the PAT scoped to Administration: read+write on '"$GH_REPO"'?" >&2; exit 1; }

  ./config.sh \
    --url "https://github.com/'"$GH_REPO"'" \
    --token "$TOKEN" \
    --name "${RUNNER_NAME:-platform-runner}" \
    --labels self-hosted,platform \
    --work /home/runner/_work \
    --unattended --replace --ephemeral --disableupdate

  # --disableupdate: the runner must NEVER self-update. A self-update rewrites bin/ in the persistent
  # container layer; a half-applied one leaves Runner.Listener missing, so every restart crash-loops
  # with "No such file or directory". The image is how the runner updates here — rebuild it.
  #
  # --ephemeral: run.sh exits after ONE job, de-registered. compose (restart: always) brings us back,
  # and the state wipe above makes that a clean slate. The docker layer cache is untouched — it lives in
  # colima s daemon, not here (no apostrophe: this whole block is inside a single-quoted bash -c).
  exec ./run.sh
'
