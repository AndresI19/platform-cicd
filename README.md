# platform-cicd

The platform's deploy path: a single self-hosted GitHub Actions runner and the scripts it runs. A
merge to any app repo's `main` builds that component on this machine, pushes it to the local TLS
registry, and rolls it out — reported to Discord, with no inbound port and a runner that cannot read
the platform's secrets.

## The pieces

| Path | What it is |
| --- | --- |
| `.github/workflows/release.yml` | the deploy job — triggered by `repository_dispatch`, one per component |
| `runner/Dockerfile` · `compose.yml` · `entrypoint.sh` | the self-hosted runner: ephemeral, buildx, on minikube's docker network |
| `runner/runner.service` | systemd **user** unit that starts the runner at boot |
| `deploy/build.sh` | build one component's image (a per-component registry of build contexts) and push it |
| `deploy/deploy.sh` | `kubectl set image` the component, wait, verify, roll back on failure |
| `scripts/kubeconfig.sh` | mint the least-privilege `deployer` kubeconfig for `runner/.env` |

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

**Full documentation** → the [docs](docs/): [Architecture](docs/architecture.md) ·
[Runner](docs/runner.md) · [Deploy pipeline](docs/deploy-pipeline.md) · [Security](docs/security.md) ·
[Operations](docs/operations.md) · [Troubleshooting](docs/troubleshooting.md).
