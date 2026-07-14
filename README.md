# platform-cicd

The platform's only deploy path: a self-hosted GitHub Actions runner, the scripts it runs, and one
serialized queue for every component.

```
app repo (merge → main)          this repo                    this machine
─────────────────────────        ──────────────────────       ─────────────────────────
tag  ────────────────────►  repository_dispatch  ────────►    the ONLY self-hosted runner
dispatch (GitHub's VMs)          concurrency: platform-deploy  build → push → deploy
```

## Why the dispatch hop exists

**A self-hosted runner can only be scoped to one repository.** Org-level runners and runner groups are
an *organization* feature; `AndresI19` is a personal account. Five app repos therefore cannot share a
runner — and a reusable workflow does not help, because its jobs run in the **calling** repo's context
and would need a runner registered *there*.

So the runner lives here, and only here. Three things follow, and all of them are good:

- **No app repo can reach it.** Not by label, not by a crafted workflow, not from a fork. The runner
  does not exist in their world.
- **The concurrency group actually works.** Every component's deploy is a job in *this* repo, so one
  `concurrency: group: platform-deploy` serializes all five. (Groups are per-repository — five copies
  of a workflow in five repos would be five groups, serializing nothing.)
- **This repo is private**, so it has no fork PRs at all — which is the attack that makes self-hosted
  runners on *public* repos dangerous.

## Why the runner can do so little

It builds images, so it holds the docker socket — root-equivalent on the colima VM. Everything else is
fenced:

- **It cannot read your home directory.** Colima mounts exactly one host directory (three certificate
  files). `~/.ssh`, the Cloudflare tunnel token and the sealed-secrets master key do not exist inside
  the VM, so no container — including one a job starts — can bind-mount them.
- **It cannot read Kubernetes Secrets.** It authenticates as the `deployer` ServiceAccount, which may
  patch Deployments and create the version-spec writer Pod. `kubectl auth can-i get secrets` → **no**.
  It could not read the tunnel token, the Postgres passwords, or the auth signing key if it tried.

That second one is a consequence of the first: the host's kubeconfig authenticates with client certs
under `~/.minikube`, which the container cannot see — so rather than widen the mount, the runner got an
identity of its own. The boundary made the design.

## Run it

```bash
cp runner/.env.example runner/.env    # then fill it in — see the file
docker compose -f runner/compose.yml up -d --build
docker compose -f runner/compose.yml logs -f
```

## Start it at boot

The runner is a systemd **user** unit, ordered after the platform (it joins minikube's docker
network, which only exists once the cluster is up). Installing it is copying the file AND enabling
linger — the same two-part step the platform units need, and the same one that is easy to half-do:

```bash
cp runner/runner.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now runner.service
sudo loginctl enable-linger "$USER"   # WITHOUT THIS, no user unit starts at boot
```

A job waits in GitHub's queue until a runner takes it, so a runner that is not running at boot does
not lose work — it just delays every deploy until someone starts it. Which is exactly the kind of
quiet gap this unit closes. Verify: `systemctl --user is-enabled runner` and
`loginctl show-user "$USER" -p Linger` must read `enabled` and `Linger=yes`.

## Layout

```
runner/     Dockerfile · compose.yml · entrypoint.sh · runner.service   — the runner + its boot unit
deploy/     build.sh · deploy.sh                       — what a release actually does
.github/    release.yml                                — the serialized deploy queue
```
