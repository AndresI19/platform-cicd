"""The open-vMCP gateway — its dashboard on the site host, its MCP surface on the API host."""

from __future__ import annotations

from conftest import http


def test_dashboard_loads(site):
    """GET /vmcp/ serves the dashboard"""
    r = http(f"{site}/vmcp/")
    assert r.status == 200, f"expected 200, got {r.status}"


def test_api_health(api):
    """GET /health on the API host is ok"""
    r = http(f"{api}/health")
    assert r.status == 200, f"expected 200, got {r.status}"


def test_registry_lists_servers(api):
    """GET /api/servers lists the registered MCP servers"""
    r = http(f"{api}/api/servers")
    assert r.status == 200, f"expected 200, got {r.status}"
    body = r.json()
    servers = body if isinstance(body, list) else body.get("servers", [])
    # Non-empty, not merely well-formed: an empty registry is what a gateway that lost its database
    # looks like, and it would otherwise pass a shape-only assertion.
    assert servers, f"registry is empty: {str(body)[:200]}"


def test_mcp_endpoint_is_routed(api):
    """POST /mcp is routed to the gateway"""
    # Deliberately NOT a protocol handshake — the rs-mcp traffic suite already exercises the tools
    # end to end. This asks the narrower question the sanity board needs: does nginx still route /mcp
    # to something that speaks HTTP. An unauthenticated call is expected to be refused, and a refusal
    # IS the gateway answering; only a 5xx or a connection failure means the route is broken.
    r = http(f"{api}/mcp", "POST", {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    assert r.status < 500, f"gateway returned {r.status}: {r.text[:200]}"


def test_site_host_does_not_serve_mcp(site):
    """GET /mcp on the site host is deliberately 404"""
    # The MCP endpoint moved to the API host and the site host returns a 404 that says so. Asserting
    # it keeps the split honest: a config that started serving MCP from both hosts again would be a
    # silent regression nothing else notices.
    r = http(f"{site}/mcp")
    assert r.status == 404, f"expected 404, got {r.status}"
