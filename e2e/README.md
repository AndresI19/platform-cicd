# e2e — the front-end regression oracle

Playwright specs that drive the **live** platform through every front-end feature. Where `fvt/`
exercises the public API on a loop, this exercises the three browser UIs, and it is the gate used
while a repo is rewritten: capture what the deployed system does now, refactor underneath it, and
confirm the observable behaviour did not move.

It is **not** wired into the deploy pipeline. It is run by hand, before and after a change.

## Run

```bash
npm install
npx playwright install chromium     # the browsers are not vendored
npm test                            # against https://andres.project-platform.me
npm run report                      # open the HTML report from the last run
```

Point it somewhere else with the two env vars the config reads:

```bash
PLATFORM_BASE=http://localhost:8081 npm test          # a port-forward
PLATFORM_API=https://api-andres.project-platform.me npm test
```

## What it covers

| Spec | Covers |
| --- | --- |
| `tests/home.spec.ts` | masthead, `/version` reporting image **and** platform versions, the architecture pull-down paging all four diagrams, the topology drawing `fvt-traffic` as a consumer rather than a cluster box, the first-visit gate dismissing as guest, cross-links to the other two apps |
| `tests/quiz.spec.ts` | setup screen, starting a run and rendering a playable card, the garden tool palette, and the pause-pill stuck-render regression |
| `tests/vmcp.spec.ts` | dashboard overview, Recent Calls telemetry rows, the read-only sign-in control |

## Two things the config does on purpose

**`retries: 1`.** The suite drives production over the internet, behind Cloudflare. One retry absorbs
a transient edge hiccup; a real regression still fails both attempts. Without it, flakiness erodes
trust in the gate, which is worse than a slower run.

**Specs read hosts from the config, never hard-coded.** `playwright.config.ts` exports `HOSTS`
(`home`, `quiz`, `vmcp`, `api`) derived from `PLATFORM_BASE` / `PLATFORM_API`, so pointing the whole
suite at a snapshot deploy or a port-forward is a one-variable change.

## A note on test names

`quiz.spec.ts` names one test after the bug it prevents — *"pause pill keeps the card mounted (no
stuck-render regression)"*. That is deliberate: a test named for its incident explains why it may not
be deleted when it looks redundant.
