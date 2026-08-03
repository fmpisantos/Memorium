"""The authentication boundary.

Every one of these is a way in that must stay shut. They sign real RS256
tokens, so the only thing stubbed is where the public key comes from.
"""

import time

import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.main import app
from tests.conftest import ALLOWED_EMAIL, auth_header, google_id_token

# A representative route from each router. Auth is applied per-router, so one
# slipped `dependencies=` would otherwise leave a whole file unguarded.
GUARDED = [
    ("GET", "/me"),
    ("GET", "/profile"),
    ("GET", "/words"),
    ("GET", "/study/queue"),
    ("GET", "/enrich/status"),
    ("GET", "/leeches"),
]


def _call(client: TestClient, method: str, path: str, headers: dict[str, str]):
    return client.request(method, path, headers=headers)


# --------------------------------------------------------------------------- #
# The happy path
# --------------------------------------------------------------------------- #
def test_a_verified_allowlisted_account_gets_in(client):
    r = client.get("/me")
    assert r.status_code == 200
    assert r.json() == {"email": ALLOWED_EMAIL}


def test_the_allowlist_ignores_case(client):
    """Addresses are not case-sensitive, and .env is typed by hand."""
    r = client.get("/me", headers=auth_header("SOMEONE.ELSE@example.COM"))
    assert r.status_code == 200


# --------------------------------------------------------------------------- #
# Ways in that must stay shut
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("method,path", GUARDED)
def test_every_route_refuses_an_anonymous_caller(client, method, path):
    assert _call(client, method, path, {"Authorization": ""}).status_code == 401


@pytest.mark.parametrize("method,path", GUARDED)
def test_every_route_refuses_an_account_off_the_list(client, method, path):
    r = _call(client, method, path, auth_header("stranger@example.com"))
    assert r.status_code == 403
    assert "stranger@example.com" in r.json()["detail"]


def test_a_token_signed_by_someone_else_is_refused(client):
    """The whole scheme rests on this one: without the signature check, a
    token is just a JSON object claiming to be whoever it likes."""
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    forged = google_id_token(ALLOWED_EMAIL, key=impostor)

    r = client.get("/me", headers={"Authorization": f"Bearer {forged}"})
    assert r.status_code == 401


def test_an_unsigned_token_is_refused(client):
    """`alg: none` -- the oldest JWT hole there is."""
    import jwt

    now = int(time.time())
    unsigned = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": "test-client.apps.googleusercontent.com",
            "sub": "1",
            "email": ALLOWED_EMAIL,
            "email_verified": True,
            "iat": now,
            "exp": now + 3600,
        },
        key="",
        algorithm="none",
    )
    r = client.get("/me", headers={"Authorization": f"Bearer {unsigned}"})
    assert r.status_code == 401


def test_an_expired_token_is_refused_and_says_so(client):
    r = client.get("/me", headers=auth_header(expires_in=-120))
    assert r.status_code == 401
    assert "expired" in r.json()["detail"].lower()


def test_a_token_for_another_app_is_refused(client):
    """Audience is what stops a token minted for some other Google app -- one
    the holder controls -- being replayed here."""
    r = client.get("/me", headers=auth_header(audience="some-other-app.apps.googleusercontent.com"))
    assert r.status_code == 401


def test_a_token_from_another_issuer_is_refused(client):
    r = client.get("/me", headers=auth_header(issuer="https://evil.example.com"))
    assert r.status_code == 401


def test_an_unverified_address_is_refused(client):
    """Anyone can put any address on an account; `email_verified` is the proof
    they own it, and without it the allowlist means nothing."""
    r = client.get("/me", headers=auth_header(email_verified=False))
    assert r.status_code == 401


def test_a_token_with_no_email_is_refused(client):
    r = client.get("/me", headers=auth_header(email=""))
    assert r.status_code == 401


def test_garbage_is_refused_rather_than_crashing(client):
    for value in ["Bearer", "Bearer ", "Bearer not-a-jwt", "Basic abc", "Bearer a.b.c"]:
        r = client.get("/me", headers={"Authorization": value})
        assert r.status_code == 401, value


# --------------------------------------------------------------------------- #
# Refusing to serve when misconfigured
# --------------------------------------------------------------------------- #
def _with_settings(**overrides):
    base = get_settings().model_dump()
    base.update(overrides)
    app.dependency_overrides[get_settings] = lambda: Settings(**base)


@pytest.fixture
def restore_settings():
    yield
    app.dependency_overrides.pop(get_settings, None)


def test_an_empty_allowlist_refuses_everyone_loudly(client, restore_settings):
    """Not a 403 per caller: an empty list is a misconfigured server, and
    saying so is the difference between a five-minute fix and an evening."""
    _with_settings(allowed_emails="")
    r = client.get("/me")
    assert r.status_code == 500
    assert "MEMORIUM_ALLOWED_EMAILS" in r.json()["detail"]


def test_a_missing_client_id_refuses_to_serve(client, restore_settings):
    _with_settings(google_client_id="")
    r = client.get("/me")
    assert r.status_code == 500
    assert "MEMORIUM_GOOGLE_CLIENT_ID" in r.json()["detail"]


# --------------------------------------------------------------------------- #
# Open on purpose
# --------------------------------------------------------------------------- #
def test_health_needs_no_login(client):
    """A container healthcheck runs before anyone has signed in."""
    r = client.get("/health", headers={"Authorization": ""})
    assert r.status_code == 200
    assert r.json()["db"] == "ok"


def test_health_gives_away_no_deck_content(client):
    client.post("/words", json={"lemma": "perro", "native_gloss": "dog"})
    body = client.get("/health", headers={"Authorization": ""}).text
    assert "perro" not in body


# --------------------------------------------------------------------------- #
# The allowlist parser
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "raw,expected",
    [
        ("a@b.com", {"a@b.com"}),
        ("a@b.com,c@d.com", {"a@b.com", "c@d.com"}),
        (" a@b.com , c@d.com ", {"a@b.com", "c@d.com"}),
        ("a@b.com;c@d.com", {"a@b.com", "c@d.com"}),
        ("A@B.com", {"a@b.com"}),
        ("", set()),
        (" , ,, ", set()),
    ],
)
def test_the_allowlist_survives_being_typed_by_a_human(raw, expected):
    assert set(Settings(allowed_emails=raw).allowed_email_set) == expected
