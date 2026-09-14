"""The home page at / — the portfolio shell everything else hangs off."""

from __future__ import annotations

from conftest import http


def test_root_serves_the_page(site):
    """GET / returns the page shell"""
    r = http(f"{site}/")
    assert r.status == 200, f"expected 200, got {r.status}"
    # Not a full DOM assertion — just that this is the SPA shell and not an error page nginx or
    # Cloudflare produced. `<div id="app">` is the mount point main.ts writes into.
    assert 'id="app"' in r.text, "response did not look like the SPA shell"


def test_version_reports_itself(site):
    """GET /version reports an image version"""
    r = http(f"{site}/version")
    assert r.status == 200, f"expected 200, got {r.status}"
    body = r.json()
    assert body.get("version"), f"no version in {body}"


def test_versions_fan_out(site):
    """GET /api/versions aggregates the other components"""
    # This one endpoint is the only place that reaches every service over cluster DNS, so a failure
    # here can mean any of them is unreachable from inside — a different signal from the per-service
    # public checks below, which is why it is worth its own check.
    r = http(f"{site}/api/versions")
    assert r.status == 200, f"expected 200, got {r.status}"
    body = r.json()
    assert isinstance(body.get("components"), dict), f"no components map in {str(body)[:200]}"


def test_config_is_served(site):
    """GET /api/config returns the client's runtime config"""
    r = http(f"{site}/api/config")
    assert r.status == 200, f"expected 200, got {r.status}"
    assert "vmcpApiBase" in r.json(), "config did not carry vmcpApiBase"


def test_resume_is_a_pdf(site):
    """GET /resume.pdf serves a real PDF from the content volume"""
    r = http(f"{site}/resume.pdf")
    assert r.status == 200, f"expected 200, got {r.status}"
    # The magic bytes, not the content-type: the failure this catches is the SPA catch-all returning
    # index.html with a 200, which a header check would miss and a byte check cannot.
    assert r.body[:5] == b"%PDF-", f"not a PDF — first bytes were {r.body[:16]!r}"
