"""Platform-wide sanity FVT: fixtures, and the plugin that turns a pytest run into a posted report.

This suite drives the PUBLIC API from the host, outside the cluster — the same path a visitor takes,
through Cloudflare and nginx, not a shortcut over cluster DNS. An in-cluster check that passes while
the public route is broken is the failure mode worth avoiding, and it is the one an internal probe
cannot see.

It is deliberately SHALLOW. Every check asks "is this service answering correctly at all", never "is
its business logic right" — that is what each repo's own tests are for. A sanity suite that duplicates
unit tests takes their maintenance cost and reports their failures a day late.

The reporting plugin below is why this is a pytest suite rather than a shell script: pytest already
knows each check's name, outcome, duration and failure text, so the report is a projection of what it
collected rather than a second bookkeeping system that can disagree with the run.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field

import pytest

# --- Configuration -------------------------------------------------------------------------------

#: The site host. Everything a browser touches lives here.
SITE_URL = os.environ.get("SITE_URL", "https://andres.project-platform.me").rstrip("/")
#: The API host. /mcp, /api and /health are routed here, and the site host 404s /mcp on purpose.
API_URL = os.environ.get("API_URL", "https://api-andres.project-platform.me").rstrip("/")
#: platform-auth, reachable on both hosts under /auth.
AUTH_URL = os.environ.get("AUTH_URL", SITE_URL).rstrip("/")
#: Where the run report is POSTed. Empty disables reporting — the suite still runs and still fails
#: the process, which is what makes it usable from a laptop without touching the history.
REPORT_URL = os.environ.get("FVT_REPORT_URL", f"{SITE_URL}/api/fvt/results").rstrip("/")
REPORT_ENABLED = os.environ.get("FVT_REPORT", "1") not in ("0", "false", "no", "")

FVT_USER = os.environ.get("FVT_USER", "fvt-runner")
FVT_CODE = os.environ.get("FVT_CODE", "")

#: Per-request timeout. Generous: this crosses the public internet and a Cloudflare tunnel, and a
#: slow answer is a different finding from no answer — only the latter should fail a sanity check.
TIMEOUT = float(os.environ.get("FVT_TIMEOUT", "20"))

SUITE = "platform-sanity"


# --- A tiny HTTP client --------------------------------------------------------------------------


@dataclass
class Response:
    status: int
    body: bytes
    headers: dict

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.body)

    def header(self, name: str, default: str = "") -> str:
        """One header, case-insensitively.

        HTTP header names are case-insensitive but a plain dict is not, and what reaches us has been
        through nginx and Cloudflare — either may normalise the casing. Looking up "Location" and
        getting nothing because the wire said "location" is a check that fails against a service
        doing exactly the right thing.
        """
        lowered = {k.lower(): v for k, v in self.headers.items()}
        return lowered.get(name.lower(), default)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surfaces a 3xx as the response instead of following it.

    urllib follows redirects transparently, which makes a redirect UNOBSERVABLE: asserting that
    /job-searcher redirects to /job-searcher/ sees only the 200 at the end of the hop and reports a
    failure against a route that is working perfectly. Any check about the redirect itself has to
    opt out of following it.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirect)


def http(
    url: str,
    method: str = "GET",
    body: dict | None = None,
    headers: dict | None = None,
    timeout: float | None = None,
    follow: bool = True,
) -> Response:
    """One request, returning the response even for 4xx/5xx.

    urllib raises on a non-2xx, but a status IS the finding here — "did /health return 200" wants to
    report `got 503`, not an exception with the number buried in it. So HTTPError is unwrapped back
    into an ordinary response and only genuine transport failures propagate.

    `follow=False` reports a 3xx rather than chasing it — see _NoRedirect.
    """
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "*/*")
    # A recognisable agent: these requests show up in access logs, and "python-urllib" there is a
    # small mystery for whoever reads them next.
    req.add_header("User-Agent", f"platform-fvt/{SUITE}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    opener = urllib.request.urlopen if follow else _NO_REDIRECT_OPENER.open
    try:
        with opener(req, timeout=timeout or TIMEOUT) as r:
            return Response(r.status, r.read(), dict(r.headers))
    except urllib.error.HTTPError as e:
        # With follow=False a 3xx arrives here, which is the point: it carries the status and the
        # Location header the check wants to read.
        return Response(e.code, e.read(), dict(e.headers))


# --- Fixtures ------------------------------------------------------------------------------------


@pytest.fixture(scope="session")
def site() -> str:
    return SITE_URL


@pytest.fixture(scope="session")
def api() -> str:
    return API_URL


#: The run's one token. platform-auth rate-limits MUTATING requests per IP (AUTH_RATE_MAX, default
#: 10 per 5 minutes), and signing in is mutating — so every sign-in this suite makes is spent from a
#: budget that also has to cover the deliberate bad-password check and the report at the end.
#: Signing in once and reusing it is not an optimisation; it is what keeps a suite run from being
#: most of its own rate limit. (Found by running the container four times in a minute and watching
#: the auth checks start failing with 429s that looked like real failures.)
_token: str | None = None
#: Why the last sign-in failed, so a failing auth check can say "429 rate limited" rather than the
#: useless "could not sign in". The status is the whole diagnosis here and it was being discarded.
_token_error: str = ""


def get_token() -> str | None:
    """Sign in once per process, cached. None when there is no credential or auth refuses.

    Two-step, like the rs-mcp traffic runner: POST /auth/identities returns a token on 201 (created)
    or 409 if the name is taken, in which case /auth/token exchanges the credentials. The
    self-provisioning half matters because the auth database being rebuilt should not silently end
    the reporting — the runner re-creates its own account and carries on.
    """
    global _token, _token_error
    if _token is not None:
        return _token
    if not FVT_CODE:
        _token_error = "FVT_CODE unset"
        return None
    creds = {"username": FVT_USER, "password": FVT_CODE}
    try:
        r = http(f"{AUTH_URL}/auth/identities", "POST", creds)
        tok = r.json().get("token") if r.status in (200, 201) else None
        if not tok:
            r = http(f"{AUTH_URL}/auth/token", "POST", creds)
            tok = r.json().get("token") if r.status == 200 else None
            if not tok:
                # The status IS the finding. 429 means this IP spent its budget (10 mutating
                # attempts per 5 minutes by default) and says nothing about the platform's health;
                # 401 would mean the credential is actually wrong. Reporting them identically sent
                # us looking for an auth outage that was our own repeated runs.
                _token_error = f"{r.status} {r.text[:160]}"
    except Exception as e:  # noqa: BLE001 - a transport failure is a finding too, not a crash
        _token_error = f"{type(e).__name__}: {e}"
        tok = None
    _token = tok
    return _token


def token_error() -> str:
    return _token_error or "no token and no reason recorded"


@pytest.fixture(scope="session")
def bearer() -> str:
    """A real platform-auth token for FVT_USER.

    Skips rather than fails when FVT_CODE is unset: a checkout with no credential can still run every
    unauthenticated check, and reporting a red board because the laptop lacks a password would be a
    false alarm about the platform.
    """
    if not FVT_CODE:
        pytest.skip("FVT_CODE unset — no credential to sign in with")
    tok = get_token()
    if not tok:
        pytest.fail(f"could not sign in as {FVT_USER} at {AUTH_URL}: {token_error()}")
    return tok


# --- The reporting plugin --------------------------------------------------------------------------


@dataclass
class Collected:
    started: float = field(default_factory=time.time)
    checks: list[dict] = field(default_factory=list)


_collected = Collected()

#: test_job_searcher.py → "job-searcher". Everything else is the module name after `test_`, so a new
#: file needs no registration — the service name cannot drift from the file that tests it.
_SERVICE_OVERRIDES = {"job_searcher": "job-searcher", "rs_mcp": "rs-mcp"}


def _service_of(nodeid: str) -> str:
    module = nodeid.split("::", 1)[0].rsplit("/", 1)[-1]
    stem = module[len("test_") :].removesuffix(".py") if module.startswith("test_") else module
    return _SERVICE_OVERRIDES.get(stem, stem.replace("_", "-"))


def _name_of(item) -> str:
    """The check's human name: its docstring's first line, else the test function's name.

    Docstrings win because they are written for a reader — the dashboard shows this string, and
    `test_health_returns_200` is a worse thing to read on a board than "GET /health returns 200".
    """
    doc = (item.function.__doc__ or "").strip().splitlines()
    return doc[0].strip() if doc and doc[0].strip() else item.name


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()

    # Normally only the `call` phase is a check — counting setup and teardown too would report every
    # test three times. But a test whose SETUP fails never reaches `call`, so recording call-only
    # dropped it from the report entirely: a fixture that could not sign in silently shortened the
    # board from 24 checks to 22, which reads as "complete and green" rather than "two checks could
    # not run". A missing check is worse than a failing one, because nothing on the dashboard says
    # it is missing. So a setup failure is recorded as the check failing, and teardown is ignored.
    if report.when == "setup":
        if report.passed:
            return  # the ordinary case; the real result comes from `call`
        status = "skip" if report.skipped else "fail"
        detail = str(report.longrepr)[:1500] if report.longrepr else None
    elif report.when == "call":
        if report.skipped:
            status, detail = "skip", str(report.longrepr)[:1500] if report.longrepr else None
        elif report.passed:
            status, detail = "pass", None
        else:
            status, detail = "fail", str(report.longrepr)[:1500]
    else:
        return  # teardown

    _collected.checks.append(
        {
            "service": _service_of(report.nodeid),
            "name": _name_of(item),
            "status": status,
            "durationMs": int(report.duration * 1000),
            "detail": detail,
        }
    )


def pytest_sessionfinish(session, exitstatus):
    """POST the run, then say what happened — on stdout, which is the journal's copy of record.

    Reporting failures never change the exit status. The suite's verdict is about the PLATFORM; if
    the dashboard cannot be written that is worth shouting about in the log, but turning it into a
    red run would mean an outage of the reporting endpoint looked exactly like an outage of
    everything it reports on.
    """
    if not _collected.checks:
        print("[fvt-sanity] no checks ran — nothing to report")
        return
    if not REPORT_ENABLED:
        print(f"[fvt-sanity] reporting disabled; {len(_collected.checks)} checks not posted")
        return

    payload = {
        "suite": SUITE,
        "target": SITE_URL,
        # Time-based and unique per run, so a retry of the SAME run replaces it while tomorrow's is
        # a new row. uuid4 alone would duplicate on retry; a date alone would collide on a re-run.
        "runId": f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(_collected.started))}-{uuid.uuid4().hex[:8]}",
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_collected.started)),
        "finishedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "checks": _collected.checks,
    }

    if not FVT_CODE:
        print("[fvt-sanity] FVT_CODE unset — cannot authenticate to report; skipping the POST")
        return
    try:
        # The SAME token the checks used. Signing in again here would double this run's spend against
        # the auth rate limit for no gain — the token is minutes old and valid for hours.
        tok = get_token()
        if not tok:
            print("[fvt-sanity] could not get a token to report with")
            return
        res = http(REPORT_URL, "POST", payload, {"Authorization": f"Bearer {tok}"})
        if res.status == 201:
            print(f"[fvt-sanity] reported {len(payload['checks'])} checks: {res.text[:200]}")
        else:
            print(f"[fvt-sanity] report REJECTED {res.status}: {res.text[:300]}")
    except Exception as e:  # noqa: BLE001 - reporting must never mask the suite's own verdict
        print(f"[fvt-sanity] could not post the report: {e}")
