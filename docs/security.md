# Security

The runner builds images, so it holds the docker socket — **root-equivalent on the colima VM**. That
cannot be taken away without stopping it building. So the model is not "lock down the socket"; it is
**fence everything else**, and control who can trigger a job.

## Who can trigger a job

- The runner is registered to **this repo alone** (self-hosted runners are per-repository on a personal
  account). No app repo, and no fork of one, can send it a job.
- This repo is **private**, so it has no fork PRs — the attack that makes self-hosted runners on public
  repos dangerous.
- Jobs arrive only via `repository_dispatch` from an app repo's `release.yml`, which runs on GitHub's
  VMs and only after a protected-branch merge with green checks.

The `runs-on: [self-hosted, platform]` label is the mechanism: a job without it is never *offered* to
this runner, so there is nothing to block at runtime.

## It cannot read the host

Colima mounts exactly **one** host directory into the VM (`.platform-vm/certs`, three certificate
files). Everything else — `~/.ssh`, the Cloudflare tunnel token, the sealed-secrets master key — does
not exist inside the VM, so **no container a job starts can bind-mount it**. A `docker run -v /home/…`
sees an empty directory.

This is why the kubeconfig is passed as an **env var, not a mount** (see
[Runner](runner.md#the-two-credentials)): a mount would be the one thing that widens that window.

## The deployer identity

The runner authenticates as the `deployer` ServiceAccount (defined in
`platform-orchestration/k8s/bootstrap/deployer-rbac.yaml`), **not** an admin kubeconfig — the admin
client certs live under `~/.minikube`, outside the mount. It is not cluster-admin: it cannot touch
Roles, RoleBindings, ServiceAccounts or SealedSecrets (bootstrap, applied by the human out-of-band), so
a job cannot grant itself more.

**The secrets trade.** The deploy is `helm upgrade`, and Helm keeps its release state in a Secret — so
the identity is granted `secrets`. That grant cannot be narrowed to only the release Secret, so it also
lets a job read the Postgres passwords, the auth signing key, and the tunnel token. This **widens** the
original "the deployer cannot read Secrets" boundary, accepted because this is a single-developer
platform on one trusted machine — the threat that boundary guarded (a shared or hosted runner
exfiltrating secrets) does not apply. On a hosted runner you would instead point Helm's storage at a
tightly-scoped namespace (or a non-Secret backend) and keep app secrets off-limits.

What it may do: server-side-apply the release's Deployments, ReplicaSets, Services, ConfigMaps and
Ingress; create the in-cluster rollout-check Job (which runs as this same identity); watch a rollout;
and read/write the release Secret. (`watch` is not optional: the rollout-check Job's `kubectl rollout
status` opens a watch, and without it a rollout is read as failed and rolled back — see
[Troubleshooting → False rollback](troubleshooting.md#false-rollback-missing-rbac-watch).)

## The two tokens

Both are fine-grained, both scoped to **platform-cicd only** — a token's scope is what it can *act on*,
not where it is *stored*.

| Token | Stored in | Acts on | Permission |
| --- | --- | --- | --- |
| registration | `runner/.env` on this machine | platform-cicd (register the runner) | Administration: R/W |
| dispatch (`CICD_DISPATCH_TOKEN`) | each app repo's GitHub secrets | platform-cicd (POST a dispatch) | Contents: R/W |

The dispatch token lives in a **public** app repo's secrets but only ever calls one endpoint on
platform-cicd — so it needs write access to platform-cicd and **none** to the repo it is stored in (a
workflow reads its own repo via `GITHUB_TOKEN`). Scoping it to "all repos" is the danger: a leak from a
public repo would then reach your whole account.

## No secrets in git

The runner's certs and CA are generated at runtime by `platform-orchestration/k8s/registry.sh`, never
committed. `runner/.env` (both tokens + the kubeconfig) is gitignored. Certificates are public by
definition; the keys only ever exist on disk.
