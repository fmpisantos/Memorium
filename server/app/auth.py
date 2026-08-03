"""Who is calling, and are they allowed in.

There is no user table and no password. Identity is a Google ID token the app
already holds; authorisation is a list of addresses in `.env`. That keeps the
one secret worth stealing -- a token good forever on a shared bearer scheme --
out of the design entirely: a Google ID token expires in an hour, and revoking
someone is deleting them from `MEMORIUM_ALLOWED_EMAILS`.

The checks below are the standard ones for an ID token, and skipping any of
them is what turns "signed in with Google" into "anyone with any Google token".
"""

from __future__ import annotations

import logging
from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient

log = logging.getLogger("memorium.auth")

GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"
# Google has issued both spellings over the years and documents accepting both.
GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
# Tolerance for a server clock that drifted, in seconds.
CLOCK_SKEW = 60


class InvalidIdentity(Exception):
    """The token is not a valid, current Google ID token for this app."""


@lru_cache
def _jwk_client() -> PyJWKClient:
    # Google's signing keys rotate slowly and are cached, so verification is
    # local arithmetic after the first call rather than an HTTPS round trip on
    # every request.
    return PyJWKClient(GOOGLE_CERTS_URL, cache_keys=True, lifespan=3600)


def _signing_key(token: str) -> Any:
    """The public key Google signed `token` with. Patched out in tests."""
    return _jwk_client().get_signing_key_from_jwt(token).key


def verify_google_id_token(token: str, client_id: str) -> dict[str, Any]:
    """Verify a Google ID token and return its claims.

    Raises `InvalidIdentity` for anything that fails, with a message safe to
    hand back to the caller -- they are holding the token in question.
    """
    if not token:
        raise InvalidIdentity("No token presented")

    try:
        key = _signing_key(token)
    except Exception as exc:  # network down, unknown key id, malformed header
        # Distinguishable in the log, deliberately not to the caller: whether
        # Google's key endpoint is reachable is not their business.
        log.warning("could not fetch a signing key for the presented token: %s", exc)
        raise InvalidIdentity("Could not verify the Google token") from exc

    try:
        claims = jwt.decode(
            token,
            key=key,
            algorithms=["RS256"],
            audience=client_id,
            leeway=CLOCK_SKEW,
            options={"require": ["exp", "iat", "aud", "iss", "sub"]},
        )
    except jwt.ExpiredSignatureError as exc:
        # The app is expected to refresh and retry, so this one is named
        # precisely rather than lumped in with "invalid".
        raise InvalidIdentity("The Google session has expired") from exc
    except jwt.InvalidAudienceError as exc:
        raise InvalidIdentity("That token was issued for a different app") from exc
    except jwt.InvalidTokenError as exc:
        raise InvalidIdentity(f"Invalid Google token: {exc}") from exc

    # PyJWT validates `iss` only against a single value, and Google uses two.
    if claims.get("iss") not in GOOGLE_ISSUERS:
        raise InvalidIdentity("That token was not issued by Google")

    email = str(claims.get("email") or "").strip()
    if not email:
        raise InvalidIdentity("That token carries no email address")
    # An unverified address is one the account holder never proved they own,
    # which would make the allowlist a list of addresses anyone can claim.
    if claims.get("email_verified") is not True:
        raise InvalidIdentity(f"{email} has not been verified with Google")

    claims["email"] = email
    return claims


def is_allowed(email: str, allowed: frozenset[str]) -> bool:
    return email.strip().casefold() in allowed
