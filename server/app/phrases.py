"""The stored pool of practice sentences, and the writer that keeps it full.

Writing a set of sentences takes a minute or two. Nobody opens a practice
screen to watch that happen, so it does not happen then: a fixed number of
unanswered sentences is kept in store, written in the background, and a session
is served out of what is already there. Practising drains the pool and wakes
the writer, which tops it back up while the learner is still answering.

Two rules shape what is in the pool.

*Everything gets its turn.* The vocabulary a batch is built from is chosen by
rotation -- the deck words that have turned up in the fewest sentences so far
come first -- with the rest of the sample drawn at random, so the same words
keep meeting different neighbours instead of the writer circling the handful it
finds easiest to use. Over enough batches every word in the deck is practised,
and practised in company.

*A sentence stays until it is answered right.* Getting one wrong is not a
reason to throw it away; it is the reason to ask again later. Only a correct
answer takes a sentence out of circulation.
"""

from __future__ import annotations

import asyncio
import logging
import random
from collections import Counter
from datetime import timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import SessionLocal
from app.deps import ensure_profile
from app.enrichment import get_service
from app.llm.base import ContentGenerationError, GeneratedPhrase
from app.models import Card, Phrase, Profile, Word, deck_key, utcnow

log = logging.getLogger("memorium.phrases")

# Below this there is nothing to build a sentence out of, and the honest answer
# is to say so rather than to hand back four sentences about a dog.
MIN_KNOWN_WORDS = 5

# How much vocabulary to put in front of the generator. Enough to write varied
# sentences; not so much that the prompt is mostly word list.
VOCABULARY_SAMPLE = 60

# Words the batch is built around -- the ones the rotation has reached.
FOCUS_WORDS = 8

# Sentences are written a batch at a time, not a session at a time. Writing
# twelve costs about what writing six does.
BATCH_SIZE = 12


# --------------------------------------------------------------------------- #
# What counts as vocabulary
# --------------------------------------------------------------------------- #
def learned_lemmas(db: Session) -> tuple[list[str], list[str]]:
    """The deck, split into what has been reviewed and what has not.

    "Known" should mean the learner has met the word, not that it sits
    unstudied in the deck. But a deck built by importing a word list is a deck
    of words met somewhere else, so the unreviewed half is kept rather than
    discarded -- it is what a fresh import has to practise with.
    """
    reviewed = list(
        db.scalars(
            select(Word.lemma)
            .join(Card, Card.word_id == Word.id)
            .where(Card.reps > 0)
            .group_by(Word.id)
            .order_by(func.max(Card.stability).desc().nullslast())
        )
    )
    unreviewed = list(
        db.scalars(
            select(Word.lemma)
            .where(Word.lemma.notin_(reviewed))
            .order_by(Word.created_at.asc())
        )
    )
    return reviewed, unreviewed


def known_lemmas(db: Session) -> list[str]:
    """Every word a sentence could be built from, best-known first."""
    reviewed, unreviewed = learned_lemmas(db)
    return reviewed + unreviewed


def phrase_coverage(db: Session, profile: Profile) -> Counter[str]:
    """How many stored sentences each deck word has turned up in.

    Counted over every phrase for the pair, mastered ones included: a word is
    practised whether or not the sentence it was in has been retired, and
    forgetting that would send the rotation back over the same words.
    """
    counts: Counter[str] = Counter()
    for lemmas in db.scalars(
        select(Phrase.lemmas).where(
            Phrase.target_lang == profile.target_lang,
            Phrase.source_lang == profile.source_lang,
        )
    ):
        # Per phrase, not per mention: a sentence using a word twice has still
        # only practised it once.
        for key in {deck_key(str(lemma)) for lemma in (lemmas or [])}:
            counts[key] += 1
    return counts


def vocabulary_for_batch(
    db: Session, profile: Profile, *, rng: random.Random | None = None
) -> tuple[list[str], list[str]]:
    """The words the next batch may use, and the ones it is built around.

    Returns `(known, focus)`. `focus` is the least-covered end of the rotation,
    shuffled among equals so a tie is not always broken the same way. `known`
    is the focus plus a random draw from the rest of the deck: the focus words
    have to be usable *with* something, and offering them the same neighbours
    every time writes the same sentences with different subjects.
    """
    picker = rng or random
    reviewed, unreviewed = learned_lemmas(db)
    deck = reviewed + unreviewed
    if len(deck) < MIN_KNOWN_WORDS:
        return [], []

    # Rotate over the words actually met. A deck that has just been imported
    # has met none of them, and rotating over the import is a great deal better
    # than refusing to practise.
    rotation = reviewed if len(reviewed) >= MIN_KNOWN_WORDS else deck
    coverage = phrase_coverage(db, profile)
    ranked = sorted(rotation, key=lambda lemma: (coverage[deck_key(lemma)], picker.random()))

    focus = ranked[:FOCUS_WORDS]
    chosen = set(focus)
    rest = [lemma for lemma in deck if lemma not in chosen]
    room = max(VOCABULARY_SAMPLE - len(focus), 0)
    return focus + picker.sample(rest, min(room, len(rest))), focus


# --------------------------------------------------------------------------- #
# The stored pool
# --------------------------------------------------------------------------- #
def _in_deck(lemmas, deck: set[str]) -> bool:
    """Has this sentence outlived the words it was made of?

    One surviving word is enough. Requiring all of them would retire good
    sentences over a single deleted word, and a phrase that records none of
    its vocabulary -- the generator declined to say -- is kept rather than
    quietly thrown away.
    """
    written = [str(lemma) for lemma in (lemmas or [])]
    return not written or any(deck_key(lemma) in deck for lemma in written)


def _still_in_deck(phrase: Phrase, deck: set[str]) -> bool:
    return _in_deck(phrase.lemmas, deck)


def available(
    db: Session,
    profile: Profile,
    limit: int,
    *,
    unseen_only: bool = False,
    ignore_cooldown: bool = False,
    include_mastered: bool = False,
    exclude: set[str] | None = None,
) -> list[Phrase]:
    """Stored sentences to practise, in the order they should be asked.

    Unfinished business first: a sentence that has been put in front of the
    learner and not answered comes back before anything new does, so a set
    opened and abandoned is waiting where it was left instead of being buried
    under fresh material. Then sentences never served at all, and last the ones
    answered wrong, which have already had their turn and are waiting out the
    cooling-off period. Mastered sentences are out of it altogether unless
    there is nothing else left.
    """
    if limit <= 0:
        return []
    query = select(Phrase).where(
        Phrase.target_lang == profile.target_lang,
        Phrase.source_lang == profile.source_lang,
    )
    if not include_mastered:
        query = query.where(Phrase.mastered_at.is_(None))
    if not ignore_cooldown:
        query = query.where(
            (Phrase.retry_after.is_(None)) | (Phrase.retry_after <= utcnow())
        )
    if unseen_only:
        query = query.where(Phrase.last_served_at.is_(None))
    if exclude:
        query = query.where(Phrase.id.notin_(exclude))

    # Over-fetch, because some of what comes back may have outlived its words.
    candidates = list(
        db.scalars(
            query.order_by(
                Phrase.attempts.asc(),
                # Nulls *last*: a sentence already shown and not answered is
                # the one still owed, and a never-served one can wait.
                Phrase.last_served_at.asc().nullslast(),
                Phrase.created_at.asc(),
            ).limit(limit * 3)
        )
    )
    deck = set(db.scalars(select(Word.lemma_key)))
    return [phrase for phrase in candidates if _still_in_deck(phrase, deck)][:limit]


def depth(db: Session, profile: Profile) -> int:
    """How many sentences are waiting to be answered correctly.

    What the writer tops up, and what a session draws down. Counted the same
    way `available` selects, deck check included: a pool that is mostly
    sentences about deleted words is a pool that needs filling, and a plain
    `COUNT(*)` would report it full while sessions came back short.
    """
    deck = set(db.scalars(select(Word.lemma_key)))
    return sum(
        1
        for lemmas in db.scalars(
            select(Phrase.lemmas).where(
                Phrase.target_lang == profile.target_lang,
                Phrase.source_lang == profile.source_lang,
                Phrase.mastered_at.is_(None),
            )
        )
        if _in_deck(lemmas, deck)
    )


def mark_served(db: Session, phrases: list[Phrase]) -> None:
    now = utcnow()
    for phrase in phrases:
        phrase.served_count += 1
        phrase.last_served_at = now
    db.add_all(phrases)
    db.commit()


def record_result(db: Session, phrase: Phrase, correct: bool, answered_at=None) -> Phrase:
    """Apply one answer to one sentence.

    Right once and it is done: `mastered_at` takes it out of the rotation.
    Wrong and it stays exactly where it was, minus a cooling-off period, so it
    comes back around rather than being retired unanswered.
    """
    now = answered_at or utcnow()
    phrase.attempts += 1
    if correct:
        phrase.mastered_at = phrase.mastered_at or now
        phrase.retry_after = None
    else:
        phrase.lapses += 1
        phrase.retry_after = now + timedelta(hours=get_settings().phrase_retry_hours)
    db.add(phrase)
    return phrase


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #
def store(db: Session, profile: Profile, written: list[GeneratedPhrase]) -> list[Phrase]:
    """Keep the usable half of what came back.

    A sentence already in the pool is not practice, it is the same card again.
    Checked case-insensitively and against this batch as well as the store,
    since a generator asked twice in a day repeats itself.
    """
    seen = {
        target.casefold()
        for target in db.scalars(
            select(Phrase.target).where(Phrase.target_lang == profile.target_lang)
        )
    }
    fresh: list[Phrase] = []
    for phrase in written:
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


async def generate(
    db: Session,
    profile: Profile,
    count: int,
    *,
    rng: random.Random | None = None,
) -> list[Phrase]:
    """Write `count` new sentences and keep them.

    Raises `ContentGenerationError`, which every caller treats as "serve what
    is already stored" rather than as a failed session.
    """
    known, focus = vocabulary_for_batch(db, profile, rng=rng)
    if not known:
        return []
    result = await get_service().generator.practice_phrases(
        count=count,
        known_words=known,
        focus_words=focus,
        source_lang=profile.source_lang,
        target_lang=profile.target_lang,
    )
    return store(db, profile, result.phrases)


# --------------------------------------------------------------------------- #
# The background writer
# --------------------------------------------------------------------------- #
class PhrasePool:
    """Keeps `phrase_pool_size` unanswered sentences in store, ahead of use.

    Runs on a slow tick and on demand: serving a session wakes it, so the batch
    that replaces what was just practised is written while the learner is still
    answering rather than the next time they open the screen.

    One writer, and one lock shared with the on-demand path. Each generation
    forks a `claude` CLI subprocess, and two of them racing would write the
    same sentences twice as well as costing twice as much.
    """

    def __init__(
        self,
        *,
        target: int | None = None,
        interval: float | None = None,
        enabled: bool | None = None,
    ):
        settings = get_settings()
        self.target = target if target is not None else settings.phrase_pool_size
        self.interval = (
            interval if interval is not None else settings.phrase_pool_interval_seconds
        )
        self.enabled = enabled if enabled is not None else settings.phrase_pool_enabled
        self.last_error: str | None = None
        self._lock = asyncio.Lock()
        self._wake = asyncio.Event()
        self._task: asyncio.Task | None = None
        self._loop: asyncio.AbstractEventLoop | None = None

    # ------------------------------------------------------------------ #
    async def start(self) -> None:
        # Captured so `request_top_up` can wake the writer from FastAPI's
        # threadpool -- see the note there.
        self._loop = asyncio.get_running_loop()
        if not self.enabled:
            return
        self._task = asyncio.create_task(self._run(), name="phrase-pool")

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass
        self._task = None

    def request_top_up(self) -> None:
        """Write the next batch now rather than at the next tick.

        `asyncio.Event` is not thread-safe and the routes that call this are
        served from FastAPI's threadpool: setting it from there can leave the
        writer parked with the flag set, which looks exactly like a pool that
        silently stopped filling. Bounce it onto the loop thread instead.
        """
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(self._wake.set)
        else:
            self._wake.set()

    async def _run(self) -> None:
        while True:
            self._wake.clear()
            try:
                await self.top_up()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - the writer must never die
                log.exception("phrase pool top-up crashed")
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=self.interval)
            except TimeoutError:
                pass

    # ------------------------------------------------------------------ #
    async def top_up(self) -> int:
        """Fill the pool back to `target`. Returns how many were written.

        A batch at a time, checking the pool between them: the deck can change
        while this is running, and a learner deleting half of it mid-batch
        should not be handed sentences about the words they just removed.
        """
        written = 0
        while True:
            with SessionLocal() as db:
                profile = ensure_profile(db)
                deficit = self.target - depth(db, profile)
                if deficit <= 0:
                    return written
                if len(known_lemmas(db)) < MIN_KNOWN_WORDS:
                    return written  # Nothing to build sentences out of yet.
                try:
                    async with self._lock:
                        batch = await generate(db, profile, min(deficit, BATCH_SIZE))
                except ContentGenerationError as exc:
                    # Nothing to escalate: the pool is a buffer, and a session
                    # served from what is already in it is a normal session.
                    self.last_error = str(exc)
                    log.warning("phrase pool top-up failed: %s", exc)
                    return written
            if not batch:
                # The generator returned nothing usable. Trying again straight
                # away would spin on it, so leave it for the next tick.
                return written
            self.last_error = None
            written += len(batch)
            log.info("wrote %d phrases (%d this cycle)", len(batch), written)

    async def write_now(self, db: Session, profile: Profile, count: int) -> list[Phrase]:
        """Write a batch for a caller with nothing to serve.

        Takes the same lock as the background writer, so an empty pool being
        filled on demand and the writer's own tick cannot run at once.
        """
        async with self._lock:
            return await generate(db, profile, count)


_pool: PhrasePool | None = None


def get_pool() -> PhrasePool:
    global _pool
    if _pool is None:
        _pool = PhrasePool()
    return _pool


def set_pool(pool: PhrasePool | None) -> None:
    """Test seam: a pool with a known target, or none at all."""
    global _pool
    _pool = pool


__all__ = [
    "BATCH_SIZE",
    "MIN_KNOWN_WORDS",
    "PhrasePool",
    "available",
    "depth",
    "generate",
    "get_pool",
    "known_lemmas",
    "mark_served",
    "record_result",
    "set_pool",
    "vocabulary_for_batch",
]
