from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_profile, require_user
from app.enrichment import get_service
from app.models import EnrichmentStatus, Profile, Word, deck_key, normalise_lemma
from app.scheduler import new_cards_for_word
from app.schemas import (
    ProfileOut,
    ProfileUpdate,
    WordBatchCreate,
    WordBatchResult,
    WordCreate,
    WordOut,
    WordUpdate,
)

router = APIRouter(tags=["deck"], dependencies=[Depends(require_user)])


# --------------------------------------------------------------------------- #
# Profile
# --------------------------------------------------------------------------- #
@router.get("/profile", response_model=ProfileOut)
def read_profile(profile: Profile = Depends(get_profile)):
    return profile


@router.patch("/profile", response_model=ProfileOut)
def update_profile(
    payload: ProfileUpdate,
    db: Session = Depends(get_db),
    profile: Profile = Depends(get_profile),
):
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(profile, field, value)
    db.add(profile)
    db.commit()
    db.refresh(profile)
    return profile


# --------------------------------------------------------------------------- #
# Words
# --------------------------------------------------------------------------- #
@router.get("/words", response_model=list[WordOut])
def list_words(
    db: Session = Depends(get_db),
    q: str | None = Query(default=None, description="Substring match on lemma or gloss"),
    limit: int = Query(default=200, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(Word).order_by(Word.created_at.desc()).limit(limit).offset(offset)
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(Word.lemma.ilike(like) | Word.native_gloss.ilike(like))
    return list(db.scalars(stmt))


@router.post("/words", response_model=WordOut, status_code=status.HTTP_201_CREATED)
def create_word(payload: WordCreate, db: Session = Depends(get_db)):
    lemma = normalise_lemma(payload.lemma)
    if db.scalar(select(Word).where(Word.lemma_key == deck_key(lemma))):
        raise HTTPException(status.HTTP_409_CONFLICT, f"'{lemma}' is already in the deck")

    word = Word(
        lemma=lemma,
        native_gloss=payload.native_gloss.strip(),
        notes=payload.notes,
        source=payload.source,
        enrichment_status=EnrichmentStatus.pending,
    )
    db.add(word)
    db.flush()
    for card in new_cards_for_word(word.id):
        db.add(card)
    db.commit()
    db.refresh(word)
    get_service().enqueue([word.id])
    return word


@router.post("/words/batch", response_model=WordBatchResult, status_code=status.HTTP_201_CREATED)
def create_words_batch(payload: WordBatchCreate, db: Session = Depends(get_db)):
    """Bulk add, skipping duplicates rather than failing the whole batch.

    OCR import posts here: one mistyped duplicate in a 200-word screenshot
    import should not throw away the other 199.

    A batch that repeats a word itself collapses to one entry, silently: the
    learner is told about words the deck already had, which is news, not about
    a word they listed twice, which is not.
    """
    incoming: dict[str, WordCreate] = {}
    for spec in payload.words:
        # First spelling wins, so the batch reads back the way it was sent.
        incoming.setdefault(deck_key(spec.lemma), spec)

    existing = set(
        db.scalars(select(Word.lemma_key).where(Word.lemma_key.in_(list(incoming)))).all()
    )

    created: list[Word] = []
    for key, spec in incoming.items():
        if key in existing:
            continue
        word = Word(
            lemma=normalise_lemma(spec.lemma),
            native_gloss=spec.native_gloss.strip(),
            notes=spec.notes,
            source=spec.source,
            enrichment_status=EnrichmentStatus.pending,
        )
        db.add(word)
        db.flush()
        for card in new_cards_for_word(word.id):
            db.add(card)
        created.append(word)

    db.commit()
    for word in created:
        db.refresh(word)
    get_service().enqueue([w.id for w in created])

    # Reported as they were sent, not as they are keyed: "Perro" is what the
    # learner typed and what they need to find in the list.
    duplicates = sorted(normalise_lemma(incoming[key].lemma) for key in existing)
    return WordBatchResult(created=created, duplicates=duplicates)


@router.get("/words/{word_id}", response_model=WordOut)
def read_word(word_id: str, db: Session = Depends(get_db)):
    word = db.get(Word, word_id)
    if word is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such word")
    return word


@router.patch("/words/{word_id}", response_model=WordOut)
def update_word(word_id: str, payload: WordUpdate, db: Session = Depends(get_db)):
    word = db.get(Word, word_id)
    if word is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such word")

    data = payload.model_dump(exclude_unset=True)
    if "lemma" in data and data["lemma"]:
        data["lemma"] = normalise_lemma(data["lemma"])
        # Not `!= word.lemma`: a word may be recased into itself, which is a
        # rename the deck has no reason to refuse.
        clash = db.scalar(
            select(Word).where(Word.lemma_key == deck_key(data["lemma"]), Word.id != word_id)
        )
        if clash:
            raise HTTPException(status.HTTP_409_CONFLICT, f"'{data['lemma']}' is already in the deck")
        # The lemma changed, so any generated sentences describe the old word.
        word.enrichment_status = EnrichmentStatus.pending

    for field, value in data.items():
        setattr(word, field, value)
    db.add(word)
    db.commit()
    db.refresh(word)
    return word


@router.delete("/words/{word_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_word(word_id: str, db: Session = Depends(get_db)):
    word = db.get(Word, word_id)
    if word is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such word")
    db.delete(word)
    db.commit()
