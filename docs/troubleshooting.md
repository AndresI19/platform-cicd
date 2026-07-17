# Troubleshooting

Every failure mode this pipeline has hit, what it looked like, and the fix. Most were silent-ish —
which is why every deploy now reports to Discord.

## Concurrency group dropped deploys

**Symptom:** merged several repos at once; some components deployed, others showed `cancelled` runs.

**Cause:** a `concurrency: { group, cancel-in-progress: false }` block. GitHub keeps only **one running
+ one pending** job per group and **cancels the rest** — `cancel-in-progress: false` protects only the
running one, not the pile of pending ones.

**Fix:** removed the group. The single runner already serializes (one job at a time off the
job-assignment queue, which never cancels). See
[Architecture → Serialization](architecture.md#serialization-the-runner-is-the-queue).

## Version race (predicted instead of read)

**Symptom:** the dispatch job hung "waiting for version-tag to push 0.1.14", forever.

**Cause:** the job computed `latest + 1` itself, like `version-tag.yml` does. Two independent
computations disagree — the tagger cut `0.1.13`, this job ran a moment later, saw `0.1.13`, computed
`0.1.14`, and waited for a tag that would never exist.

**Fix:** read the tag `version-tag` actually put on the commit — `git tag --points-at $GITHUB_SHA` —
never predict it.

## 404 on a present image

**Symptom:** `deploy.sh` aborted with "not in the registry", but the image was there.

**Cause:** it verified by fetching the manifest with `Accept: …docker.distribution.manifest.v2+json`. A
registry answers **404** (not 406) for a media type it does not have stored, and docker pushes **OCI**
manifests — so the old schema2 request read a present image as missing.

**Fix:** check the **tags list** (`/v2/<c>/tags/list`), which is media-type agnostic.

## False rollback (missing RBAC `watch`)

**Symptom:** `platform-auth` deployed, then immediately rolled back; log showed `cannot watch resource
"deployments"`.

**Cause:** the `deployer` Role granted `get/list/patch/update` but not **`watch`**. `helm --wait` (and
`kubectl rollout status`) opens a watch; without it the command times out and the deploy is treated as a
failed rollout and reverted. Fast rollouts that finished on the first `get` (home/quiz/vmcp) hid it.

**Fix:** added `watch` to deployments and replicasets in `deployer-rbac.yaml`.

## fvt-traffic build fails on `COPY README.md`

**Symptom:** `COPY failed: … stat README.md: file does not exist`, only for `fvt-traffic`.

**Cause:** `Dockerfile.fvt` copies `README.md`; the root `.dockerignore` strips it, and only
`Dockerfile.fvt.dockerignore` un-strips it. Per-Dockerfile `.dockerignore` files are a **BuildKit**
feature — and the runner's build was using the legacy builder.

**Wrong first fix:** `DOCKER_BUILDKIT=1` alone — the static docker CLI has **no buildx plugin**, so it
errored `buildx component is missing` on *every* build (modern docker has no legacy fallback).

**Fix:** install **buildx** in the runner image. It builds everything and honors the per-Dockerfile
ignore file, backed by colima's daemon over the mounted socket.

## Runner crash-loops after one job

**Symptom:** `./bin/Runner.Listener: No such file or directory`, repeating; the image was fine.

**Cause:** the runner **self-updated**, rewriting `bin/` in the persistent container layer; `restart:
always` reuses that same layer, and a half-applied update leaves `bin/` broken.

**Fix:** `--ephemeral` **+ `--disableupdate`** + a state wipe on each start. The image is how the runner
updates. See [Runner → Ephemeral](runner.md#ephemeral-and-why).

## Runner online but never takes jobs

**Symptom:** jobs stay `queued`; runner logs `Runner version vX is deprecated and cannot receive
messages`, then exits (an exit-0 loop).

**Cause:** GitHub deprecates old runner versions server-side. With `--disableupdate`, a too-old pinned
version can no longer receive work.

**Fix:** bump `RUNNER_VERSION` in `runner/Dockerfile` and rebuild.

## A container mount resolves to an empty directory

**Symptom:** the registry container crash-looped `open /certs/registry.crt: no such file`; the file
existed on the host.

**Cause:** docker lives in the colima VM, which mounts only `.platform-vm`. A bind mount of any other
host path resolves to an **empty directory inside the VM**. (The security boundary working — see
[Security](security.md#it-cannot-read-the-host).)

**Fix:** put anything a container must read under the mounted directory; pass everything else (like the
kubeconfig) as an env var.

## Workflow "file issue" — no step runs

**Symptom:** a run fails instantly as a "workflow file issue", with no logs.

**Cause:** invalid YAML. The usual culprit: a line inside a `run: |` block indented **less** than the
block, which terminates the block scalar and corrupts the rest of the file.

**Fix:** keep every line of a `run:` block at or beyond the block indent (build multi-line strings with
a bash `$'\n'` on one indented line). Validate with a real YAML parser before pushing.

## A deploy silently reverts with no CI failure

**This can no longer happen** — it was the **pins conflict**, fixed by the Helm migration. Historically
a `kubectl apply -k` re-applied the image tags pinned in `kustomization.yaml`, reverting a CD `kubectl
set image` to an old image. Tags now live in the Helm release, not a committed file, so an apply has
nothing to revert, and there is no `apply -k` anymore. Kept here because the symptom — a component back
on an old image after an unrelated orchestration change — is where you would look. See
[Operations → The pins conflict](operations.md#the-pins-conflict-resolved-by-the-helm-migration).
