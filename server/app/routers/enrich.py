from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_profile, require_user
from app.enrichment import get_service
from app.llm.base import ContentGenerationError
from app.models import Card, Enrichment, EnrichmentStatus, Profile, Word, utcnow

router = APIRouter(tags=["content"], dependencies=[Depends(require_user)])


class EnrichRequest(BaseModel):
    word_ids: list[str] | None = None
    all_pending: bool = False
    # Failures only, for the app's "retry" button. Separate from `all_pending`
    # so the button re-runs exactly the words it counted -- sweeping up pending
    # ones as well would report a number the learner never saw.
    all_failed: bool = False


class EnrichStatus(BaseModel):
    queue_depth: int
    pending: int
    running: int
    done: int
    failed: int


class GradeAnswerRequest(BaseModel):
    prompt: str
    expected: str
    given: str


class GradeAnswerResponse(BaseModel):
    verdict: str
    reason: str


class TranslateRequest(BaseModel):
    text: Annotated[str, Field(min_length=1, max_length=400)]
    # Which side of the card is missing: "target" when the learner typed the
    # gloss and wants the foreign word, "source" the other way round.
    into: Literal["source", "target"]


class TranslateResponse(BaseModel):
    translation: str
    into: str


class TranslateBatchRequest(BaseModel):
    # Bounded like WordBatchCreate, and for the same reason: a screenshot import
    # is the caller, and it is capped at the same size.
    texts: Annotated[
        list[Annotated[str, Field(min_length=1, max_length=400)]],
        Field(min_length=1, max_length=500),
    ]
    into: Literal["source", "target"]


class TranslateBatchResponse(BaseModel):
    # Aligned with the request by position. A word Claude could not translate
    # comes back as null rather than being dropped, so the caller can still tell
    # which word it was.
    translations: list[str | None]
    into: str


class StoryResponse(BaseModel):
    title: str
    target: str
    native: str
    lemmas: list[str]


@router.post("/enrich", response_model=EnrichStatus)
def enrich(payload: EnrichRequest, db: Session = Depends(get_db)):
    service = get_service()
    if payload.all_pending or payload.all_failed:
        wanted = [EnrichmentStatus.failed]
        if payload.all_pending:
            wanted.append(EnrichmentStatus.pending)
        ids = list(
            db.scalars(select(Word.id).where(Word.enrichment_status.in_(wanted)))
        )
    else:
        ids = payload.word_ids or []
    service.enqueue(ids)
    return _status(db, service.depth)


@router.get("/enrich/status", response_model=EnrichStatus)
def enrich_status(db: Session = Depends(get_db)):
    return _status(db, get_service().depth)


def _status(db: Session, depth: int) -> EnrichStatus:
    counts = dict(
        db.execute(
            select(Word.enrichment_status, func.count()).group_by(Word.enrichment_status)
        ).all()
    )
    return EnrichStatus(
        queue_depth=depth,
        pending=counts.get(EnrichmentStatus.pending, 0) + counts.get(EnrichmentStatus.queued, 0),
        running=counts.get(EnrichmentStatus.running, 0),
        done=counts.get(EnrichmentStatus.done, 0),
        failed=counts.get(EnrichmentStatus.failed, 0),
    )


@router.post("/grade", response_model=GradeAnswerResponse)
async def grade_answer(
    payload: GradeAnswerRequest,
    profile: Profile = Depends(get_profile),
):
    """Fallback answer grading.

    The app tries a normalised string match first, then its on-device model.
    This is only reached when neither could decide, or the phone has no
    Apple Intelligence.
    """
    try:
        judgement = await get_service().generator.grade_answer(
            prompt=payload.prompt,
            expected=payload.expected,
            given=payload.given,
            source_lang=profile.source_lang,
            target_lang=profile.target_lang,
        )
    except ContentGenerationError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc
    return GradeAnswerResponse(verdict=judgement.verdict, reason=judgement.reason)


@router.post("/translate", response_model=TranslateResponse)
async def translate(
    payload: TranslateRequest,
    profile: Profile = Depends(get_profile),
):
    """Fill in the other side of a card being added.

    Typing both halves of every word is the friction that stops a deck growing,
    so the app offers this from whichever field the learner filled in first.
    """
    try:
        result = await get_service().generator.translate(
            text=payload.text.strip(),
            into=payload.into,
            source_lang=profile.source_lang,
            target_lang=profile.target_lang,
        )
    except ContentGenerationError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc

    translation = result.translation.strip()
    if not translation:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, "Claude returned an empty translation"
        )
    return TranslateResponse(translation=translation, into=payload.into)


@router.post("/translate/batch", response_model=TranslateBatchResponse)
async def translate_batch(
    payload: TranslateBatchRequest,
    profile: Profile = Depends(get_profile),
):
    """Fill in the missing side of many cards at once.

    Importing a word list is the case this exists for. Duolingo shows a
    translation under only about half the words it lists, so a hundred-word
    import arrives with dozens of blanks -- one request each would be a hundred
    round trips before the learner sees their deck.
    """
    texts = [text.strip() for text in payload.texts]
    try:
        result = await get_service().generator.translate_batch(
            texts=texts,
            into=payload.into,
            source_lang=profile.source_lang,
            target_lang=profile.target_lang,
        )
    except ContentGenerationError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc

    # An empty slot is a word Claude declined, not a failure of the batch: the
    # other ninety-nine words are still worth having, and the caller shows the
    # blank one for the learner to fill in.
    return TranslateBatchResponse(
        translations=[text.strip() or None for text in result.translations],
        into=payload.into,
    )


@router.post("/words/{word_id}/mnemonic")
async def make_mnemonic(
    word_id: str,
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
):
    """Rescue a leech: a word failed repeatedly gets a memory hook.

    Grinding the same failing card is what makes people quit; a different angle
    is the intervention.
    """
    word = db.get(Word, word_id)
    if word is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such word")

    try:
        result = await get_service().generator.mnemonic(
            lemma=word.lemma,
            native_gloss=word.native_gloss,
            source_lang=profile.source_lang,
            target_lang=profile.target_lang,
        )
    except ContentGenerationError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc

    enrichment = db.get(Enrichment, word_id)
    if enrichment is None:
        enrichment = Enrichment(word_id=word_id, payload={"sentences": []})
    enrichment.mnemonic = result.mnemonic
    enrichment.generated_at = utcnow()
    db.add(enrichment)
    db.commit()
    return {"word_id": word_id, "mnemonic": result.mnemonic}


_story_cache: dict[tuple[date, str], StoryResponse] = {}


@router.get("/story", response_model=StoryResponse)
async def daily_story(
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
):
    """A short story built from today's due words.

    Reading your own vocabulary in connected prose is where recall starts
    turning into fluency.
    """
    now = utcnow()
    lemmas = list(
        db.scalars(
            select(Word.lemma)
            .join(Card, Card.word_id == Word.id)
            .where(Card.due <= now, Card.reps > 0)
            .group_by(Word.id)
            .order_by(Card.due.asc())
            .limit(8)
        )
    )
    if not lemmas:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND, "Nothing is due today, so there is no story to tell."
        )

    key = (now.date(), "|".join(sorted(lemmas)))
    if key in _story_cache:
        return _story_cache[key]

    try:
        story = await get_service().generator.daily_story(
            lemmas=lemmas,
            source_lang=profile.source_lang,
            target_lang=profile.target_lang,
        )
    except ContentGenerationError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc

    response = StoryResponse(
        title=story.title, target=story.target, native=story.native, lemmas=lemmas
    )
    _story_cache.clear()  # only today's story is ever worth keeping
    _story_cache[key] = response
    return response
