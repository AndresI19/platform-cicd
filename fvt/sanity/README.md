# Platform sanity FVT

A once-a-day sweep of **every public route on the platform**, run from the host and reported to the
`/debug` board.

It is the sibling of `../compose.yml`, the rs-mcp traffic runner, and shares its `.env` and its
`fvt-runner` identity — but it has the opposite shape. That one loops forever to keep the vMCP
dashboard's Recent Calls populated. This one answers a single question once a day: *was the whole
platform healthy this morning?*

## What it checks

One file per service; the service name on the dashboard is derived from the filename, so it cannot
drift from what it tests.

| File | Service | Covers |
|---|---|---|
| `test_home.py` | `home` | `/`, `/version`, `/api/versions`, `/api/config`, `/resume.pdf` |
| `test_quiz.py` | `quiz` | redirect, app shell, `/api/health`, `/version` |
| `test_job_searcher.py` | `job-searcher` | redirect, app shell, `/api/health`, `/version`, `/api/results` |
| `test_vmcp.py` | `vmcp` | dashboard, API-host `/health`, `/api/servers`, `/mcp` routing, and that the site host still 404s `/mcp` |
| `test_auth.py` | `auth` | JWKS on both hosts, sign-in, token claims, wrong-password refusal |

Every check is **shallow on purpose**: "is this service answering correctly at all", never "is its
business logic right". The per-repo test suites own the latter, and duplicating them here would take
on their maintenance cost to report their failures a day late.

It drives the **public** API — through Cloudflare and nginx, exactly as a visitor does. An in-cluster
probe that passes while the public route is broken is the failure this exists to catch.

## Running it

```bash
# From the host, against production, without touching the dashboard:
FVT_REPORT=0 python3 -m pytest . -q

# In the container, the way the timer runs it:
docker compose -f compose.yml run --rm --build fvt-sanity
```

| Variable | Default | Meaning |
|---|---|---|
| `SITE_URL` | `https://andres.project-platform.me` | the site host |
| `API_URL` | `https://api-andres.project-platform.me` | the API host (`/mcp`, `/api`, `/health`) |
| `AUTH_URL` | `SITE_URL` | platform-auth; both hosts route `/auth` |
| `FVT_REPORT_URL` | `<SITE_URL>/api/fvt/results` | where the run is posted |
| `FVT_REPORT` | `1` | `0` runs the checks without posting |
| `FVT_USER` / `FVT_CODE` | from `../.env` | the runner's platform-auth identity |
| `FVT_TIMEOUT` | `20` | per-request seconds |

Without `FVT_CODE` the authenticated checks **skip** rather than fail, and nothing is posted — a
checkout with no credential can still exercise every public route, and a red board because the laptop
lacks a password would be a false alarm about the platform.

## Scheduling

```bash
cp fvt-sanity.service fvt-sanity.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now fvt-sanity.timer
systemctl --user list-timers fvt-sanity.timer   # confirm the next firing
systemctl --user start fvt-sanity.service       # run one now, by hand
journalctl --user -u fvt-sanity.service -n 50   # what the last run found
```

06:00 local, `Persistent=true` so a run missed while the machine was off happens after the next boot.
**Linger must be enabled** (`loginctl enable-linger $USER`) or a user timer does not fire without a
login session — the same requirement every other host unit here has.

The unit deliberately inherits pytest's exit code, so a red platform leaves `systemctl --user status
fvt-sanity` red too. The board is the report; this is a second signal visible from the host.

## Gotchas

- **The running suite is whatever this checkout has.** The image is built locally (`build:`, not a
  registry pull) so `git pull` is all it takes to ship a changed check — but a stale or
  feature-branched checkout silently runs stale checks. The same is already true of `../compose.yml`.
- **Auth rate limiting bounds how often you can run this.** platform-auth allows `AUTH_RATE_MAX`
  (default 10) *mutating* requests per IP per 5 minutes, and signing in is mutating. One run spends
  about two. Running the suite repeatedly while iterating will start returning
  `429 too many attempts`, which is the limiter working — not an auth outage. The suite signs in
  **once** per run and reuses that token for both the checks and the report, for exactly this reason.
- **A setup failure is reported as a failed check, not dropped.** pytest produces no `call` report
  when a fixture fails, so recording call-only silently shortened the board from 24 checks to 22 —
  which reads as complete and green. The plugin records setup failures too; a missing check is worse
  than a failing one, because nothing on the dashboard says it is missing.
- **`urllib` follows redirects.** Any check about a redirect must pass `follow=False`, or it sees the
  200 at the end of the hop and reports a failure against a route that is working.
- **Header lookups must go through `Response.header()`.** Names are case-insensitive on the wire and
  both nginx and Cloudflare may normalise them; a plain dict lookup for `Location` can miss.
