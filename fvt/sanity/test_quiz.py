"""The quiz at /cloud-developer-quiz/."""

from __future__ import annotations

from conftest import http

BASE = "/cloud-developer-quiz"


def test_bare_path_redirects(site):
    """GET /cloud-developer-quiz redirects to the trailing slash"""
    # Without the redirect the SPA loads at a path its asset URLs are not relative to, and the page
    # comes up blank — a 200 that is completely broken, so the redirect is worth asserting directly.
    r = http(f"{site}{BASE}", timeout=15, follow=False)
    assert r.status in (301, 302, 308), f"expected a redirect, got {r.status}"
    assert r.header("Location").endswith(f"{BASE}/"), f"redirected to {r.header('Location') or '(no Location)'}"


def test_app_loads(site):
    """GET /cloud-developer-quiz/ serves the app"""
    r = http(f"{site}{BASE}/")
    assert r.status == 200, f"expected 200, got {r.status}"
    assert "<div id=" in r.text or "<script" in r.text, "response did not look like the app shell"


def test_health(site):
    """GET /cloud-developer-quiz/api/health is ok"""
    r = http(f"{site}{BASE}/api/health")
    assert r.status == 200, f"expected 200, got {r.status}"


def test_version(site):
    """GET /cloud-developer-quiz/version reports an image version"""
    r = http(f"{site}{BASE}/version")
    assert r.status == 200, f"expected 200, got {r.status}"
    assert r.json().get("version"), f"no version in {r.text[:200]}"
