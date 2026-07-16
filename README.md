# platform-cicd

The platform's deploy path: a single self-hosted GitHub Actions runner and the scripts it runs. A
merge to any app repo's `main` builds that component on this machine, pushes it to the local TLS
registry, and rolls it out as a Helm release — reported to Discord, with no inbound port.

## The pieces

| Path | What it is |
| --- | --- |
| `.github/workflows/release.yml` | the deploy job — triggered by `repository_dispatch`, one per component |
| `runner/Dockerfile` · `compose.yml` · `entrypoint.sh` | the self-hosted runner: ephemeral, buildx, on minikube's docker network |
| `runner/runner.service` | systemd **user** unit that starts the runner at boot |
| `fvt/compose.yml` · `fvt.service` | the FVT traffic runner: a host container that drives the **public** API on a loop (was a cluster Pod) |
| `deploy/build.sh` | build one component's image (a per-component registry of build contexts) and push it |
| `deploy/deploy.sh` | `helm upgrade` the component's **own** release, verify the spec, hand the rollout to the cluster — applied, not awaited |
| `deploy/rollout-check.yaml` | the Job that watches that rollout in-cluster and rolls the release back (+ Discord) if it stalls |
| `scripts/kubeconfig.sh` | mint the scoped `deployer` kubeconfig for `runner/.env` |

The matching half lives in each app repo as its own `release.yml`: on merge it reads the tag
`version-tag.yml` cut and `repository_dispatch`es here. See [Deploy pipeline](docs/deploy-pipeline.md).

## Run & connect

```bash
cp runner/.env.example runner/.env     # fill in GH_PAT and KUBECONFIG_B64 — see the file
docker compose -f runner/compose.yml up -d --build
docker compose -f runner/compose.yml logs -f
```

Start it at boot (a systemd **user** unit — needs linger, the same two-part step the platform units
need):

```bash
cp runner/runner.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now runner.service
sudo loginctl enable-linger "$USER"    # WITHOUT THIS, no user unit starts at boot
```

Verify: `systemctl --user is-enabled runner` → `enabled`, `loginctl show-user "$USER" -p Linger` →
`Linger=yes`. A job waits in GitHub's queue until a runner takes it, so a runner that is down at boot
delays deploys rather than losing them.

### The FVT traffic runner

A second host service, `fvt/`, replays the function-verification suite through the gateway on a loop
so the dashboard's Recent Calls stay populated. It used to be an in-cluster `fvt-traffic` Deployment;
it now runs on the host and hits the **public** API, signing in to platform-auth for a real token
(vMCP verifies signatures, so the old forged bearer no longer works). CI still builds and pushes its
image — the release job just skips the helm-deploy for it.

```bash
cp fvt/.env.example fvt/.env           # set FVT_CODE (the fvt-runner pin, ≥4 chars) — see the file
docker compose -f fvt/compose.yml up -d --pull always
docker compose -f fvt/compose.yml logs -f

cp fvt/fvt.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now fvt.service      # linger (above) covers this unit too
```

After an rs-mcp-server release rebuilds the image, adopt it with `systemctl --user restart fvt` — the
unit runs `up --pull always`, so it pulls the newest `:latest` and recreates the container.

**Full documentation** → the [docs](docs/): [Architecture](docs/architecture.md) ·
[Runner](docs/runner.md) · [Deploy pipeline](docs/deploy-pipeline.md) · [Security](docs/security.md) ·
[Operations](docs/operations.md) · [Troubleshooting](docs/troubleshooting.md).
