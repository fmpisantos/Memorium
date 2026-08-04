from __future__ import annotations

import enum
import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Enum as SAEnum,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    TypeDecorator,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship, validates
from sqlalchemy.types import JSON


class Base(DeclarativeBase):
    pass


def normalise_lemma(lemma: str) -> str:
    """Collapses the whitespace that comes along with a paste."""
    return " ".join(lemma.split())


def deck_key(lemma: str) -> str:
    """The deck's identity for a word: one entry per word, whatever case it was
    typed in.

    The learner sees 'perro' and 'Perro' as the same word, and so does the deck
    -- the translator capitalises a word it returns on its own, so the two
    spellings arrive by perfectly ordinary routes.

    Casefolded here rather than compared with `lower()` in SQL, because
    SQLite's `lower()` is ASCII-only: it would file Öl and öl as two words.
    """
    return normalise_lemma(lemma).casefold()


class UTCDateTime(TypeDecorator):
    """Always store UTC, always return tz-aware UTC.

    SQLite silently drops tzinfo, which makes `card.due < now` compare a naive
    datetime against an aware one and raise at runtime -- or worse, compare
    wrong after a DST shift. Normalising at the type boundary means the rest of
    the codebase can assume every datetime is aware.
    """

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError(f"refusing to store naive datetime: {value!r}")
        return value.astimezone(UTC)

    def process_result_value(self, value: datetime | None, dialect):
        if value is None:
            return None
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def enum_column(enum_cls, length: int = 24):
    """Store the enum's *value* and hand back real enum members on load.

    A plain String column returns `str`, which makes `card.kind is
    CardKind.recognition` silently False even though the values match -- every
    branch falls through to the last one. Round-tripping as enum members keeps
    identity comparisons honest.
    """
    return SAEnum(
        enum_cls,
        native_enum=False,
        length=length,
        values_callable=lambda e: [m.value for m in e],
        validate_strings=True,
    )


def _uuid() -> str:
    return str(uuid.uuid4())


def utcnow() -> datetime:
    return datetime.now(UTC)


# --------------------------------------------------------------------------- #
# Enums
# --------------------------------------------------------------------------- #
class CardKind(str, enum.Enum):
    recognition = "recognition"  # target -> native   (audio auto-plays)
    production = "production"  # native -> target   (audio on reveal only)
    listening = "listening"  # audio  -> meaning  (audio auto-plays, no text)
    cloze = "cloze"  # typed answer inside a sentence


class WordSource(str, enum.Enum):
    manual = "manual"
    ocr = "ocr"


class EnrichmentStatus(str, enum.Enum):
    pending = "pending"
    queued = "queued"
    running = "running"
    done = "done"
    failed = "failed"


# --------------------------------------------------------------------------- #
# Tables
# --------------------------------------------------------------------------- #
class Profile(Base):
    """Single-row table (id=1) holding the learner's configuration."""

    __tablename__ = "profiles"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    source_lang: Mapped[str] = mapped_column(String(16))  # BCP-47, e.g. "en-US"
    target_lang: Mapped[str] = mapped_column(String(16))  # BCP-47, e.g. "es-ES"
    desired_retention: Mapped[float] = mapped_column(Float, default=0.90)
    daily_new_limit: Mapped[int] = mapped_column(Integer, default=10)
    # IANA zone. The daily new-word limit rolls over at local midnight, not UTC
    # midnight, or a late-evening session silently borrows tomorrow's quota.
    timezone: Mapped[str] = mapped_column(String(64), default="UTC")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class Word(Base):
    __tablename__ = "words"
    # Uniqueness lives on the key, not the lemma: it is the stronger of the two
    # (no two lemmas can share a key) and it is the one the learner means.
    __table_args__ = (UniqueConstraint("lemma_key", name="uq_words_lemma_key"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    lemma: Mapped[str] = mapped_column(String(200), index=True)
    # Derived from the lemma, never set by hand -- see the validator below.
    lemma_key: Mapped[str] = mapped_column(String(200))
    native_gloss: Mapped[str] = mapped_column(String(400))

    # Filled by enrichment; all optional so a word is usable the moment it's added.
    pos: Mapped[str | None] = mapped_column(String(40), default=None)
    gender: Mapped[str | None] = mapped_column(String(20), default=None)
    article: Mapped[str | None] = mapped_column(String(20), default=None)
    plural_form: Mapped[str | None] = mapped_column(String(200), default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    source: Mapped[WordSource] = mapped_column(enum_column(WordSource), default=WordSource.manual)
    enrichment_status: Mapped[EnrichmentStatus] = mapped_column(
        enum_column(EnrichmentStatus), default=EnrichmentStatus.pending, index=True
    )
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    cards: Mapped[list[Card]] = relationship(
        back_populates="word", cascade="all, delete-orphan", lazy="selectin"
    )
    enrichment: Mapped[Enrichment | None] = relationship(
        back_populates="word", cascade="all, delete-orphan", uselist=False, lazy="selectin"
    )

    def __init__(self, **kw):
        kw.setdefault("source", WordSource.manual)
        kw.setdefault("enrichment_status", EnrichmentStatus.pending)
        kw.setdefault("created_at", utcnow())
        super().__init__(**kw)

    @validates("lemma")
    def _keep_key_in_step(self, _field: str, lemma: str) -> str:
        """Ties the key to the lemma at every write, new word or rename alike.

        A key that a caller has to remember to set is a key that goes stale on
        the one path nobody thought about, and a stale key means a duplicate
        the unique constraint cannot see.
        """
        lemma = normalise_lemma(lemma)
        self.lemma_key = deck_key(lemma)
        return lemma


class Card(Base):
    """One scheduled review item. A word owns several, scheduled independently.

    The FSRS fields mirror `fsrs.Card`; reps/lapses/is_leech are ours (FSRS v6
    does not track them) and drive leech detection.
    """

    __tablename__ = "cards"
    __table_args__ = (UniqueConstraint("word_id", "kind", name="uq_cards_word_kind"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    word_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("words.id", ondelete="CASCADE"), index=True
    )
    kind: Mapped[CardKind] = mapped_column(enum_column(CardKind))

    # --- FSRS state ---
    state: Mapped[int] = mapped_column(Integer, default=1)  # 1=Learning 2=Review 3=Relearning
    step: Mapped[int | None] = mapped_column(Integer, default=0)
    stability: Mapped[float | None] = mapped_column(Float, default=None)
    difficulty: Mapped[float | None] = mapped_column(Float, default=None)
    due: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    last_review: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)

    # --- our bookkeeping ---
    reps: Mapped[int] = mapped_column(Integer, default=0)
    lapses: Mapped[int] = mapped_column(Integer, default=0)
    is_leech: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    word: Mapped[Word] = relationship(back_populates="cards")

    def __init__(self, **kw):
        # `mapped_column(default=...)` only fires on INSERT, so a Card that has
        # not been flushed yet would carry None everywhere -- and State(None)
        # raises. Scheduling logic operates on unflushed cards, so the defaults
        # have to exist in Python too.
        kw.setdefault("state", 1)  # fsrs.State.Learning
        kw.setdefault("step", 0)
        kw.setdefault("reps", 0)
        kw.setdefault("lapses", 0)
        kw.setdefault("is_leech", False)
        kw.setdefault("due", utcnow())
        kw.setdefault("created_at", utcnow())
        super().__init__(**kw)


class ReviewLog(Base):
    """Append-only review history. Never mutated.

    This is what lets the FSRS optimiser re-fit parameters to your actual
    forgetting curve later, so it must stay complete and immutable.
    """

    __tablename__ = "review_logs"
    __table_args__ = (
        UniqueConstraint("client_grade_id", name="uq_review_logs_client_grade_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    card_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("cards.id", ondelete="CASCADE"), index=True
    )
    rating: Mapped[int] = mapped_column(Integer)  # 1=Again 2=Hard 3=Good 4=Easy
    reviewed_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    elapsed_days: Mapped[float | None] = mapped_column(Float, default=None)
    mode: Mapped[str | None] = mapped_column(String(20), default=None)  # e.g. "speaking"

    # A review the learner asked for, taken before the card came due. Recorded
    # like any other -- it happened, and the optimiser should be able to see it
    # -- but flagged, because it left the schedule alone. See scheduler.is_practice.
    practice: Mapped[bool] = mapped_column(Boolean, default=False)

    # Client-generated UUID. Makes outbox flushes idempotent: replaying a grade
    # after a flaky connection must not double-schedule the card.
    client_grade_id: Mapped[str] = mapped_column(String(36), index=True)

    def __init__(self, **kw):
        kw.setdefault("practice", False)
        super().__init__(**kw)


class Enrichment(Base):
    __tablename__ = "enrichments"

    word_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("words.id", ondelete="CASCADE"), primary_key=True
    )
    schema_version: Mapped[int] = mapped_column(Integer, default=1)
    payload: Mapped[dict] = mapped_column(JSON)  # sentences, cloze indices, grammar
    mnemonic: Mapped[str | None] = mapped_column(Text, default=None)
    generated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    error: Mapped[str | None] = mapped_column(Text, default=None)

    word: Mapped[Word] = relationship(back_populates="enrichment")
