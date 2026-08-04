"""Whole sentences, built from words the learner already knows.

Cards teach one word at a time, which is where recall starts and not where it
ends -- knowing "trenger" on sight is a different skill from producing it in a
sentence while you are trying to say something. This is that second skill: hear
a sentence and write it down, or read it in one language and say it in the
other, with every content word drawn from vocabulary already in the deck.

The sentences themselves are written ahead of time and kept; `app.phrases` owns
that pool and the rotation that decides which words go into it. This is the
serving end: hand out what is stored, take back how it went, and wake the
writer on the way out.

Nothing here touches the schedule. Cards carry the deck's memory; a phrase
answered well or badly moves nothing, so practice is free.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import phrases as pool_module
from app.db import get_db
from app.deps import get_profile, require_user
from app.llm.base import ContentGenerationError
from app.models import Phrase, PhraseAttempt, Profile, utcnow
from app.phrases import BATCH_SIZE, MIN_KNOWN_WORDS, get_pool
from app.schemas import (
    PhraseOut,
    PhraseResultBatchIn,
    PhraseResultBatchResult,
    PhraseResultOut,
    PhraseSetOut,
)

log = logging.getLogger("memorium.practice")

router = APIRouter(tags=["practice"], dependencies=[Depends(require_user)])


# --------------------------------------------------------------------------- #
@router.get("/practice/phrases", response_model=PhraseSetOut)
async def practice_phrases(
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
    count: int = Query(default=8, ge=1, le=20),
    refresh: bool = Query(
        default=False, description="Only sentences that have never been served."
    ),
):
    """A session's worth of sentences.

    Served from the pool, which the background writer keeps stocked -- so this
    normally returns as fast as any other request rather than waiting on a
    generation. Sentences you have not answered yet come first, then the ones
    you got wrong and have sat out their cooling-off period; a sentence
    answered correctly does not come back.

    Only an empty pool generates while the learner waits, because a first
    session has to come from somewhere. When Claude cannot be reached at all
    the pool answers instead: a sentence practised last week is a great deal
    better than an error message, and this is the feature most likely to be
    wanted on a train.
    """
    if len(pool_module.known_lemmas(db)) < MIN_KNOWN_WORDS:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "Phrases are built from words you already know, and there aren't "
            f"enough in the deck yet — add at least {MIN_KNOWN_WORDS}.",
        )

    pool = get_pool()
    served = pool_module.available(db, profile, count, unseen_only=refresh)

    failure: Exception | None = None
    # Writing here is the exception, not the rule: an empty pool (a first
    # session, or one held up behind a long import) and an explicit ask for
    # material never seen before.
    if len(served) < count and (refresh or not served):
        shortfall = count - len(served)
        try:
            written = await pool.write_now(db, profile, max(shortfall, BATCH_SIZE))
            # The rest of the batch stays unserved for next time.
            served += written[:shortfall]
        except ContentGenerationError as exc:
            log.warning("phrase generation failed: %s", exc)
            failure = exc

    if len(served) < count:
        # Sentences still cooling off after a wrong answer, rather than a short
        # session. Being asked one again sooner than planned is a small price
        # against being handed four cards and told that is the session.
        served += pool_module.available(
            db,
            profile,
            count - len(served),
            ignore_cooldown=True,
            exclude={phrase.id for phrase in served},
        )

    if len(served) < count:
        # Everything left is already answered. Repeats beat an empty screen.
        served += pool_module.available(
            db,
            profile,
            count - len(served),
            ignore_cooldown=True,
            include_mastered=True,
            exclude={phrase.id for phrase in served},
        )

    if not served:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            f"Couldn't write any phrases: {failure}"
            if failure
            else "Couldn't write any phrases.",
        )

    pool_module.mark_served(db, served)
    # Whatever was just handed out has left the pool for as long as it takes to
    # answer it, so the batch replacing it is written now -- while the learner
    # is still working through this one -- rather than at the next tick.
    pool.request_top_up()

    return PhraseSetOut(
        target_lang=profile.target_lang,
        source_lang=profile.source_lang,
        phrases=[PhraseOut.model_validate(phrase) for phrase in served],
        pool_depth=pool_module.depth(db, profile),
    )


@router.post("/practice/phrases/results", response_model=PhraseResultBatchResult)
def phrase_results(
    payload: PhraseResultBatchIn,
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
):
    """Record how a set of phrases went. Safe to replay.

    A sentence answered correctly is done and drops out of the rotation; one
    answered wrong stays in it, and comes back after a cooling-off period.
    Nothing here touches the schedule -- see the note at the top of the module.

    Idempotency is keyed on the client-generated result id, so an outbox flush
    replayed after a flaky connection reports the sentence's current state
    instead of counting a second attempt against it.
    """
    ids = [item.client_result_id for item in payload.results]
    seen = set(
        db.scalars(
            select(PhraseAttempt.client_result_id).where(
                PhraseAttempt.client_result_id.in_(ids)
            )
        ).all()
    )

    results: list[PhraseResultOut] = []
    for item in payload.results:
        phrase = db.get(Phrase, item.phrase_id)
        if phrase is None:
            # Its words left the deck, or it was written for another language
            # pair and cleared out. Accepting nothing is the honest answer, and
            # tells the app to stop retrying it.
            results.append(
                PhraseResultOut(
                    client_result_id=item.client_result_id,
                    phrase_id=item.phrase_id,
                    accepted=False,
                )
            )
            continue

        if item.client_result_id in seen:
            results.append(
                PhraseResultOut(
                    client_result_id=item.client_result_id,
                    phrase_id=phrase.id,
                    accepted=True,
                    duplicate=True,
                    mastered=phrase.mastered_at is not None,
                    retry_after=phrase.retry_after,
                )
            )
            continue

        answered_at = item.answered_at or utcnow()
        pool_module.record_result(db, phrase, item.correct, answered_at=answered_at)
        db.add(
            PhraseAttempt(
                phrase_id=phrase.id,
                correct=item.correct,
                answered_at=answered_at,
                client_result_id=item.client_result_id,
            )
        )
        seen.add(item.client_result_id)
        results.append(
            PhraseResultOut(
                client_result_id=item.client_result_id,
                phrase_id=phrase.id,
                accepted=True,
                mastered=phrase.mastered_at is not None,
                retry_after=phrase.retry_after,
            )
        )

    db.commit()
    # Mastered sentences have left the pool for good, so this is where it
    # actually gets shorter -- and where the writer is most worth waking.
    get_pool().request_top_up()
    return PhraseResultBatchResult(results=results)
