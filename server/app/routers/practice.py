"""Whole sentences, built from words the learner already knows.

Cards teach one word at a time, which is where recall starts and not where it
ends -- knowing "trenger" on sight is a different skill from producing it in a
sentence while you are trying to say something. This is that second skill: hear
a sentence and write it down, or read it in one language and say it in the
other, with every content word drawn from vocabulary already in the deck.

Nothing here touches the schedule. Cards carry the deck's memory; a phrase
answered well or badly moves nothing, so practice is free.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_profile, require_user
from app.enrichment import get_service
from app.llm.base import ContentGenerationError
from app.models import Card, Phrase, Profile, Word, deck_key, utcnow
from app.schemas import PhraseOut, PhraseSetOut

log = logging.getLogger("memorium.practice")

router = APIRouter(tags=["practice"], dependencies=[Depends(require_user)])

# Below this there is nothing to build a sentence out of, and the honest answer
# is to say so rather than to hand back four sentences about a dog.
MIN_KNOWN_WORDS = 5

# How much vocabulary to put in front of the generator. Enough to write varied
# sentences; not so much that the prompt is mostly word list.
VOCABULARY_SAMPLE = 60

# Words the schedule says are closest to being forgotten. Naming them keeps a
# session pointed at the words that need the work, instead of the handful the
# generator happens to find easiest to use.
FOCUS_WORDS = 8

# Sentences are written a batch at a time, not a session at a time. Writing
# twelve costs about what writing six does and leaves the next session ready
# to start on the spot -- and ready to happen at all without a connection.
BATCH_SIZE = 12


# --------------------------------------------------------------------------- #
# What counts as vocabulary
# --------------------------------------------------------------------------- #
def _known_lemmas(db: Session, limit: int = VOCABULARY_SAMPLE) -> list[str]:
    """Words to build sentences from, best-known first.

    Reviewed words come first: "known" should mean the learner has met it, not
    that it sits unstudied in the deck. But a deck built by importing a word
    list is a deck of words met somewhere else, so the rest of it tops up the
    sample rather than being treated as unknown -- otherwise a fresh import
    can't practise at all.
    """
    reviewed = list(
        db.scalars(
            select(Word.lemma)
            .join(Card, Card.word_id == Word.id)
            .where(Card.reps > 0)
            .group_by(Word.id)
            .order_by(func.max(Card.stability).desc().nullslast())
            .limit(limit)
        )
    )
    if len(reviewed) >= limit:
        return reviewed
    rest = list(
        db.scalars(
            select(Word.lemma)
            .where(Word.lemma.notin_(reviewed))
            .order_by(Word.created_at.asc())
            .limit(limit - len(reviewed))
        )
    )
    return reviewed + rest


def _focus_lemmas(db: Session, limit: int = FOCUS_WORDS) -> list[str]:
    """Reviewed words with the nearest due date -- the ones going stale."""
    return list(
        db.scalars(
            select(Word.lemma)
            .join(Card, Card.word_id == Word.id)
            .where(Card.reps > 0)
            .group_by(Word.id)
            .order_by(func.min(Card.due).asc())
            .limit(limit)
        )
    )


# --------------------------------------------------------------------------- #
# The stored pool
# --------------------------------------------------------------------------- #
def _still_in_deck(phrase: Phrase, deck: set[str]) -> bool:
    """Has this sentence outlived the words it was made of?

    One surviving word is enough. Requiring all of them would retire good
    sentences over a single deleted word, and a phrase that records none of
    its vocabulary -- the generator declined to say -- is kept rather than
    quietly thrown away.
    """
    lemmas = [str(lemma) for lemma in (phrase.lemmas or [])]
    return not lemmas or any(deck_key(lemma) in deck for lemma in lemmas)


def _pool(
    db: Session,
    profile: Profile,
    limit: int,
    *,
    unseen_only: bool,
    exclude: set[str] | None = None,
) -> list[Phrase]:
    """Stored phrases for this language pair, least practised first."""
    if limit <= 0:
        return []
    query = select(Phrase).where(
        Phrase.target_lang == profile.target_lang,
        Phrase.source_lang == profile.source_lang,
    )
    if unseen_only:
        query = query.where(Phrase.last_served_at.is_(None))
    if exclude:
        query = query.where(Phrase.id.notin_(exclude))

    # Over-fetch, because some of what comes back may have outlived its words.
    candidates = list(
        db.scalars(
            query.order_by(
                Phrase.last_served_at.asc().nullsfirst(), Phrase.created_at.asc()
            ).limit(limit * 3)
        )
    )
    deck = set(db.scalars(select(Word.lemma_key)))
    return [phrase for phrase in candidates if _still_in_deck(phrase, deck)][:limit]


async def _generate(
    db: Session, profile: Profile, count: int, known: list[str], focus: list[str]
) -> list[Phrase]:
    """Write `count` new sentences and keep them.

    Raises `ContentGenerationError`, which the caller treats as "serve what is
    already stored" rather than as a failed session.
    """
    result = await get_service().generator.practice_phrases(
        count=count,
        known_words=known,
        focus_words=focus,
        source_lang=profile.source_lang,
        target_lang=profile.target_lang,
    )

    # A sentence already in the pool is not practice, it is the same card
    # again. Checked case-insensitively and against this batch as well as the
    # store, since a generator asked twice in a day repeats itself.
    seen = {
        target.casefold()
        for target in db.scalars(
            select(Phrase.target).where(Phrase.target_lang == profile.target_lang)
        )
    }
    fresh: list[Phrase] = []
    for phrase in result.phrases:
        target = phrase.target.strip()
        native = phrase.native.strip()
        if not target or not native or target.casefold() in seen:
            continue
        seen.add(target.casefold())
        fresh.append(
            Phrase(
                target=target,
                native=native,
                lemmas=[use.strip() for use in phrase.uses if use.strip()],
                source_lang=profile.source_lang,
                target_lang=profile.target_lang,
            )
        )

    db.add_all(fresh)
    db.commit()
    return fresh


def _mark_served(db: Session, phrases: list[Phrase]) -> None:
    now = utcnow()
    for phrase in phrases:
        phrase.served_count += 1
        phrase.last_served_at = now
    db.add_all(phrases)
    db.commit()


# --------------------------------------------------------------------------- #
@router.get("/practice/phrases", response_model=PhraseSetOut)
async def practice_phrases(
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
    count: int = Query(default=8, ge=1, le=20),
    refresh: bool = Query(
        default=False, description="Skip the stored pool and write new sentences."
    ),
):
    """A session's worth of sentences.

    Unpractised sentences are served first and new ones written when the pool
    runs short, so a session is new material by default. When Claude cannot be
    reached the pool answers instead: a sentence practised a week ago is a
    great deal better than an error message, and this is the feature most
    likely to be wanted on a train.
    """
    known = _known_lemmas(db)
    if len(known) < MIN_KNOWN_WORDS:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "Phrases are built from words you already know, and there aren't "
            f"enough in the deck yet — add at least {MIN_KNOWN_WORDS}.",
        )

    phrases = [] if refresh else _pool(db, profile, count, unseen_only=True)

    failure: Exception | None = None
    if len(phrases) < count:
        shortfall = count - len(phrases)
        try:
            written = await _generate(
                db, profile, max(shortfall, BATCH_SIZE), known, _focus_lemmas(db)
            )
            # The rest of the batch stays unserved for next time.
            phrases += written[:shortfall]
        except ContentGenerationError as exc:
            log.warning("phrase generation failed: %s", exc)
            failure = exc

    if len(phrases) < count:
        # Repeats, rather than a short session. Practising a sentence twice is
        # the ordinary way this works once the pool has been round once.
        phrases += _pool(
            db,
            profile,
            count - len(phrases),
            unseen_only=False,
            exclude={phrase.id for phrase in phrases},
        )

    if not phrases:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            f"Couldn't write any phrases: {failure}"
            if failure
            else "Couldn't write any phrases.",
        )

    _mark_served(db, phrases)
    return PhraseSetOut(
        target_lang=profile.target_lang,
        source_lang=profile.source_lang,
        phrases=[PhraseOut.model_validate(phrase) for phrase in phrases],
    )
