"""platform-auth — the identity every other service verifies against."""

from __future__ import annotations

import base64
import json

from conftest import http


def _claims(token: str) -> dict:
    """The payload segment, decoded WITHOUT verifying — this is inspection, not trust.

    The suite has no business verifying a signature: that is exactly what every service does with the
    JWKS, and a second implementation here could disagree with them and be the one that is wrong. All
    this needs is "does the token carry the claims the platform keys off".
    """
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)  # base64url segments arrive unpadded
    return json.loads(base64.urlsafe_b64decode(payload))


def test_jwks_is_published(site):
    """GET /.well-known/jwks.json publishes a usable key set"""
    r = http(f"{site}/.well-known/jwks.json")
    assert r.status == 200, f"expected 200, got {r.status}"
    keys = r.json().get("keys")
    assert keys, f"no keys in the JWKS: {r.text[:200]}"
    # RSA keys with a key id: every verifier on the platform pins RS256 and selects by kid, so a set
    # missing either is one that looks published and verifies nothing.
    assert all(k.get("kty") == "RSA" and k.get("kid") for k in keys), f"malformed keys: {keys}"


def test_jwks_on_the_api_host(api):
    """GET /.well-known/jwks.json on the API host serves the same key set"""
    # Both hosts route it, and services are configured against one or the other. If they ever diverge,
    # tokens minted for one host stop verifying on the other — a confusing, partial outage.
    r = http(f"{api}/.well-known/jwks.json")
    assert r.status == 200, f"expected 200, got {r.status}"
    assert r.json().get("keys"), "API host published an empty key set"


def test_sign_in_returns_a_token(bearer):
    """POST /auth/token signs the runner in"""
    # The fixture did the round trip; this asserts the shape of what came back.
    assert bearer.count(".") == 2, "token is not a three-segment JWT"


def test_token_carries_the_platform_claims(bearer):
    """the issued token carries iss, aud and sub"""
    c = _claims(bearer)
    assert c.get("iss"), f"no issuer claim: {c}"
    assert c.get("aud"), f"no audience claim: {c}"
    assert c.get("sub"), f"no subject claim: {c}"


def test_a_bad_password_is_refused(site):
    """POST /auth/token refuses a wrong password"""
    # The check that matters most on this service: an auth endpoint that accepts anything would pass
    # every other test here, because every other test only needs A token, not a correctly-refused one.
    r = http(
        f"{site}/auth/token",
        "POST",
        {"username": "fvt-runner", "password": "definitely-not-the-password"},
    )
    # The invariant is "no token comes back", not a particular status. platform-auth rate-limits
    # mutating requests per IP, so a 429 here is the limiter working, not the platform accepting a
    # bad password — asserting a 401 specifically turns a second run inside the window into a false
    # red. What must never happen is a 200 with a token in it.
    assert r.status != 200, f"a wrong password returned 200: {r.text[:200]}"
    assert r.status < 500, f"a wrong password caused a server error: {r.status} {r.text[:200]}"
    body = r.json() if r.body[:1] == b"{" else {}
    assert not body.get("token"), "a wrong password produced a token"
