from collections.abc import Iterator
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings

_settings = get_settings()

# SQLite needs check_same_thread=False because FastAPI serves requests from a
# threadpool; every request still gets its own Session.
_connect_args = {"check_same_thread": False} if _settings.database_url.startswith("sqlite") else {}

if _settings.database_url.startswith("sqlite:///"):
    db_path = Path(_settings.database_url.removeprefix("sqlite:///"))
    db_path.parent.mkdir(parents=True, exist_ok=True)

engine = create_engine(_settings.database_url, connect_args=_connect_args, future=True)


@event.listens_for(engine, "connect")
def _sqlite_pragmas(dbapi_connection, _record):
    """WAL keeps reads from blocking during an enrichment write; FKs are off by
    default in SQLite and we rely on them for cascade deletes."""
    if not _settings.database_url.startswith("sqlite"):
        return
    cur = dbapi_connection.cursor()
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA foreign_keys=ON")
    cur.close()


SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)


def get_db() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    from app import models  # noqa: F401  (registers mappers before create_all)

    models.Base.metadata.create_all(bind=engine)
