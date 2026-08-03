"""The study loop: what to review now, and what grading it does to the schedule."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_profile, require_token
from app.models import Card, CardKind, Profile, ReviewLog, Word, utcnow
from app.scheduler import (
    apply_review,
    audio_autoplays,
    kinds_to_unlock,
    local_day_start,
    next_interval_days,
)
from app.schemas import (
    GradeBatchIn,
    GradeBatchResult,
    GradeResult,
    StudyCard,
    StudyQueue,
)

router = APIRouter(tags=["study"], dependencies=[Depends(require_token)])

BLANK = "____"


# --------------------------------------------------------------------------- #
# Rendering a card
# --------------------------------------------------------------------------- #
def _display_lemma(word: Word) -> str:
    """Include the article when we know it -- 'el perro' teaches gender, 'perro' doesn't."""
    return f"{word.article} {word.lemma}" if word.article else word.lemma


def _first_sentence(word: Word) -> dict | None:
    if word.enrichment is None or not word.enrichment.payload:
        return None
    sentences = word.enrichment.payload.get("sentences") or []
    return sentences[0] if sentences else None


def build_study_card(card: Card, word: Word) -> StudyCard:
    display = _display_lemma(word)
    sentence = _first_sentence(word)
    sentence_target = sentence.get("target") if sentence else None
    sentence_native = sentence.get("native") if sentence else None

    cloze_answer = None
    prompt: str
    answer: str
    speech_text = word.lemma

    if card.kind is CardKind.recognition:
        prompt, answer = display, word.native_gloss

    elif card.kind is CardKind.production:
        prompt, answer = word.native_gloss, display

    elif card.kind is CardKind.listening:
        # No text on the prompt side at all -- the audio is the question.
        prompt, answer = "", f"{display} — {word.native_gloss}"

    else:  # cloze
        target = sentence_target or ""
        cloze_answer = (sentence or {}).get("cloze_word") or word.lemma
        prompt = (
            target.replace(cloze_answer, BLANK, 1)
            if cloze_answer and cloze_answer in target
            else target
        )
        answer = cloze_answer
        # Speak the whole sentence so you hear the word in context.
        speech_text = target or word.lemma

    return StudyCard(
        card_id=card.id,
        word_id=word.id,
        kind=card.kind,
        lemma=word.lemma,
        native_gloss=word.native_gloss,
        article=word.article,
        pos=word.pos,
        prompt=prompt,
        answer=answer,
        speech_text=speech_text,
        audio_autoplay=audio_autoplays(card.kind),
        sentence_target=sentence_target,
        sentence_native=sentence_native,
        cloze_answer=cloze_answer,
        is_new=card.reps == 0,
        is_leech=card.is_leech,
        due=card.due,
    )


# --------------------------------------------------------------------------- #
# Daily new-word budget
# --------------------------------------------------------------------------- #
def _words_introduced_today(db: Session, profile: Profile) -> int:
    """Distinct words whose first-ever review happened today (learner-local)."""
    day_start = local_day_start(profile)
    first_seen = (
        select(Card.word_id.label("word_id"), func.min(ReviewLog.reviewed_at).label("first_seen"))
        .join(ReviewLog, ReviewLog.card_id == Card.id)
        .group_by(Card.word_id)
        .subquery()
    )
    return (
        db.scalar(
            select(func.count()).select_from(first_seen).where(first_seen.c.first_seen >= day_start)
        )
        or 0
    )


def _interleave(reviews: list[StudyCard], new: list[StudyCard]) -> list[StudyCard]:
    """Spread new cards through the reviews.

    All-new-first is discouraging and all-reviews-first means new material only
    ever arrives when you're already tired.
    """
    if not new:
        return reviews
    if not reviews:
        return new
    out: list[StudyCard] = []
    gap = max(1, len(reviews) // len(new))
    new_iter = iter(new)
    for i, card in enumerate(reviews):
        out.append(card)
        if i % gap == gap - 1:
            nxt = next(new_iter, None)
            if nxt is not None:
                out.append(nxt)
    out.extend(new_iter)
    return out


@router.get("/study/queue", response_model=StudyQueue)
def study_queue(
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
    limit: int = Query(default=120, ge=1, le=500),
):
    now = utcnow()

    due_cards = list(
        db.scalars(
            select(Card)
            .join(Word, Word.id == Card.word_id)
            .where(Card.due <= now, Card.reps > 0)
            .order_by(Card.due.asc())
            .limit(limit)
        )
    )

    introduced = _words_introduced_today(db, profile)
    new_remaining = max(0, profile.daily_new_limit - introduced)

    new_cards: list[Card] = []
    if new_remaining > 0:
        # Budget is in *words*, so pull whole words and take all their cards.
        fresh_word_ids = list(
            db.scalars(
                select(Word.id)
                .join(Card, Card.word_id == Word.id)
                .group_by(Word.id)
                .having(func.max(Card.reps) == 0)
                .order_by(func.min(Word.created_at).asc())
                .limit(new_remaining)
            )
        )
        if fresh_word_ids:
            new_cards = list(
                db.scalars(
                    select(Card)
                    .where(Card.word_id.in_(fresh_word_ids), Card.reps == 0)
                    .order_by(Card.word_id, Card.kind)
                )
            )

    review_out = [build_study_card(c, c.word) for c in due_cards]
    new_out = [build_study_card(c, c.word) for c in new_cards]

    return StudyQueue(
        target_lang=profile.target_lang,
        source_lang=profile.source_lang,
        cards=_interleave(review_out, new_out),
        due_count=len(review_out),
        new_count=len(new_out),
        new_remaining_today=new_remaining,
    )


# --------------------------------------------------------------------------- #
# Grading
# --------------------------------------------------------------------------- #
@router.post("/study/grade", response_model=GradeBatchResult)
def grade(
    payload: GradeBatchIn,
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
):
    """Apply a batch of grades. Safe to replay.

    The app writes grades to a local outbox and flushes them here, so the same
    batch can legitimately arrive twice after a flaky connection. Idempotency
    is keyed on the client-generated grade id: a replay reports the card's
    current state instead of reviewing it a second time.
    """
    results: list[GradeResult] = []

    seen = set(
        db.scalars(
            select(ReviewLog.client_grade_id).where(
                ReviewLog.client_grade_id.in_([g.client_grade_id for g in payload.grades])
            )
        ).all()
    )

    for item in payload.grades:
        card = db.get(Card, item.card_id)
        if card is None:
            results.append(
                GradeResult(
                    client_grade_id=item.client_grade_id,
                    card_id=item.card_id,
                    accepted=False,
                )
            )
            continue

        if item.client_grade_id in seen:
            results.append(
                GradeResult(
                    client_grade_id=item.client_grade_id,
                    card_id=card.id,
                    accepted=True,
                    duplicate=True,
                    next_due=card.due,
                    interval_days=next_interval_days(card),
                    is_leech=card.is_leech,
                )
            )
            continue

        reviewed_at = item.reviewed_at or utcnow()
        elapsed = apply_review(card, item.rating, profile, reviewed_at=reviewed_at)

        db.add(
            ReviewLog(
                card_id=card.id,
                rating=item.rating,
                reviewed_at=reviewed_at,
                elapsed_days=elapsed,
                mode=item.mode,
                client_grade_id=item.client_grade_id,
            )
        )
        db.add(card)
        seen.add(item.client_grade_id)

        unlocked = _unlock_for_word(db, card.word_id)

        results.append(
            GradeResult(
                client_grade_id=item.client_grade_id,
                card_id=card.id,
                accepted=True,
                next_due=card.due,
                interval_days=next_interval_days(card, reviewed_at),
                is_leech=card.is_leech,
                unlocked_kinds=unlocked,
            )
        )

    db.commit()
    return GradeBatchResult(results=results)


def _unlock_for_word(db: Session, word_id: str) -> list[CardKind]:
    word = db.get(Word, word_id)
    if word is None:
        return []
    by_kind = {c.kind: c for c in word.cards}
    has_enrichment = word.enrichment is not None and bool(
        (word.enrichment.payload or {}).get("sentences")
    )
    kinds = kinds_to_unlock(by_kind, has_enrichment)
    now = utcnow()
    for kind in kinds:
        db.add(Card(word_id=word_id, kind=kind, due=now))
    return kinds


@router.get("/leeches", response_model=list[StudyCard])
def leeches(db: Session = Depends(get_db)):
    """Words that keep beating you. Surfaced for different treatment."""
    cards = list(
        db.scalars(
            select(Card).where(Card.is_leech.is_(True)).order_by(Card.lapses.desc()).limit(100)
        )
    )
    return [build_study_card(c, c.word) for c in cards]
