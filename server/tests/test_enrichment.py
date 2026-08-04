"""Enrichment pipeline behaviour, with a fake generator (no network, no cost)."""

import asyncio

import pytest

from app.enrichment import EnrichmentService, set_service
from app.llm.base import (
    AnswerJudgement,
    BatchTranslationOut,
    ContentGenerationError,
    GeneratedSentence,
    MnemonicOut,
    StoryOut,
    TranslationOut,
    WordEnrichment,
)
from app.models import Enrichment, EnrichmentStatus, Profile, Word


class FakeGenerator:
    """Stands in for Claude. `fail_with` makes it misbehave on demand."""

    def __init__(
        self,
        fail_with: Exception | None = None,
        sentences=None,
        translation=None,
        declines: set[str] | None = None,
    ):
        self.fail_with = fail_with
        self.calls: list[dict] = []
        self.translation = translation
        # Words this fake refuses, to stand for the ones Claude comes back
        # empty on.
        self.declines = declines or set()
        self._sentences = (
            sentences
            if sentences is not None
            else [
                GeneratedSentence(
                    target="Mi perro corre.", native="My dog runs.", cloze_word="perro"
                )
            ]
        )

    async def enrich_word(self, lemma, native_gloss, source_lang, target_lang, known_words):
        self.calls.append({"lemma": lemma, "known_words": known_words})
        if self.fail_with:
            raise self.fail_with
        return WordEnrichment(
            lemma=lemma,
            pos="noun",
            gender="masculine",
            article="el",
            plural_form="perros",
            native_gloss=native_gloss,
            notes="",
            sentences=self._sentences,
        )

    async def grade_answer(self, prompt, expected, given, source_lang, target_lang):
        if self.fail_with:
            raise self.fail_with
        correct = given.strip().lower() == expected.strip().lower()
        return AnswerJudgement(
            verdict="correct" if correct else "wrong", reason="because" if not correct else "ok"
        )

    async def mnemonic(self, lemma, native_gloss, source_lang, target_lang):
        if self.fail_with:
            raise self.fail_with
        return MnemonicOut(mnemonic=f"hook for {lemma}")

    async def daily_story(self, lemmas, source_lang, target_lang):
        if self.fail_with:
            raise self.fail_with
        return StoryOut(title="t", target=" ".join(lemmas), native="n")

    async def translate(self, text, into, source_lang, target_lang):
        self.calls.append({"translate": text, "into": into})
        if self.fail_with:
            raise self.fail_with
        return TranslationOut(translation=self.translation or f"{text}-in-{into}")

    async def translate_batch(self, texts, into, source_lang, target_lang):
        self.calls.append({"translate_batch": list(texts), "into": into})
        if self.fail_with:
            raise self.fail_with
        # An empty input stands for a word the model declined, which the
        # endpoint turns into a null rather than dropping.
        return BatchTranslationOut(
            translations=[
                "" if text in self.declines else (self.translation or f"{text}-in-{into}")
                for text in texts
            ]
        )


@pytest.fixture
def fake():
    generator = FakeGenerator()
    set_service(EnrichmentService(generator=generator, workers=0))
    yield generator
    set_service(None)


def seed_profile(db):
    if db.get(Profile, 1) is None:
        db.add(
            Profile(
                id=1,
                source_lang="en-US",
                target_lang="es-ES",
                desired_retention=0.9,
                daily_new_limit=10,
                timezone="UTC",
            )
        )
        db.commit()


# --------------------------------------------------------------------------- #
def test_successful_enrichment_fills_grammar_and_sentences(client, db, fake):
    seed_profile(db)
    word = client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).json()

    asyncio.run(get_service_process(word["id"]))

    db.expire_all()
    stored = db.get(Word, word["id"])
    assert stored.enrichment_status is EnrichmentStatus.done
    assert stored.article == "el"
    assert stored.gender == "masculine"
    assert stored.plural_form == "perros"

    enrichment = db.get(Enrichment, word["id"])
    assert enrichment.payload["sentences"][0]["cloze_word"] == "perro"
    assert enrichment.error is None


def test_blank_fields_become_null_not_empty_strings(client, db):
    """The schema spells 'not applicable' as "" so fields can stay required;
    storing that literally would render as 'None perro' on a card."""
    generator = FakeGenerator()

    async def no_grammar(lemma, native_gloss, source_lang, target_lang, known_words):
        return WordEnrichment(
            lemma=lemma,
            pos="verb",
            gender="",
            article="",
            plural_form="",
            native_gloss=native_gloss,
            notes="",
            sentences=[],
        )

    generator.enrich_word = no_grammar
    set_service(EnrichmentService(generator=generator, workers=0))
    try:
        seed_profile(db)
        word = client.post("/words", json={"lemma": "correr", "native_gloss": "to run"}).json()
        asyncio.run(get_service_process(word["id"]))
        db.expire_all()
        stored = db.get(Word, word["id"])
        assert stored.article is None
        assert stored.gender is None
        assert stored.plural_form is None
    finally:
        set_service(None)


def test_failure_is_recorded_without_writing_partial_content(client, db):
    """A half-written enrichment is worse than none: it would unlock a cloze
    card with no sentence to blank out."""
    set_service(
        EnrichmentService(
            generator=FakeGenerator(fail_with=ContentGenerationError("auth expired")),
            workers=0,
        )
    )
    try:
        seed_profile(db)
        word = client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).json()
        asyncio.run(get_service_process(word["id"]))

        db.expire_all()
        stored = db.get(Word, word["id"])
        assert stored.enrichment_status is EnrichmentStatus.failed
        enrichment = db.get(Enrichment, word["id"])
        assert enrichment.payload["sentences"] == []
        assert "auth expired" in enrichment.error
        # Grammar fields untouched -- nothing invented.
        assert stored.article is None
    finally:
        set_service(None)


def test_status_endpoint_reports_failures(client, db):
    set_service(
        EnrichmentService(generator=FakeGenerator(fail_with=ContentGenerationError("nope")), workers=0)
    )
    try:
        seed_profile(db)
        word = client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).json()
        asyncio.run(get_service_process(word["id"]))
        status = client.get("/enrich/status").json()
        assert status["failed"] == 1
    finally:
        set_service(None)


def test_known_words_feed_the_i_plus_one_constraint(client, db, fake):
    """Sentences are only useful if built from words the learner already knows."""
    seed_profile(db)
    client.post("/words", json={"lemma": "casa", "native_gloss": "house"})
    target = client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).json()

    asyncio.run(get_service_process(target["id"]))

    call = next(c for c in fake.calls if c["lemma"] == "perro")
    assert "casa" in call["known_words"]
    assert "perro" not in call["known_words"]  # never seed a word with itself


def test_sentences_whose_cloze_word_is_absent_are_dropped(client, db):
    """A cloze_word that isn't a substring would leave the blank unfilled and
    show the answer on the card."""
    from app.llm.agent_sdk import AgentSDKGenerator

    good = GeneratedSentence(target="Mi perro corre.", native="My dog runs.", cloze_word="perro")
    bad = GeneratedSentence(target="Tengo un gato.", native="I have a cat.", cloze_word="perro")

    generator = AgentSDKGenerator(model="x")

    async def fake_generate(model_cls, system, user, task):
        assert task == "enrich"
        return WordEnrichment(
            lemma="perro",
            pos="noun",
            gender="masculine",
            article="el",
            plural_form="perros",
            native_gloss="dog",
            notes="",
            sentences=[good, bad],
        )

    generator._generate = fake_generate
    result = asyncio.run(
        generator.enrich_word("perro", "dog", "en-US", "es-ES", [])
    )
    assert [s.target for s in result.sentences] == ["Mi perro corre."]


def test_a_quoted_translation_is_unwrapped(db):
    """Models wrap bare answers in quotes; the quotes would land in the deck."""
    from app.llm.agent_sdk import AgentSDKGenerator

    generator = AgentSDKGenerator(model="x")

    async def fake_generate(model_cls, system, user, task):
        assert task == "translate"
        return TranslationOut(translation=' "el perro" ')

    generator._generate = fake_generate
    result = asyncio.run(generator.translate("dog", "target", "en-US", "es-ES"))
    assert result.translation == "el perro"


def test_grade_endpoint_uses_the_generator(client, db, fake):
    seed_profile(db)
    r = client.post(
        "/grade", json={"prompt": "the dog", "expected": "el perro", "given": "el perro"}
    )
    assert r.status_code == 200
    assert r.json()["verdict"] == "correct"


def test_grade_endpoint_reports_unavailable_when_claude_is_down(client, db):
    set_service(
        EnrichmentService(
            generator=FakeGenerator(fail_with=ContentGenerationError("token expired")), workers=0
        )
    )
    try:
        seed_profile(db)
        r = client.post("/grade", json={"prompt": "p", "expected": "e", "given": "g"})
        assert r.status_code == 503
    finally:
        set_service(None)


def test_translate_into_target_uses_the_generator(client, db, fake):
    seed_profile(db)
    r = client.post("/translate", json={"text": "dog", "into": "target"})
    assert r.status_code == 200
    assert r.json() == {"translation": "dog-in-target", "into": "target"}
    assert {"translate": "dog", "into": "target"} in fake.calls


def test_translate_into_source_asks_for_the_other_direction(client, db, fake):
    seed_profile(db)
    r = client.post("/translate", json={"text": "perro", "into": "source"})
    assert r.status_code == 200
    assert r.json()["translation"] == "perro-in-source"


def test_translate_rejects_a_direction_it_does_not_know(client, db, fake):
    seed_profile(db)
    assert client.post("/translate", json={"text": "perro", "into": "klingon"}).status_code == 422
    assert client.post("/translate", json={"text": "", "into": "source"}).status_code == 422


def test_translate_batch_answers_every_word_in_order(client, db, fake):
    """The caller pairs translations back to words by position, not by name."""
    seed_profile(db)
    r = client.post("/translate/batch", json={"texts": ["bor", "stor", "by"], "into": "source"})
    assert r.status_code == 200
    assert r.json() == {
        "translations": ["bor-in-source", "stor-in-source", "by-in-source"],
        "into": "source",
    }
    assert {"translate_batch": ["bor", "stor", "by"], "into": "source"} in fake.calls


def test_translate_batch_is_one_call_for_the_whole_import(client, db, fake):
    """The point of the endpoint: a hundred blanks must not be a hundred trips."""
    seed_profile(db)
    texts = [f"ord{index}" for index in range(100)]
    r = client.post("/translate/batch", json={"texts": texts, "into": "source"})
    assert r.status_code == 200
    assert len(r.json()["translations"]) == 100
    assert len([call for call in fake.calls if "translate_batch" in call]) == 1


def test_translate_batch_nulls_one_word_rather_than_losing_the_rest(client, db):
    """Ninety-nine translated words are still worth having."""
    set_service(EnrichmentService(generator=FakeGenerator(declines={"stor"}), workers=0))
    try:
        seed_profile(db)
        r = client.post("/translate/batch", json={"texts": ["bor", "stor", "by"], "into": "source"})
        assert r.status_code == 200
        # Still three entries, so "stor" is identifiable as the one that failed.
        assert r.json()["translations"] == ["bor-in-source", None, "by-in-source"]
    finally:
        set_service(None)


def test_translate_batch_reports_unavailable_when_claude_is_down(client, db):
    set_service(
        EnrichmentService(
            generator=FakeGenerator(fail_with=ContentGenerationError("token expired")), workers=0
        )
    )
    try:
        seed_profile(db)
        r = client.post("/translate/batch", json={"texts": ["bor"], "into": "source"})
        assert r.status_code == 503
    finally:
        set_service(None)


def test_translate_batch_rejects_an_empty_or_oversized_list(client, db, fake):
    seed_profile(db)
    assert client.post("/translate/batch", json={"texts": [], "into": "source"}).status_code == 422
    assert (
        client.post(
            "/translate/batch", json={"texts": ["a"] * 501, "into": "source"}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/translate/batch", json={"texts": ["bor"], "into": "klingon"}
        ).status_code
        == 422
    )


def test_translate_batch_refuses_a_mismatched_count():
    """A short list from Claude would shift every translation onto the wrong word."""
    from app.llm.agent_sdk import AgentSDKGenerator

    generator = AgentSDKGenerator(model="x")

    async def fake_generate(model_cls, system, user, task):
        return BatchTranslationOut(translations=["one", "two"])

    generator._generate = fake_generate
    with pytest.raises(ContentGenerationError):
        asyncio.run(generator.translate_batch(["a", "b", "c"], "source", "en-US", "nb-NO"))


def test_translate_reports_unavailable_rather_than_saving_a_blank(client, db):
    """An empty translation would silently overwrite the field with nothing."""
    set_service(EnrichmentService(generator=FakeGenerator(translation="   "), workers=0))
    try:
        seed_profile(db)
        r = client.post("/translate", json={"text": "perro", "into": "source"})
        assert r.status_code == 503
    finally:
        set_service(None)


def test_translate_reports_unavailable_when_claude_is_down(client, db):
    set_service(
        EnrichmentService(
            generator=FakeGenerator(fail_with=ContentGenerationError("token expired")), workers=0
        )
    )
    try:
        seed_profile(db)
        r = client.post("/translate", json={"text": "perro", "into": "source"})
        assert r.status_code == 503
    finally:
        set_service(None)


def test_mnemonic_is_stored_for_a_leech(client, db, fake):
    seed_profile(db)
    word = client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).json()
    r = client.post(f"/words/{word['id']}/mnemonic")
    assert r.status_code == 200
    db.expire_all()
    assert db.get(Enrichment, word["id"]).mnemonic == "hook for perro"


def test_enqueue_from_a_worker_thread_actually_reaches_a_worker(db):
    """Regression: the routes are sync, so `enqueue` runs in FastAPI's
    threadpool while the workers live on the event loop. asyncio.Queue is not
    thread-safe -- a plain put_nowait from another thread enqueues the item but
    never wakes a worker, and words sit queued forever with no error logged.
    """
    seed_profile(db)
    # Marked done so startup recovery ignores it: this test is about the
    # thread-boundary handoff, not the crash-recovery path.
    word = Word(lemma="perro", native_gloss="dog", enrichment_status=EnrichmentStatus.done)
    db.add(word)
    db.commit()
    word_id = word.id

    processed: list[str] = []

    async def scenario():
        service = EnrichmentService(generator=FakeGenerator(), workers=1)
        service._process = lambda wid: _record(processed, wid)
        await service.start()
        try:
            # asyncio.to_thread mirrors how FastAPI runs a sync endpoint.
            await asyncio.to_thread(service.enqueue, [word_id])
            await asyncio.wait_for(service._queue.join(), timeout=5)
        finally:
            await service.stop()

    asyncio.run(scenario())
    assert processed == [word_id], "worker never received the queued word"


async def _record(sink: list[str], word_id: str) -> None:
    sink.append(word_id)


# --------------------------------------------------------------------------- #
async def get_service_process(word_id: str):
    from app.enrichment import get_service

    await get_service()._process(word_id)
