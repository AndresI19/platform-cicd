# Deploy pipeline

What runs, in order, from a merge to a live rollout. Two halves: the app repo's `release.yml` (on
GitHub's VMs) and this repo's `release.yml` (on the runner).

## The app-repo half

Each app repo carries a `release.yml` triggered by `push: main`. It does **not** deploy — it computes
the version and dispatches.

```yaml
on: { push: { branches: [main] } }   # a merge; main is protected, so CI is already green
```

Two things are load-bearing:

**It reads the tag, it does not compute one.** Each repo's `version-tag.yml` cuts a tag on every merge.
`release.yml` waits for that tag on `$GITHUB_SHA` and uses exactly it (`git tag --points-at`). Computing
the next version independently **races** the tagger — the loser lands one higher and waits forever for a
tag that never comes. See [Troubleshooting → Version race](troubleshooting.md#version-race-predicted-instead-of-read).

**It rides `push: main`, not `push: tags`.** A tag pushed by a workflow using `GITHUB_TOKEN` does not
trigger another workflow (GitHub's recursion guard), so a `push: tags` trigger would never fire. Both
jobs hang off the same merge event.

It then `repository_dispatch`es to this repo, once per component:

```yaml
for c in <components>:
  POST /repos/AndresI19/platform-cicd/dispatches
    { event_type: release, client_payload: { component: c, repo, version } }
```

This uses `CICD_DISPATCH_TOKEN` — a fine-grained token scoped to **platform-cicd only**,
`Contents: read+write`. `GITHUB_TOKEN` cannot dispatch across repos. See
[Security → The two tokens](security.md#the-two-tokens).

## This repo's half — `release.yml`

Triggered by `repository_dispatch: [release]`, runs on `[self-hosted, platform]`. No concurrency group
— see [Architecture → Serialization](architecture.md#serialization-the-runner-is-the-queue).

1. **Checkout** three things: the deploy scripts (this repo), the component's source at the exact tag,
   and the Helm chart from `platform-orchestration@main` (`helm upgrade` needs the chart to render).
2. **Build and publish** — [`build.sh`](../deploy/build.sh).
3. **Deploy** — [`deploy.sh`](../deploy/deploy.sh).
4. **Report the outcome** — `if: always()`, posts ✅/❌ to Discord and writes a job summary.

## Build

`build.sh <component> <version> <src>` carries a **component registry** — the one place that knows how
each component builds:

| Component | Context | Quirk |
| --- | --- | --- |
| `home` | `src/portfolio-home` | — |
| `platform-auth` | `src/platform-auth` | — |
| `quiz` | `src` | `--build-arg BASE_PATH=/cloud-developer-quiz/` |
| `vmcp` | `src` | — |
| `rs-mcp-server` | `src` | — |
| `fvt-traffic` | `src` | `-f Dockerfile.fvt` · **built only, not deployed** — runs on the host (`fvt/`) |

Every image takes `VERSION` / `GIT_SHA` / `BUILD_DATE` build-args. `VERSION` is baked into a `VERSION`
file the app serves from `/version`. The image is pushed to `registry:5000/<component>:<version>` and
also tagged `:latest` — a pointer for humans; **nothing deploys `:latest`** (a mutable tag is the bug
the content-addressed scheme exists to kill). Builds run under **BuildKit via buildx**; an unknown
component fails loudly.

## Deploy

`deploy.sh <component> <version>`, running as the scoped `deployer` ServiceAccount:

1. **Verify the image is in the registry** — by the **tags list**, not a manifest fetch. A manifest
   request pins a media type, and a registry answers `404` for a type it does not have stored; docker
   pushes OCI manifests, so asking for the old schema2 type reads a present image as missing. See
   [Troubleshooting → 404 on a present image](troubleshooting.md#404-on-a-present-image).
2. **Refuse a component that ships no values.** Each service's Deployment/Service spec lives in its own
   repo as `deploy/<component>.values.yaml`. Without this check the upgrade would "succeed" against the
   generic chart's bare defaults and deploy a component-shaped nothing.
3. **Vendor the library subchart** (`helm dependency build`). `charts/service` depends on `platform-lib`
   and orchestration gitignores the vendored copy, so the fresh checkout cannot render until this runs.
4. **`helm upgrade --install <component>`** — that component's **own release**, rendered from
   orchestration's generic `charts/service` plus the step-2 values file, with only `image.repo/tag/version`
   set per deploy.

   **No `--reuse-values`**, and its absence is the point: the umbrella release rendered every app from
   one `.Values.apps` map, so a per-component deploy needed that flag to avoid wiping siblings' tags —
   which made the *release*, not the chart, the source of truth. A key deleted from the chart lived on in
   release state forever; a key added never reached an existing release. Now the values come from the
   component's own repo in full on every deploy: the file **is** the state, nothing accumulates.

   **`--take-ownership`** so the first per-component deploy adopts objects a previous release held, and
   **`--force-conflicts`** because legacy field managers (`kubectl set image`, the old umbrella) own the
   image field and Helm 4's server-side apply must be told to take it. Both stay on: CI is authoritative,
   and a manual hotfix must never make the next deploy fail.
5. **No `--wait`.** The upgrade returns once the manifests are applied. **Exit 0 means APPLIED AND BEING
   WATCHED, not "rolled out"** — see [Asynchronous rollout](#asynchronous-rollout).
6. **Read the running image back** and assert it matches — never trust the command that set it. This
   asserts the **spec** Helm just wrote; readiness is the Job's job, not the runner's.

The kubelet then pulls `registry:5000/<component>:<version>` on its own — no side-load. Every deploy is a
rollback-able Helm revision, **per component**: `helm history quiz`, `helm rollback quiz <n>` revert that
service alone. The acceptance test is the component's own `/version` endpoint.

### Asynchronous rollout

The runner is a single, ephemeral, serialized worker: every second it watches a rollout is a second the
next release waits in the queue. So `deploy.sh` applies and then launches `deploy/rollout-check.yaml` — a
Job that watches the rollout **in the cluster**, where watching is free. The runner is released in ~0.5s.

This is safe **because of** RollingUpdate: an image that never becomes ready cannot displace the healthy
old pods, so a failed deploy degrades to "the old version is still serving", never an outage. The Job
turns a *silent* stuck rollout into a loud, reverted one — `helm rollback` (which keeps Helm's state and
the cluster in sync, unlike `kubectl rollout undo`), then a Discord post.

So when reading a release run: a green ✅ is the **apply**. A rollout that starts and then stalls cannot
be reported by the workflow — the runner is long gone — so that failure arrives from the Job, minutes
later, in Discord. A red ❌ from the workflow means the deploy never started (bad manifest, image not in
the registry) and nothing changed.

## Verifying a deploy

`/api/versions` on the home page aggregates every component's `/version`. After a deploy the component
reports its new version there and on its own card. That endpoint is also the drift check: compare it to
the latest git tag.
