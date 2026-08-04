import os
import tempfile
import time
from pathlib import Path

# Must be set before any app module imports, because app.db builds the engine
# from settings at import time.
_tmpdir = tempfile.mkdtemp(prefix="memorium-tests-")
os.environ["MEMORIUM_DATABASE_URL"] = f"sqlite:///{Path(_tmpdir) / 'test.db'}"
os.environ["MEMORIUM_DEFAULT_TIMEZONE"] = "UTC"
os.environ["MEMORIUM_GOOGLE_CLIENT_ID"] = "test-client.apps.googleusercontent.com"
os.environ["MEMORIUM_ALLOWED_EMAILS"] = "learner@example.com, Someone.Else@Example.com"
# The background phrase writer is driven by hand in the tests that care about
# it. Left running it would write sentences in the middle of unrelated tests,
# against whatever generator happened to be installed at the time.
os.environ["MEMORIUM_PHRASE_POOL_ENABLED"] = "false"

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import auth  # noqa: E402
from app.db import SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base  # noqa: E402
from app.phrases import set_pool  # noqa: E402

CLIENT_ID = os.environ["MEMORIUM_GOOGLE_CLIENT_ID"]
ALLOWED_EMAIL = "learner@example.com"

# One keypair for the whole session, standing in for Google's. Tests sign real
# RS256 tokens with it, so every request goes through the same verification the
# server does in production -- signature included.
_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_private_pem = _key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.TraditionalOpenSSL,
    encryption_algorithm=serialization.NoEncryption(),
)


def google_id_token(
    email: str = ALLOWED_EMAIL,
    *,
    audience: str = CLIENT_ID,
    issuer: str = "https://accounts.google.com",
    email_verified: bool = True,
    expires_in: int = 3600,
    key=None,
    **extra,
) -> str:
    """Mint an ID token shaped exactly like Google's, signed by the test key."""
    now = int(time.time())
    claims = {
        "iss": issuer,
        "aud": audience,
        "sub": "1234567890",
        "email": email,
        "email_verified": email_verified,
        "iat": now,
        "exp": now + expires_in,
        **extra,
    }
    return jwt.encode(claims, key or _private_pem, algorithm="RS256")


def auth_header(email: str = ALLOWED_EMAIL, **kwargs) -> dict[str, str]:
    return {"Authorization": f"Bearer {google_id_token(email, **kwargs)}"}


@pytest.fixture(autouse=True)
def google_keys(monkeypatch):
    """Point the verifier at the test keypair instead of Google's endpoint.

    Only the key lookup is replaced. Signature, audience, issuer, expiry and
    `email_verified` are all still checked for real.
    """
    monkeypatch.setattr(auth, "_signing_key", lambda token: _key.public_key())


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture(autouse=True)
def fresh_pool():
    """A test that swaps the pool's settings must not leak them into the next."""
    set_pool(None)
    yield
    set_pool(None)


@pytest.fixture
def client():
    with TestClient(app) as c:
        c.headers.update(auth_header())
        yield c


@pytest.fixture
def db():
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def profile(db):
    from app.models import Profile

    p = Profile(
        id=1,
        source_lang="en-US",
        target_lang="es-ES",
        desired_retention=0.90,
        daily_new_limit=10,
        timezone="UTC",
    )
    db.add(p)
    db.commit()
    db.refresh(p)
    return p
