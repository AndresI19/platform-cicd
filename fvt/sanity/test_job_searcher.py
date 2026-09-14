"""Jobomancer at /job-searcher/."""

from __future__ import annotations

from conftest import http

BASE = "/job-searcher"


def test_bare_path_redirects(site):
    """GET /job-searcher redirects to the trailing slash"""
    r = http(f"{site}{BASE}", timeout=15, follow=False)
    assert r.status in (301, 302, 308), f"expected a redirect, got {r.status}"
    assert r.header("Location").endswith(f"{BASE}/"), f"redirected to {r.header('Location') or '(no Location)'}"


def test_app_loads(site):
    """GET /job-searcher/ serves the app"""
    r = http(f"{site}{BASE}/")
    assert r.status == 200, f"expected 200, got {r.status}"


def test_health(site):
    """GET /job-searcher/api/health is ok"""
    r = http(f"{site}{BASE}/api/health")
    assert r.status == 200, f"expected 200, got {r.status}"


def test_version(site):
    """GET /job-searcher/version reports an image version"""
    r = http(f"{site}{BASE}/version")
    assert r.status == 200, f"expected 200, got {r.status}"
    assert r.json().get("version"), f"no version in {r.text[:200]}"


def test_results_query_answers(site):
    """GET /job-searcher/api/results answers a read"""
    # A guest read, so it exercises the Postgres path without needing an identity. This is the check
    # that would have caught the container dying on a large result set: it is the one endpoint here
    # that touches the database rather than just proving the process is listening.
    r = http(f"{site}{BASE}/api/results")
    assert r.status == 200, f"expected 200, got {r.status}"
    body = r.json()
    assert "results" in body or "rows" in body, f"unexpected shape: {str(body)[:200]}"
