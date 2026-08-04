"""The study loop: what to review now, and what grading it does to the schedule."""

from __future__ import annotations

import random
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_profile, require_user
from app.models import Card, CardKind, Profile, ReviewLog, Word, utcnow
from app.scheduler import (
    apply_review,
    audio_autoplays,
    elapsed_days,
    is_practice,
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

router = APIRouter(tags=["study"], dependencies=[Depends(require_user)])

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


def build_study_card(card: Card, word: Word, now: datetime | None = None) -> StudyCard:
    now = now or utcnow()
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
        is_practice=is_practice(card, now),
        due=card.due,
    )


# --------------------------------------------------------------------------- #
# Picking the cards
# --------------------------------------------------------------------------- #
DEFAULT_QUEUE_LIMIT = 120

# An extra round should feel like "a few more", not like reopening the whole
# deck. It has to end for asking for another one to stay a decision.
EXTRA_SESSION_SIZE = 20

# A card answered this recently is still sitting in short-term memory, so
# putting it in an extra round would test the last few minutes rather than
# anything worth knowing.
PRACTICE_COOLDOWN = timedelta(hours=1)


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


def _due_cards(db: Session, now: datetime, limit: int) -> list[Card]:
    """Everything the schedule is actually asking for, soonest-due first."""
    return list(
        db.scalars(
            select(Card)
            .join(Word, Word.id == Card.word_id)
            .where(Card.due <= now, Card.reps > 0)
            .order_by(Card.due.asc())
            .limit(limit)
        )
    )


def _new_word_cards(db: Session, words: int) -> list[Card]:
    """Cards for up to `words` never-reviewed words, oldest addition first.

    The budget is counted in *words*, so a word arrives with all of its cards
    at once: meeting "perro -> dog" today and "dog -> perro" tomorrow would be
    two introductions to one word. Deck order, not random -- you have never
    seen any of these, so there is no sequence to memorise, and working through
    the deck in the order you built it is what you meant by adding them.
    """
    if words <= 0:
        return []
    fresh_word_ids = list(
        db.scalars(
            select(Word.id)
            .join(Card, Card.word_id == Word.id)
            .group_by(Word.id)
            .having(func.max(Card.reps) == 0)
            .order_by(func.min(Word.created_at).asc())
            .limit(words)
        )
    )
    if not fresh_word_ids:
        return []
    return list(
        db.scalars(
            select(Card)
            .where(Card.word_id.in_(fresh_word_ids), Card.reps == 0)
            .order_by(Card.word_id, Card.kind)
        )
    )


def _practice_cards(db: Session, now: datetime, limit: int) -> list[Card]:
    """Cards you already know and are not due for yet, drawn at random.

    Random on purpose. Any fixed order -- by due date, by when the word was
    added, hardest first -- is an order you end up learning, and then the extra
    rounds are testing the sequence instead of the words.

    Cards inside the cooldown sort last rather than being dropped, so a small
    deck still fills a round instead of handing back nothing.
    """
    if limit <= 0:
        return []
    just_seen = Card.last_review > now - PRACTICE_COOLDOWN
    return list(
        db.scalars(
            select(Card)
            .where(Card.due > now, Card.reps > 0)
            .order_by(just_seen.asc(), func.random())
            .limit(limit)
        )
    )


# How many other cards have to sit between two cards of the same word. A word's
# recognition and production cards are mirror images -- "hei -> hi" followed by
# "hi -> hei" hands you the answer you just read, so the second card tests
# nothing. Same for its listening and cloze cards.
SIBLING_GAP = 4


def _space_siblings(cards: list[StudyCard], gap: int = SIBLING_GAP) -> list[StudyCard]:
    """Reorder so no two cards of the same word land within `gap` of each other.

    Greedy and order-preserving: at each slot take the earliest card whose word
    has not appeared in the last `gap` slots, falling back to the earliest
    remaining card when everything left is a sibling. Best-effort by design --
    a queue that is mostly one word cannot be spaced, and dropping cards to
    force it would cost the learner reviews they are due.
    """
    if gap < 1:
        return cards
    remaining = list(cards)
    out: list[StudyCard] = []
    while remaining:
        recent = {c.word_id for c in out[-gap:]}
        pick = next((i for i, c in enumerate(remaining) if c.word_id not in recent), 0)
        out.append(remaining.pop(pick))
    return out


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
    extra: bool = Query(
        default=False,
        description="Another round, asked for after the day's work is done.",
    ),
    limit: int | None = Query(default=None, ge=1, le=500),
):
    """The cards to study now.

    Two shapes. The default is the day's work: everything due, plus new words
    up to the daily budget. `extra=true` is the round you ask for once that is
    finished -- a fresh budget's worth of new words, topped up with cards you
    already know, shuffled.

    The daily limit is a pace for meeting *new* words, not a cap on studying,
    so an extra round is always available and never refuses to serve a card.
    Answering one early costs nothing either: see `scheduler.is_practice`.
    """
    now = utcnow()
    limit = limit or (EXTRA_SESSION_SIZE if extra else DEFAULT_QUEUE_LIMIT)

    due_cards = _due_cards(db, now, limit)

    introduced = _words_introduced_today(db, profile)
    new_remaining = max(0, profile.daily_new_limit - introduced)
    # An extra round gets a whole budget again rather than the day's remainder,
    # which is spent by definition once anyone is asking for one.
    new_cards = _new_word_cards(db, profile.daily_new_limit if extra else new_remaining)

    practice_cards = (
        _practice_cards(db, now, limit - len(due_cards) - len(new_cards)) if extra else []
    )

    review_out = [build_study_card(c, c.word, now) for c in due_cards]
    new_out = [build_study_card(c, c.word, now) for c in new_cards]
    practice_out = [build_study_card(c, c.word, now) for c in practice_cards]

    if extra:
        # Shuffled rather than interleaved: an extra round is the one place
        # where the order is arbitrary, so it may as well be unlearnable.
        cards = review_out + new_out + practice_out
        random.shuffle(cards)
    else:
        cards = _interleave(review_out, new_out)

    return StudyQueue(
        target_lang=profile.target_lang,
        source_lang=profile.source_lang,
        cards=_space_siblings(cards),
        due_count=len(review_out),
        new_count=len(new_out),
        practice_count=len(practice_out),
        new_remaining_today=new_remaining,
        extra=extra,
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

        # Answering a card ahead of its due date is extra practice: it goes in
        # the log, and the schedule stays exactly where it was. The card itself
        # decides this, not the client, so a queue fetched hours ago -- or an
        # outbox flushed days late -- cannot talk us into rescheduling.
        practice = is_practice(card, reviewed_at)
        elapsed = (
            elapsed_days(card, reviewed_at)
            if practice
            else apply_review(card, item.rating, profile, reviewed_at=reviewed_at)
        )

        db.add(
            ReviewLog(
                card_id=card.id,
                rating=item.rating,
                reviewed_at=reviewed_at,
                elapsed_days=elapsed,
                mode=item.mode,
                client_grade_id=item.client_grade_id,
                practice=practice,
            )
        )
        seen.add(item.client_grade_id)

        # Both of these follow from the review having moved the card. Practice
        # did not, so there is nothing to save and nothing new to earn.
        unlocked: list[CardKind] = []
        if not practice:
            db.add(card)
            unlocked = _unlock_for_word(db, card.word_id)

        results.append(
            GradeResult(
                client_grade_id=item.client_grade_id,
                card_id=card.id,
                accepted=True,
                practice=practice,
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
