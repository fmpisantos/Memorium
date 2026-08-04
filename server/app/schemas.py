from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.models import CardKind, EnrichmentStatus, WordSource

# --------------------------------------------------------------------------- #
# Profile
# --------------------------------------------------------------------------- #
class ProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    source_lang: str
    target_lang: str
    desired_retention: float
    daily_new_limit: int
    timezone: str


class ProfileUpdate(BaseModel):
    source_lang: str | None = None
    target_lang: str | None = None
    desired_retention: Annotated[float, Field(ge=0.70, le=0.99)] | None = None
    daily_new_limit: Annotated[int, Field(ge=0, le=200)] | None = None
    timezone: str | None = None


# --------------------------------------------------------------------------- #
# Words
# --------------------------------------------------------------------------- #
class WordCreate(BaseModel):
    lemma: Annotated[str, Field(min_length=1, max_length=200)]
    native_gloss: Annotated[str, Field(min_length=1, max_length=400)]
    notes: str | None = None
    source: WordSource = WordSource.manual


class WordBatchCreate(BaseModel):
    """Bulk add. OCR import posts here after the review screen."""

    words: Annotated[list[WordCreate], Field(min_length=1, max_length=500)]


class WordUpdate(BaseModel):
    lemma: str | None = None
    native_gloss: str | None = None
    notes: str | None = None


class SentenceOut(BaseModel):
    target: str
    native: str
    cloze_word: str | None = None


class EnrichmentOut(BaseModel):
    sentences: list[SentenceOut] = []
    mnemonic: str | None = None


class CardOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    kind: CardKind
    state: int
    stability: float | None
    difficulty: float | None
    due: datetime
    reps: int
    lapses: int
    is_leech: bool


class WordOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    lemma: str
    native_gloss: str
    pos: str | None
    gender: str | None
    article: str | None
    plural_form: str | None
    notes: str | None
    source: WordSource
    enrichment_status: EnrichmentStatus
    created_at: datetime
    cards: list[CardOut] = []


class WordBatchResult(BaseModel):
    created: list[WordOut]
    duplicates: list[str] = Field(
        default=[],
        description="Lemmas already in the deck. Skipped rather than duplicated.",
    )


# --------------------------------------------------------------------------- #
# Study
# --------------------------------------------------------------------------- #
class StudyCard(BaseModel):
    """Everything the app needs to render a card without another round trip.

    The client caches these for the session so a dropped connection mid-review
    doesn't end the session.
    """

    card_id: str
    word_id: str
    kind: CardKind

    lemma: str
    native_gloss: str
    article: str | None = None
    pos: str | None = None

    # What to show on each side, already resolved server-side.
    prompt: str
    answer: str
    # Text to speak, always in the target language.
    speech_text: str
    # False on production/cloze, where the audio would give away the answer.
    audio_autoplay: bool

    sentence_target: str | None = None
    sentence_native: str | None = None
    cloze_answer: str | None = None

    is_new: bool
    is_leech: bool
    # Not due yet -- served because the learner asked for extra practice.
    # Answering it is logged but does not move the schedule.
    is_practice: bool = False
    due: datetime


class StudyQueue(BaseModel):
    target_lang: str
    source_lang: str
    cards: list[StudyCard]
    due_count: int
    new_count: int
    practice_count: int = 0
    new_remaining_today: int
    # True when this queue came from an extra round rather than the day's work.
    extra: bool = False


class GradeIn(BaseModel):
    # Client-generated so a replayed outbox flush is a no-op instead of a
    # second review that corrupts the schedule.
    client_grade_id: str
    card_id: str
    rating: Annotated[int, Field(ge=1, le=4)]  # 1=Again 2=Hard 3=Good 4=Easy
    reviewed_at: datetime | None = None
    mode: Literal["typed", "tapped", "speaking"] | None = None


class GradeBatchIn(BaseModel):
    grades: Annotated[list[GradeIn], Field(min_length=1, max_length=500)]


class GradeResult(BaseModel):
    client_grade_id: str
    card_id: str
    accepted: bool
    duplicate: bool = False
    # Recorded, but the schedule was deliberately left where it was.
    practice: bool = False
    next_due: datetime | None = None
    interval_days: float | None = None
    is_leech: bool = False
    unlocked_kinds: list[CardKind] = []


class GradeBatchResult(BaseModel):
    results: list[GradeResult]
