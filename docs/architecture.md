# Architecture

How a merge becomes a deployment, and why the shape is what it is.

## The flow

```
app repo (merge → main)          this repo                  this machine
─────────────────────────        ────────────────────       ─────────────────────────
version-tag.yml cuts a tag                                   the ONE self-hosted runner
release.yml reads it       ──►  repository_dispatch  ──►     build → push → deploy
  (on GitHub's VMs)                (event: release)          (Discord reports the outcome)
```

Every connection opens **from this machine outward** — the runner long-polls GitHub, the runner
pushes to the registry, the kubelet pulls from the registry. Nothing opens a connection inward, which
is what lets a machine with no inbound port run CI.

## Why a dispatch hop instead of a reusable workflow

**A self-hosted runner can only be scoped to one repository.** Runner groups are an org feature and
this is a personal account, so the app repos cannot share one runner — and a reusable workflow does
not help, because a called workflow's jobs run in the **calling** repo's context and would need a
runner registered there.

So the runner lives in this repo alone, and each app repo `repository_dispatch`es to it. Three
properties follow:

- **No app repo can reach the runner** — not by label, not by a crafted workflow, not from a fork. It
  does not exist in their world.
- **This repo is private**, so it has no fork PRs — the exact attack that makes self-hosted runners on
  *public* repos dangerous.
- **App-repo workflows run only on GitHub's VMs** and only POST a dispatch; they touch nothing here.

## Serialization: the runner is the queue

One runner takes one job at a time off GitHub's job-assignment queue. That *is* the serialization —
five deploys dispatched at once drain one after another.

**Do not add a `concurrency` group to get this.** A concurrency group keeps one running + one pending
job and **cancels the rest**, silently losing deploys. This was shipped once and reverted; see
[Troubleshooting → Concurrency group dropped deploys](troubleshooting.md#concurrency-group-dropped-deploys).
The job-assignment queue never cancels. (A second runner for speed would need a real external lock — a
concurrency group would still drop jobs.)

## One repo, several components

Two app repos ship more than one component: `project-platform` builds `home` + `platform-auth`, and
`rs-mcp-server` builds `rs-mcp-server` + `fvt-traffic`. Their `release.yml` dispatches **once per
component** at the same tag; each becomes its own serialized deploy job.
[`deploy/build.sh`](../deploy/build.sh) knows, per component, where its build context sits and any
quirk — see [Deploy pipeline](deploy-pipeline.md#build).

`fvt-traffic` is **built but not deployed to the cluster**: it runs on the host (`fvt/compose.yml`)
and drives the public API, so the release job builds and pushes its image and skips the helm-deploy.
The host adopts a new image on `systemctl --user restart fvt`.

## Why the deployer is inside the network, not on the host

The runner joins minikube's docker network, so it reaches the apiserver at its **native** address
(`192.168.49.2:8443`) and the registry at `registry:5000` — both unroutable from the host. The
host-side scripts exist to *repoint* kubeconfig around that; the runner needs none of it. See
[Runner → Networking](runner.md#networking).
