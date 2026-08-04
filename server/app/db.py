import logging
from collections.abc import Iterator
from pathlib import Path

from sqlalchemy import create_engine, event, inspect, select, text
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings

logger = logging.getLogger(__name__)

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
    _add_lemma_keys()
    _add_review_log_practice()
    _add_phrase_progress()


def _add_phrase_progress() -> None:
    """Gives sentences written before this the same blank slate as new ones.

    Same story as the columns below: no migration tool, a handful of added
    columns. The backfill is the easy kind -- a phrase from before this existed
    has never been answered, because answering one was not recorded anywhere --
    so zero attempts and no mastery is the truth rather than a guess.
    """
    existing = {c["name"] for c in inspect(engine).get_columns("phrases")}
    additions = {
        "attempts": "INTEGER NOT NULL DEFAULT 0",
        "lapses": "INTEGER NOT NULL DEFAULT 0",
        "mastered_at": "DATETIME",
        "retry_after": "DATETIME",
    }
    missing = {name: ddl for name, ddl in additions.items() if name not in existing}
    if not missing:
        return  # Fresh database: create_all already built them.

    with engine.begin() as conn:
        for name, ddl in missing.items():
            conn.execute(text(f"ALTER TABLE phrases ADD COLUMN {name} {ddl}"))
    logger.info("added phrase progress columns: %s", ", ".join(missing))


def _add_review_log_practice() -> None:
    """Marks an existing review log as entirely non-practice.

    Same story as the lemma keys: no migration tool, one added column. The
    backfill is the easy kind -- every review already in the log moved the
    schedule, because extra practice sessions did not exist when it was
    written -- so a false for all of them is not a guess, it is the truth.
    """
    if "practice" in {c["name"] for c in inspect(engine).get_columns("review_logs")}:
        return  # Fresh database: create_all already built it.

    with engine.begin() as conn:
        conn.execute(
            text("ALTER TABLE review_logs ADD COLUMN practice BOOLEAN NOT NULL DEFAULT 0")
        )


def _add_lemma_keys() -> None:
    """Brings a deck built before words were kept as a set up to the new shape.

    There is no migration tool here -- `create_all` builds new databases and
    leaves existing ones alone -- so the one column that changed is added by
    hand. Backfilling it is mechanical, except where the old deck already holds
    the same word twice in different cases, which is the very thing the key
    exists to prevent. Those collapse onto the copy that was added first,
    because that is the one carrying the review history.
    """
    if "lemma_key" in {c["name"] for c in inspect(engine).get_columns("words")}:
        return  # Fresh database: create_all already built it.

    from app.models import Word, deck_key

    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE words ADD COLUMN lemma_key VARCHAR(200)"))

    dropped: list[str] = []
    with SessionLocal() as db:
        seen: set[str] = set()
        for word in list(db.scalars(select(Word).order_by(Word.created_at))):
            key = deck_key(word.lemma)
            if key in seen:
                dropped.append(word.lemma)
                db.delete(word)  # Cards and review logs cascade with it.
                continue
            seen.add(key)
            word.lemma_key = key
        db.commit()

    with engine.begin() as conn:
        conn.execute(text("CREATE UNIQUE INDEX uq_words_lemma_key ON words (lemma_key)"))

    if dropped:
        logger.warning(
            "Merged %d duplicate word(s) already in the deck, keeping the oldest copy of each: %s",
            len(dropped),
            ", ".join(sorted(dropped)),
        )
