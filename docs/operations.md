# Operations

Day-to-day: setting it up, watching it, re-running a deploy, and the one conflict to know about.

## First-time setup

1. **Two fine-grained tokens** (both scoped to platform-cicd only — see
   [Security → The two tokens](security.md#the-two-tokens)):
   - registration (`Administration: R/W`) → `runner/.env` as `GH_PAT`
   - dispatch (`Contents: R/W`) → each app repo's secrets as `CICD_DISPATCH_TOKEN`
     (`gh secret set CICD_DISPATCH_TOKEN --repo AndresI19/<repo>`)
2. **The deployer kubeconfig** → `runner/.env`:
   ```bash
   printf 'KUBECONFIG_B64=%s\n' "$(scripts/kubeconfig.sh)" >> runner/.env
   ```
   (Requires `deployer-rbac.yaml` applied in the cluster, from platform-orchestration.)
3. **The Discord webhook** for deploy notifications →
   `gh secret set DISCORD_WEBHOOK_URL --repo AndresI19/platform-cicd`.
4. Start the runner and enable it at boot — see the README's *Run & connect*.

## Watching deploys

Every deploy **pushes** its outcome — you should not have to poll:

- **Discord** — ✅ (with `was → now` images) or ❌, per component, to the CI/CD channel.
- **GitHub** — the `Report the outcome` step writes a job summary; the Actions tab shows the queue.

To see what is live: `/api/versions` on the home page aggregates every component's `/version`.

## Re-running a deploy by hand

Dispatch directly (no new commit, deploys an existing tag):

```bash
gh api -X POST repos/AndresI19/platform-cicd/dispatches -f event_type=release \
  -F 'client_payload[component]=quiz' \
  -F 'client_payload[repo]=AndresI19/data-driven-quiz-server' \
  -F 'client_payload[version]=0.1.16'
```

To exercise the **full** chain instead, push an empty commit to the app repo's `main` (via a PR) —
`version-tag` cuts a tag, `release.yml` dispatches, the runner deploys.

## The pins conflict (resolved by the Helm migration)

Historically there were **two deploy paths** writing the same deployments: this CD set images
imperatively (`kubectl set image`), while `kubectl apply -k` on platform-orchestration re-applied the
image tags pinned *declaratively* in `kustomization.yaml` — so any `apply -k` reverted CD deploys to the
pinned (old, side-loaded `platform-*`) images.

That is **gone**. The platform deploys as a Helm release now, and image tags live in the release
(server-side state), not a committed file — there is nothing for an apply to revert. Both the host
deploy and this CD are `helm upgrade` against the same `platform` release, which is the single source
of truth; `helm rollback platform <n>` is the deliberate revert. Note orchestration changes are still
**not** auto-applied — the human runs the host `./k8s/deploy.sh`.

## Registry retention (not yet automated)

The registry keeps every pushed tag. There is no automated pruning yet. When added, note: deletion is
by digest (not tag), `:latest` shares a digest with the newest version, and
`registry garbage-collect` is unsafe against concurrent pushes — so it must run inside the serialized
deploy path, and the node's own image cache must be pruned separately.
