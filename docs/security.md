# Security

The runner builds images, so it holds the docker socket — **root-equivalent on the colima VM**. That
cannot be taken away without stopping it building. So the model is not "lock down the socket"; it is
**fence everything else**, and control who can trigger a job.

## Who can trigger a job

- The runner is registered to **this repo alone** (a self-hosted runner is per-repository on a
  personal account). No app repo, and no fork of one, can send it a job.
- This repo is **private**, so it has no fork PRs at all — the attack that makes self-hosted runners
  on public repos dangerous.
- Jobs arrive only via `repository_dispatch` from an app repo's `release.yml`, which runs on GitHub's
  VMs and only after a protected-branch merge with green checks.

The `runs-on: [self-hosted, platform]` label is the mechanism: a job without that label is never
*offered* to this runner, so there is nothing to block at runtime.

## It cannot read the host

Colima mounts exactly **one** host directory into the VM (`.platform-vm/certs`, three certificate
files). Everything else — `~/.ssh`, the Cloudflare tunnel token in `.env`, the sealed-secrets master
key — does not exist inside the VM, so **no container, including one a job starts, can bind-mount
it**. A `docker run -v /home/…:/x` sees an empty directory.

This is why the kubeconfig is passed as an **env var, not a mount** (see [Runner](runner.md#the-two-credentials)):
adding a mount would be the one thing that widens that window.

## The deployer identity

The runner authenticates to Kubernetes as the `deployer` ServiceAccount (defined in
`platform-orchestration/k8s/base/deployer-rbac.yaml`), **not** an admin kubeconfig. It could not use
the admin one if it wanted to — those client certs live under `~/.minikube`, outside the mount. The
boundary forced a least-privilege identity.

What it may do: `get/list/watch/patch/update` Deployments and ReplicaSets; `get/list/watch/create/delete`
Pods and `create` pod/exec (to write the version spec). What it may **not** do:

```
kubectl auth can-i get secrets -n platform --as=system:serviceaccount:platform:deployer
→ no
```

So a job on this runner cannot read the Postgres passwords, the Cloudflare tunnel token, or the auth
signing key — all of which live as Secrets in the namespace. Deploying an image does not require
reading them, so it cannot. (`watch` is not optional: `kubectl rollout status` opens a watch, and
without it deploys falsely roll back — see
[Troubleshooting → False rollback](troubleshooting.md#false-rollback-missing-rbac-watch).)

## The two tokens

Both are fine-grained, both scoped to **platform-cicd only** — a token's scope is about what it can
*act on*, not where it is *stored*.

| Token | Stored in | Acts on | Permission |
| --- | --- | --- | --- |
| registration | `runner/.env` on this machine | platform-cicd (register the runner) | Administration: R/W |
| dispatch (`CICD_DISPATCH_TOKEN`) | each app repo's GitHub secrets | platform-cicd (POST a dispatch) | Contents: R/W |

The dispatch token lives in a **public** app repo's secrets but only ever calls one endpoint on
platform-cicd — so it needs write access to platform-cicd and **none** to the repo it is stored in
(a workflow reads its own repo via the built-in `GITHUB_TOKEN`). Scoping it broadly is the danger:
"all repos" would mean a leak from a public repo reaches your whole account.

## No secrets in git

The runner's certs and CA are generated at runtime by `platform-orchestration/k8s/registry.sh`, never
committed. `runner/.env` (both tokens + the kubeconfig) is gitignored. Certificates are public by
definition; the keys only ever exist on disk.
