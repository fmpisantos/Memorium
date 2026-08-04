"""The stored pool of practice sentences: who fills it, and what leaves it.

Two promises are tested here. Sentences are written before they are asked for,
so opening the practice screen is a request rather than a two-minute wait. And
a sentence stays in the rotation until it has been answered correctly, so
getting one wrong means seeing it again rather than losing it.
"""

import asyncio
import uuid
from datetime import timedelta

import pytest
from sqlalchemy import select

from app import phrases as pool_module
from app.db import SessionLocal
from app.enrichment import EnrichmentService, set_service
from app.llm.base import ContentGenerationError, GeneratedPhrase, PhraseSet
from app.models import Phrase, Profile, utcnow
from app.phrases import PhrasePool, set_pool
from tests.test_enrichment import FakeGenerator
from tests.test_practice import answer, phrases, stock_deck


class RotatingGenerator(FakeGenerator):
    """A generator that really does build on the words it was pointed at.

    The stock fake credits every sentence to the same word, which is fine for
    testing the plumbing and useless for testing rotation -- the whole question
    here is whether the vocabulary moves on.
    """

    async def practice_phrases(self, count, known_words, focus_words, source_lang, target_lang):
        self.calls.append(
            {"phrases": count, "known_words": known_words, "focus_words": focus_words}
        )
        if self.fail_with:
            raise self.fail_with
        start = self.written
        self.written += count
        return PhraseSet(
            phrases=[
                GeneratedPhrase(
                    target=f"Frase {index}.",
                    native=f"Phrase {index}.",
                    uses=[focus_words[index % len(focus_words)]] if focus_words else [],
                )
                for index in range(start + 1, start + count + 1)
            ]
        )


class WatchfulPool(PhrasePool):
    """Counts the nudges it gets instead of acting on them."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.wakes = 0

    def request_top_up(self) -> None:
        self.wakes += 1
        super().request_top_up()


@pytest.fixture
def fake():
    generator = FakeGenerator()
    set_service(EnrichmentService(generator=generator, workers=0))
    yield generator
    set_service(None)


@pytest.fixture
def rotating():
    generator = RotatingGenerator()
    set_service(EnrichmentService(generator=generator, workers=0))
    yield generator
    set_service(None)


def profile_of(db) -> Profile:
    return db.get(Profile, 1)


def current_depth() -> int:
    """The pool as it stands right now.

    A session of its own each time, because the writer commits on another
    connection and a session that opened its transaction earlier would keep
    reporting the pool it saw when it started.
    """
    with SessionLocal() as db:
        return pool_module.depth(db, profile_of(db))


def used_lemmas(db) -> set[str]:
    return {str(lemma) for lemmas in db.scalars(select(Phrase.lemmas)) for lemma in lemmas}


# --------------------------------------------------------------------------- #
# Filling it
# --------------------------------------------------------------------------- #
async def test_the_writer_fills_the_pool_to_its_target(client, fake, db):
    stock_deck(client, count=8)
    pool = PhrasePool(target=10, enabled=False)

    assert await pool.top_up() == 10
    assert pool_module.depth(db, profile_of(db)) == 10


async def test_a_full_pool_is_left_alone(client, fake, db):
    """Every generation forks a CLI subprocess. Writing sentences nobody has
    asked for yet is the point; writing them into a full pool is just cost."""
    stock_deck(client, count=8)
    pool = PhrasePool(target=10, enabled=False)
    await pool.top_up()

    fake.calls.clear()
    assert await pool.top_up() == 0
    assert not fake.calls


async def test_the_writer_runs_without_being_asked(client, fake):
    """The whole point: sentences appear before anyone opens the screen."""
    stock_deck(client, count=8)
    pool = PhrasePool(target=6, interval=0.01, enabled=True)

    await pool.start()
    try:
        for _ in range(200):
            if current_depth() >= 6:
                break
            await asyncio.sleep(0.01)
    finally:
        await pool.stop()

    assert current_depth() == 6


async def test_a_thin_deck_is_not_worth_writing_for(client, fake, db):
    """Three words cannot make a sentence, and the writer must not spin on it
    once a minute for as long as the server is up."""
    stock_deck(client, count=3)
    pool = PhrasePool(target=10, enabled=False)

    assert await pool.top_up() == 0
    assert not any("phrases" in call for call in fake.calls)


async def test_a_dead_generator_does_not_wedge_the_writer(client, fake, db):
    """Claude's token expires. The pool is a buffer, so that is a quiet failure
    that gets recorded and retried -- not one that stops practice."""
    stock_deck(client, count=8)
    pool = PhrasePool(target=10, enabled=False)

    fake.fail_with = ContentGenerationError("token expired")
    assert await pool.top_up() == 0
    assert pool.last_error == "token expired"

    fake.fail_with = None
    assert await pool.top_up() == 10
    assert pool.last_error is None


# --------------------------------------------------------------------------- #
# Choosing what goes in it
# --------------------------------------------------------------------------- #
async def test_every_word_in_the_deck_gets_its_turn(client, rotating, db):
    """The point of the rotation. Left to itself a generator reaches for the
    same dozen easy words, and the rest of the deck is never practised in a
    sentence at all."""
    stock_deck(client, count=20)
    pool = PhrasePool(target=36, enabled=False)

    await pool.top_up()

    assert used_lemmas(db) == {f"ord{index}" for index in range(20)}


async def test_the_next_batch_is_built_on_the_words_the_last_one_missed(client, rotating, db):
    stock_deck(client, count=20)
    pool = PhrasePool(target=24, enabled=False)

    await pool.top_up()

    written = [call for call in rotating.calls if "phrases" in call]
    assert len(written) == 2, "a target of two batches is written as two batches"
    first, second = (set(call["focus_words"]) for call in written)
    assert first and second
    assert first.isdisjoint(second), "the second batch moves on to untouched words"


async def test_the_vocabulary_offered_is_wider_than_the_words_being_practised(
    client, rotating, db
):
    """A focus word has to be usable *with* something. Offering only the eight
    words being rotated to would write eight sentences about each other."""
    stock_deck(client, count=20)
    pool = PhrasePool(target=12, enabled=False)

    await pool.top_up()

    call = next(call for call in rotating.calls if "phrases" in call)
    assert set(call["focus_words"]) < set(call["known_words"])


# --------------------------------------------------------------------------- #
# Emptying it
# --------------------------------------------------------------------------- #
def test_a_sentence_answered_right_does_not_come_back(client, fake, db):
    stock_deck(client)
    served = phrases(client, count=3)["phrases"]

    results = answer(client, [phrase["id"] for phrase in served], correct=True)
    assert all(result["mastered"] for result in results)

    # Nine of the twelve written at the cold start are left, and they are what
    # a session of nine is made of -- no repeats while anything is unanswered.
    later = phrases(client, count=9)["phrases"]
    assert {phrase["id"] for phrase in later}.isdisjoint({phrase["id"] for phrase in served})


def test_a_sentence_answered_wrong_is_kept_and_asked_again(client, fake, db):
    stock_deck(client)
    missed = phrases(client, count=1)["phrases"][0]["id"]

    result = answer(client, [missed], correct=False)[0]
    assert not result["mastered"]
    assert result["retry_after"], "a wrong answer is a date to ask again, not a deletion"

    # Not in the next session: being shown the answer and asked it again
    # straight away tests the last minute rather than the word.
    assert missed not in {phrase["id"] for phrase in phrases(client, count=5)["phrases"]}

    stored = db.get(Phrase, missed)
    assert (stored.attempts, stored.lapses, stored.mastered_at) == (1, 1, None)

    # Once it has sat out its cooling-off period it is back in the rotation,
    # behind everything still unanswered.
    stored.retry_after = utcnow() - timedelta(minutes=1)
    db.add(stored)
    db.commit()
    assert missed in {phrase["id"] for phrase in phrases(client, count=12)["phrases"]}


def test_the_pool_shrinks_only_as_sentences_are_answered(client, fake, db):
    stock_deck(client)
    body = phrases(client, count=4)
    assert body["pool_depth"] == 12, "serving a sentence does not spend it"

    answer(client, [phrase["id"] for phrase in body["phrases"]], correct=True)
    assert phrases(client, count=1)["pool_depth"] == 8


def test_a_replayed_result_is_not_a_second_attempt(client, fake, db):
    """The app writes results to an outbox and flushes them when it can, so the
    same one legitimately arrives twice after a flaky connection."""
    stock_deck(client)
    served = phrases(client, count=1)["phrases"][0]["id"]
    payload = {
        "results": [
            {
                "client_result_id": str(uuid.uuid4()),
                "phrase_id": served,
                "correct": False,
            }
        ]
    }

    client.post("/practice/phrases/results", json=payload)
    replay = client.post("/practice/phrases/results", json=payload).json()["results"][0]

    assert replay["accepted"] and replay["duplicate"]
    stored = db.get(Phrase, served)
    assert (stored.attempts, stored.lapses) == (1, 1)


def test_a_result_for_a_phrase_that_is_gone_is_refused(client, fake):
    """Refused rather than ignored: an entry the server will never accept has
    to leave the app's outbox, or it blocks every flush after it."""
    stock_deck(client)
    response = client.post(
        "/practice/phrases/results",
        json={
            "results": [
                {
                    "client_result_id": str(uuid.uuid4()),
                    "phrase_id": "no-such-phrase",
                    "correct": True,
                }
            ]
        },
    )
    assert response.status_code == 200
    assert response.json()["results"][0]["accepted"] is False


def test_practising_wakes_the_writer(client, fake):
    """What was just handed out is spoken for. Waiting for the next tick to
    replace it is how a keen learner runs the pool dry."""
    stock_deck(client)
    pool = WatchfulPool(target=20, enabled=False)
    set_pool(pool)

    served = phrases(client, count=2)["phrases"]
    assert pool.wakes == 1

    answer(client, [phrase["id"] for phrase in served], correct=True)
    assert pool.wakes == 2, "mastering a sentence is what actually empties the pool"
