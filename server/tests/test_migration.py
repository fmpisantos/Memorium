"""The hand-written migrations, run at every start-up.

There is no migration tool in this project, so this is the code that decides
whether a deck built by an earlier version survives the upgrade. The first one
deletes rows, which is reason enough to test it rather than trust it.
"""

import pytest
from sqlalchemy import inspect, text
from sqlalchemy.exc import IntegrityError

from app.db import _add_lemma_keys, _add_phrase_progress, _add_review_log_practice, engine
from app.models import Base, Card, Phrase, ReviewLog, Word


# The `words` table as the shipped version built it: unique on the lemma
# itself, with no key column. Written out rather than derived, because the
# point of the test is to run against the schema that is actually out there.
OLD_WORDS_TABLE = """
CREATE TABLE words (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    lemma VARCHAR(200) NOT NULL,
    native_gloss VARCHAR(400) NOT NULL,
    pos VARCHAR(40),
    gender VARCHAR(20),
    article VARCHAR(20),
    plural_form VARCHAR(200),
    notes TEXT,
    source VARCHAR(24) NOT NULL,
    enrichment_status VARCHAR(24) NOT NULL,
    created_at DATETIME NOT NULL,
    CONSTRAINT uq_words_lemma UNIQUE (lemma)
)
"""


@pytest.fixture
def old_shape():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE words"))
        conn.execute(text(OLD_WORDS_TABLE))
    yield
    Base.metadata.drop_all(bind=engine)


def _insert(db, lemma: str, created_at: str) -> str:
    """Writes a word the way the old code did -- lemma only, no key."""
    word_id = f"id-{lemma}-{created_at}"
    db.execute(
        text(
            "INSERT INTO words (id, lemma, native_gloss, source, enrichment_status, created_at)"
            " VALUES (:id, :lemma, 'x', 'manual', 'done', :created_at)"
        ),
        {"id": word_id, "lemma": lemma, "created_at": created_at},
    )
    db.execute(
        text(
            "INSERT INTO cards (id, word_id, kind, state, step, reps, lapses, is_leech, due,"
            " created_at) VALUES (:id, :word_id, 'recognition', 1, 0, 0, 0, 0, :due, :due)"
        ),
        {"id": f"card-{word_id}", "word_id": word_id, "due": created_at},
    )
    return word_id


def test_backfill_keys_and_add_the_constraint(old_shape, db):
    _insert(db, "perro", "2024-01-01 00:00:00")
    _insert(db, "Öl", "2024-01-02 00:00:00")
    db.commit()

    _add_lemma_keys()

    assert "lemma_key" in {c["name"] for c in inspect(engine).get_columns("words")}
    assert {w.lemma: w.lemma_key for w in db.query(Word)} == {"perro": "perro", "Öl": "öl"}

    # The constraint is real, not just an app-level check.
    with pytest.raises(IntegrityError, match="lemma_key"):
        db.execute(
            text(
                "INSERT INTO words (id, lemma, lemma_key, native_gloss, source,"
                " enrichment_status, created_at) VALUES ('x', 'Perro', 'perro', 'dog',"
                " 'manual', 'done', '2024-02-01 00:00:00')"
            )
        )
    db.rollback()


def test_a_deck_that_already_holds_a_word_twice_keeps_the_oldest_copy(old_shape, db):
    """The duplicates this change prevents may already be in the deck.

    The older copy is the one that has been reviewed, so it is the one that
    stays -- collapsing onto the newer one would throw away the history.
    """
    kept = _insert(db, "perro", "2024-01-01 00:00:00")
    dropped = _insert(db, "Perro", "2024-06-01 00:00:00")
    db.commit()

    _add_lemma_keys()

    assert [w.id for w in db.query(Word)] == [kept]
    # And it takes the abandoned copy's cards with it, rather than orphaning them.
    assert db.query(Card).filter(Card.word_id == dropped).count() == 0


def test_running_it_again_does_nothing(old_shape, db):
    _insert(db, "perro", "2024-01-01 00:00:00")
    db.commit()

    _add_lemma_keys()
    _add_lemma_keys()  # Every start-up calls it; only the first has work to do.

    assert [w.lemma for w in db.query(Word)] == ["perro"]


# --------------------------------------------------------------------------- #
# Marking an old review log as entirely non-practice
# --------------------------------------------------------------------------- #
OLD_REVIEW_LOGS_TABLE = """
CREATE TABLE review_logs (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    card_id VARCHAR(36) NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    rating INTEGER NOT NULL,
    reviewed_at DATETIME NOT NULL,
    elapsed_days FLOAT,
    mode VARCHAR(20),
    client_grade_id VARCHAR(36) NOT NULL,
    CONSTRAINT uq_review_logs_client_grade_id UNIQUE (client_grade_id)
)
"""


@pytest.fixture
def log_without_practice():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE review_logs"))
        conn.execute(text(OLD_REVIEW_LOGS_TABLE))
    yield
    Base.metadata.drop_all(bind=engine)


def test_reviews_recorded_before_extra_rounds_existed_are_not_practice(
    log_without_practice, db
):
    """Not a guess: practice rounds did not exist, so every one of them counted."""
    word = Word(lemma="perro", native_gloss="dog")
    db.add(word)
    db.flush()
    card = Card(word_id=word.id, kind="recognition")
    db.add(card)
    db.flush()
    # Raw SQL, because the mapped ReviewLog already knows about the column this
    # test exists to add.
    db.execute(
        text(
            "INSERT INTO review_logs (id, card_id, rating, reviewed_at, client_grade_id)"
            " VALUES ('log-1', :card_id, 3, '2024-01-02 00:00:00', 'grade-1')"
        ),
        {"card_id": card.id},
    )
    db.commit()

    _add_review_log_practice()
    _add_review_log_practice()  # Every start-up calls it.

    assert [entry.practice for entry in db.query(ReviewLog)] == [False]


# --------------------------------------------------------------------------- #
# Giving stored sentences somewhere to record how they went
# --------------------------------------------------------------------------- #
OLD_PHRASES_TABLE = """
CREATE TABLE phrases (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    target TEXT NOT NULL,
    native TEXT NOT NULL,
    lemmas JSON NOT NULL,
    source_lang VARCHAR(16) NOT NULL,
    target_lang VARCHAR(16) NOT NULL,
    created_at DATETIME NOT NULL,
    served_count INTEGER NOT NULL,
    last_served_at DATETIME
)
"""


@pytest.fixture
def phrases_without_progress():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE phrases"))
        conn.execute(text(OLD_PHRASES_TABLE))
    yield
    Base.metadata.drop_all(bind=engine)


def test_sentences_written_before_answers_were_recorded_start_unanswered(
    phrases_without_progress, db
):
    """Another backfill that is the truth rather than a guess: there was
    nowhere to record an answer, so none of these has ever been answered."""
    db.execute(
        text(
            "INSERT INTO phrases (id, target, native, lemmas, source_lang, target_lang,"
            " created_at, served_count, last_served_at) VALUES ('p1', 'Frase.', 'Phrase.',"
            " '[\"perro\"]', 'en-US', 'es-ES', '2024-01-01 00:00:00', 3,"
            " '2024-01-02 00:00:00')"
        )
    )
    db.commit()

    _add_phrase_progress()
    _add_phrase_progress()  # Every start-up calls it.

    stored = db.query(Phrase).one()
    assert (stored.attempts, stored.lapses) == (0, 0)
    assert stored.mastered_at is None and stored.retry_after is None
    # The history it did have is still there.
    assert stored.served_count == 3
