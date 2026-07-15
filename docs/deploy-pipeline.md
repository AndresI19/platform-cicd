# Deploy pipeline

What runs, in order, from a merge to a live rollout. Two halves: the app repo's `release.yml`
(on GitHub's VMs) and this repo's `release.yml` (on the runner).

## The app-repo half

Each app repo carries a `release.yml` triggered by `push: main`. It does **not** deploy — it only
computes the version and dispatches.

```yaml
on: { push: { branches: [main] } }   # a merge; main is protected, so CI is already green
```

Two things about it are load-bearing:

**It reads the tag, it does not compute one.** Every repo already has a `version-tag.yml` that cuts a
tag on each merge. `release.yml` waits for that tag to appear on `$GITHUB_SHA` and uses exactly it
(`git tag --points-at`). Computing the next version independently would **race** the tagger — two
"latest + 1" calculations disagree, and whichever runs second lands one higher and then waits forever
for a tag that never comes. See
[Troubleshooting → Version race](troubleshooting.md#version-race-predicted-instead-of-read).

**It rides `push: main`, not `push: tags`.** A tag pushed by a workflow using `GITHUB_TOKEN` does
**not** trigger another workflow (GitHub's recursion guard), so a `push: tags` trigger would never
fire. Both jobs therefore hang off the same merge event.

It then `repository_dispatch`es to this repo, once per component the repo ships:

```yaml
for c in <components>:
  POST /repos/AndresI19/platform-cicd/dispatches
    { event_type: release, client_payload: { component: c, repo, version } }
```

This uses `CICD_DISPATCH_TOKEN` — a fine-grained token scoped to **platform-cicd only**,
`Contents: read+write`. `GITHUB_TOKEN` cannot dispatch across repos, which is why this second token
exists. See [Security → The two tokens](security.md#the-two-tokens).

## This repo's half — `release.yml`

Triggered by `repository_dispatch: [release]`. Runs on `[self-hosted, platform]`. No concurrency
group — see [Architecture → Serialization](architecture.md#serialization-the-runner-is-the-queue).

1. **Checkout** the deploy scripts, and the component's source at the exact tag.
2. **Build and publish** — [`build.sh`](../deploy/build.sh).
3. **Deploy** — [`deploy.sh`](../deploy/deploy.sh).
4. **Report the outcome** — `if: always()`, posts ✅/❌ to Discord and writes a job summary, on
   success as well as failure.

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
| `fvt-traffic` | `src` | `-f Dockerfile.fvt` |

Every image takes `VERSION` / `GIT_SHA` / `BUILD_DATE` build-args. `VERSION` is baked into a `VERSION`
file the app serves from `/version`. The image is pushed to `registry:5000/<component>:<version>` and
also tagged `:latest` (a pointer for humans — **nothing deploys `:latest`**; a mutable tag is the bug
the content-addressed scheme exists to kill).

Builds run under **BuildKit via buildx**. An unknown component fails loudly rather than building the
repo root by accident.

## Deploy

`deploy.sh <component> <version>`, running as the least-privilege `deployer`:

1. **Verify the image is in the registry** — by the **tags list**, not a manifest fetch. A manifest
   request pins a media type, and a registry answers `404` for a type it does not have stored; docker
   pushes OCI manifests, so asking for the old schema2 type reads a present image as missing. See
   [Troubleshooting → 404 on a present image](troubleshooting.md#404-on-a-present-image).
2. **`kubectl set image`** the deployment.
3. **`kubectl rollout status`** — and on failure, **`kubectl rollout undo`**. Fail-closed: a bad
   image reverts to the previous one rather than leaving the site half-deployed.
4. **Read the running image back** and assert it matches — never trust the command that set it.

The kubelet then pulls `registry:5000/<component>:<version>` of its own accord (a consequence of the
new Pod spec) — no side-load. The acceptance test is the component's own `/version` endpoint.

## Verifying a deploy

`/api/versions` on the home page aggregates every component's `/version`. After a deploy, the
component reports its new version there and on its own card. That endpoint is also the drift check:
compare it to the latest git tag.
