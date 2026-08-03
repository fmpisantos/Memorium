import os
import tempfile
from pathlib import Path

# Must be set before any app module imports, because app.db builds the engine
# from settings at import time.
_tmpdir = tempfile.mkdtemp(prefix="memorium-tests-")
os.environ["MEMORIUM_API_TOKEN"] = "test-token"
os.environ["MEMORIUM_DATABASE_URL"] = f"sqlite:///{Path(_tmpdir) / 'test.db'}"
os.environ["MEMORIUM_DEFAULT_TIMEZONE"] = "UTC"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.db import SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client():
    with TestClient(app) as c:
        c.headers.update(AUTH)
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
