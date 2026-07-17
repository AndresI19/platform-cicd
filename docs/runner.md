# The runner

A container on minikube's docker network that registers with GitHub, takes one job, and exits.

## Ephemeral, and why

The runner registers with `--ephemeral`: it runs **one job**, de-registers, and exits. `compose`
(`restart: always`) brings a fresh one back — nothing carries between jobs, the same clean-slate
property a GitHub-hosted VM has. The entrypoint also **wipes per-run state** (`_work`, `.runner`,
`.credentials`) on every start.

Two settings keep it stable, both learned the hard way (see [Troubleshooting](troubleshooting.md)):

- **`--disableupdate`** — the runner must never self-update. A self-update rewrites `bin/` in the
  persistent container layer, and a half-applied one leaves the process unable to start. The **image**
  is how this runner updates; nothing at runtime touches `bin/`.
- **A pinned `RUNNER_VERSION`** in the Dockerfile — GitHub deprecates old runner versions server-side;
  a deprecated runner connects, is told it "cannot receive messages", and exits, leaving jobs queued
  forever. Bump the ARG when GitHub moves the line.

## What's in the image

| Tool | Why |
| --- | --- |
| `actions/runner` | registers and runs jobs |
| docker CLI + **buildx** | builds images through the mounted socket. buildx is mandatory: the static CLI has no legacy builder, and buildx honors per-Dockerfile `.dockerignore` (which `fvt-traffic` needs) |
| `kubectl` | deploys, reaching the apiserver at its native address |
| `git`, `jq`, `gosu` | checkout, JSON for the Discord payload, dropping root after fixing the socket group |

The build layer cache lives in **colima's daemon**, not the runner — so destroying the runner after
every job costs no build time.

## Networking

`compose.yml` joins the `minikube` docker network as an **external** network (minikube owns it;
compose must not define the node container). From that network the runner reaches:

- `registry:5000` — the image registry, which has no inbound port
- `192.168.49.2:8443` — the apiserver at its **native** address, unroutable from the host

So the runner needs no kubeconfig repoint: it is on the node's network, and the address minikube writes
is simply correct.

## The two credentials

Both live in `runner/.env` (gitignored). `scripts/kubeconfig.sh` mints the second.

- **`GH_PAT`** — a fine-grained token scoped to **this repo only**, `Administration: read+write`. Used
  only to mint a fresh registration token on each start (an ephemeral runner needs a new one every
  time). Not the dispatch token — see [Security](security.md#the-two-tokens).
- **`KUBECONFIG_B64`** — the `deployer` ServiceAccount's kubeconfig, base64'd. Passed as an **env var,
  not a mount**: the VM mounts exactly one host directory, and a kubeconfig mount would widen that
  window. Because Helm stores release state in a Secret, this identity **can read Secrets** — a
  deliberate trade, see [Security → The deployer identity](security.md#the-deployer-identity).

## The docker socket

`compose.yml` mounts `/var/run/docker.sock` — **root-equivalent on the colima VM**. It is how the
runner builds images, and the reason the whole security model fences *everything else*: the narrowed
colima mount and the scoped deployer exist because this socket cannot be taken away. See
[Security](security.md).

The socket's group ID is a property of the VM, not the image, so the entrypoint reads it off the socket
at runtime and adds `runner` to a matching group — hard-coding it would break on a colima base change.

## At boot

`runner/runner.service` is a systemd **user** unit, ordered `After=platform.service` (the runner joins
minikube's network, which only exists once the cluster is up; `Wants=` not `Requires=` so a slow boot
just retries). systemd brings the compose project up at boot and down on stop; docker's `restart:
always` respawns the ephemeral runner between jobs.

Like the platform's own units, it needs `loginctl enable-linger` or it will not start at boot. See the
README's *Run & connect*.
