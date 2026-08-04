"""Background enrichment queue.

Each generation forks a `claude` CLI subprocess, so this is deliberately a
small worker pool behind a queue rather than a task per word -- importing 200
words from a screenshot must not fork 200 processes.
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.deps import ensure_profile
from app.llm.agent_sdk import AgentSDKGenerator
from app.llm.base import ContentGenerationError, ContentGenerator
from app.models import Card, Enrichment, EnrichmentStatus, Word, utcnow

log = logging.getLogger("memorium.enrichment")

ENRICHMENT_SCHEMA_VERSION = 1
KNOWN_WORDS_SAMPLE = 40


def _blank_to_none(value: str | None) -> str | None:
    """The schema spells 'not applicable' as "" so every field can be required."""
    value = (value or "").strip()
    return value or None


def _known_words(db, exclude_word_id: str) -> list[str]:
    """Vocabulary to build i+1 sentences from.

    Prefer words actually reviewed at least once -- 'known' should mean the
    learner has seen it, not that it sits unstudied in the deck.
    """
    reviewed = list(
        db.scalars(
            select(Word.lemma)
            .join(Card, Card.word_id == Word.id)
            .where(Word.id != exclude_word_id, Card.reps > 0)
            .group_by(Word.id)
            .order_by(Card.stability.desc().nullslast())
            .limit(KNOWN_WORDS_SAMPLE)
        )
    )
    if reviewed:
        return reviewed
    return list(
        db.scalars(
            select(Word.lemma).where(Word.id != exclude_word_id).limit(KNOWN_WORDS_SAMPLE)
        )
    )


class EnrichmentService:
    def __init__(self, generator: ContentGenerator | None = None, workers: int | None = None):
        settings = get_settings()
        self.generator: ContentGenerator = generator or AgentSDKGenerator(
            model=settings.claude_model,
            timeout_seconds=settings.claude_timeout_seconds,
            task_models=settings.task_models,
        )
        self.worker_count = workers if workers is not None else settings.enrichment_workers
        self._queue: asyncio.Queue[str] = asyncio.Queue()
        self._tasks: list[asyncio.Task] = []
        self._loop: asyncio.AbstractEventLoop | None = None

    # ------------------------------------------------------------------ #
    async def start(self) -> None:
        # Captured so `enqueue` can hand work across the thread boundary --
        # see the note there.
        self._loop = asyncio.get_running_loop()
        self._recover()
        self._tasks = [
            asyncio.create_task(self._worker(i), name=f"enrich-{i}")
            for i in range(self.worker_count)
        ]

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
        self._tasks.clear()

    def _recover(self) -> None:
        """Re-queue anything left mid-flight by a restart.

        A word stuck in `running` because the process died would otherwise
        never be picked up again.
        """
        with SessionLocal() as db:
            stranded = list(
                db.scalars(
                    select(Word).where(
                        Word.enrichment_status.in_(
                            [
                                EnrichmentStatus.pending,
                                EnrichmentStatus.queued,
                                EnrichmentStatus.running,
                            ]
                        )
                    )
                )
            )
            for word in stranded:
                word.enrichment_status = EnrichmentStatus.queued
                db.add(word)
            db.commit()
            for word in stranded:
                self._submit(word.id)
            if stranded:
                log.info("re-queued %d words for enrichment after restart", len(stranded))

    # ------------------------------------------------------------------ #
    def enqueue(self, word_ids: list[str]) -> int:
        queued = 0
        with SessionLocal() as db:
            for word_id in word_ids:
                word = db.get(Word, word_id)
                if word is None or word.enrichment_status is EnrichmentStatus.running:
                    continue
                word.enrichment_status = EnrichmentStatus.queued
                db.add(word)
                queued += 1
            db.commit()
        for word_id in word_ids:
            self._submit(word_id)
        return queued

    def _submit(self, word_id: str) -> None:
        """Hand a word to the workers.

        `enqueue` is called from FastAPI's threadpool (the routes are sync),
        but asyncio.Queue is NOT thread-safe: `put_nowait` from another thread
        appends the item yet never wakes a worker parked in `get()`. The result
        is silent -- words sit queued forever with no error anywhere. Bounce
        the put onto the loop thread instead.
        """
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(self._queue.put_nowait, word_id)
        else:
            # No loop running yet (startup recovery, or tests with workers=0).
            self._queue.put_nowait(word_id)

    @property
    def depth(self) -> int:
        return self._queue.qsize()

    # ------------------------------------------------------------------ #
    async def _worker(self, index: int) -> None:
        while True:
            word_id = await self._queue.get()
            try:
                await self._process(word_id)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - a worker must never die
                log.exception("enrichment worker %d crashed on word %s", index, word_id)
            finally:
                self._queue.task_done()

    async def _process(self, word_id: str) -> None:
        with SessionLocal() as db:
            word = db.get(Word, word_id)
            if word is None:
                return
            # Create it if absent rather than bailing: a worker that returns
            # early here would leave the word queued forever with nothing to
            # re-trigger it.
            profile = ensure_profile(db)

            lemma, gloss = word.lemma, word.native_gloss
            source_lang, target_lang = profile.source_lang, profile.target_lang
            known = _known_words(db, word_id)

            word.enrichment_status = EnrichmentStatus.running
            db.add(word)
            db.commit()

        try:
            result = await self.generator.enrich_word(
                lemma=lemma,
                native_gloss=gloss,
                source_lang=source_lang,
                target_lang=target_lang,
                known_words=known,
            )
        except ContentGenerationError as exc:
            log.warning("enrichment failed for %s: %s", lemma, exc)
            self._record_failure(word_id, str(exc))
            return

        with SessionLocal() as db:
            word = db.get(Word, word_id)
            if word is None:  # deleted while we were generating
                return

            # The learner's own edits to the lemma win; we only fill blanks.
            word.pos = _blank_to_none(result.pos)
            word.gender = _blank_to_none(result.gender)
            word.article = _blank_to_none(result.article)
            word.plural_form = _blank_to_none(result.plural_form)
            if not word.notes:
                word.notes = _blank_to_none(result.notes)

            payload = {
                "sentences": [s.model_dump() for s in result.sentences],
                "suggested_gloss": result.native_gloss,
            }
            enrichment = db.get(Enrichment, word_id)
            if enrichment is None:
                enrichment = Enrichment(word_id=word_id)
            enrichment.schema_version = ENRICHMENT_SCHEMA_VERSION
            enrichment.payload = payload
            enrichment.generated_at = utcnow()
            enrichment.error = None

            word.enrichment_status = EnrichmentStatus.done
            db.add_all([word, enrichment])
            db.commit()
            log.info("enriched %s with %d sentences", lemma, len(result.sentences))

    def _record_failure(self, word_id: str, error: str) -> None:
        with SessionLocal() as db:
            word = db.get(Word, word_id)
            if word is None:
                return
            word.enrichment_status = EnrichmentStatus.failed
            enrichment = db.get(Enrichment, word_id)
            if enrichment is None:
                # Record the failure without inventing content. A partially
                # written enrichment is worse than none: it would silently
                # unlock a cloze card with no sentence in it.
                enrichment = Enrichment(word_id=word_id, payload={"sentences": []})
            enrichment.error = error[:1000]
            enrichment.generated_at = utcnow()
            db.add_all([word, enrichment])
            db.commit()


_service: EnrichmentService | None = None


def get_service() -> EnrichmentService:
    global _service
    if _service is None:
        _service = EnrichmentService()
    return _service


def set_service(service: EnrichmentService | None) -> None:
    """Test seam: swap in a fake generator without touching the routers."""
    global _service
    _service = service
