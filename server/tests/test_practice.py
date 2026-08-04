"""Phrase practice: whole sentences built from words already in the deck."""

import uuid

import pytest
from sqlalchemy import select

from app.enrichment import EnrichmentService, set_service
from app.llm.base import ContentGenerationError, GeneratedPhrase
from app.models import Phrase
from tests.test_enrichment import FakeGenerator


@pytest.fixture
def fake():
    generator = FakeGenerator()
    set_service(EnrichmentService(generator=generator, workers=0))
    yield generator
    set_service(None)


def stock_deck(client, count=6):
    """Enough words for a session, all of them reviewed at least once."""
    words = []
    for index in range(count):
        word = client.post(
            "/words", json={"lemma": f"ord{index}", "native_gloss": f"word {index}"}
        ).json()
        words.append(word)
    for word in words:
        for card in word["cards"]:
            client.post(
                "/study/grade",
                json={
                    "grades": [
                        {
                            "client_grade_id": str(uuid.uuid4()),
                            "card_id": card["id"],
                            "rating": 3,
                        }
                    ]
                },
            )
    return words


def phrases(client, **params):
    response = client.get("/practice/phrases", params=params)
    assert response.status_code == 200, response.text
    return response.json()


# --------------------------------------------------------------------------- #
def test_a_thin_deck_is_told_so_rather_than_served_nonsense(client, fake):
    """Three words cannot make a sentence, and inventing the rest would put
    vocabulary the learner has never seen into a listening exercise."""
    stock_deck(client, count=3)
    response = client.get("/practice/phrases")
    assert response.status_code == 409
    assert "words you already know" in response.json()["detail"]
    assert not any("phrases" in call for call in fake.calls)


def test_phrases_are_built_from_the_deck_and_carry_both_sides(client, fake):
    stock_deck(client)
    body = phrases(client, count=3)

    assert body["target_lang"] == "es-ES"
    assert body["source_lang"] == "en-US"
    assert len(body["phrases"]) == 3
    for phrase in body["phrases"]:
        assert phrase["target"] and phrase["native"]

    written = next(call for call in fake.calls if "phrases" in call)
    # A batch is written, not a session: the rest is next session's head start.
    assert written["phrases"] >= 3
    # Only deck words are offered as vocabulary.
    assert set(written["known_words"]) <= {f"ord{index}" for index in range(6)}


def test_the_words_closest_to_being_forgotten_are_named_as_the_focus(client, fake):
    stock_deck(client)
    phrases(client, count=2)
    written = next(call for call in fake.calls if "phrases" in call)
    assert written["focus_words"]
    assert set(written["focus_words"]) <= set(written["known_words"])


def test_a_second_session_is_new_material(client, fake):
    """Serving the same sentences again would be recognition practice, which
    is what the cards already do."""
    stock_deck(client)
    first = {phrase["id"] for phrase in phrases(client, count=3)["phrases"]}
    second = {phrase["id"] for phrase in phrases(client, count=3)["phrases"]}
    assert first.isdisjoint(second)


def test_stored_phrases_are_served_without_generating_again(client, fake, db):
    stock_deck(client)
    phrases(client, count=6)  # fills the pool

    fake.calls.clear()
    served = phrases(client, count=3)
    assert len(served["phrases"]) == 3
    assert not any("phrases" in call for call in fake.calls), "should have reused the pool"


def test_the_pool_answers_when_claude_cannot(client, fake, db):
    """This is the feature most likely to be wanted on a train."""
    stock_deck(client)
    first = phrases(client, count=4)["phrases"]

    fake.fail_with = ContentGenerationError("token expired")
    # `refresh` asks for new sentences, which is exactly what cannot be had,
    # and a session longer than the pool has never-practised ones.
    body = phrases(client, count=12, refresh=True)
    assert len(body["phrases"]) == 12, "repeats beat an error message"
    served = {phrase["id"] for phrase in body["phrases"]}
    assert served & {phrase["id"] for phrase in first}, "already-practised ones count"


def test_an_empty_pool_and_a_dead_generator_is_an_honest_failure(client, fake):
    stock_deck(client)
    fake.fail_with = ContentGenerationError("token expired")
    response = client.get("/practice/phrases")
    assert response.status_code == 503
    assert "token expired" in response.json()["detail"]


def test_refresh_writes_new_sentences_even_with_a_full_pool(client, fake):
    stock_deck(client)
    stored = {phrase["id"] for phrase in phrases(client, count=4)["phrases"]}
    fresh = {phrase["id"] for phrase in phrases(client, count=4, refresh=True)["phrases"]}
    assert stored.isdisjoint(fresh)


def test_a_repeated_sentence_is_not_stored_twice(client, fake, db):
    """Ask a generator for sentences twice in a day and it repeats itself."""
    stock_deck(client)
    fake.phrases = [
        GeneratedPhrase(target="Hola amigo.", native="Hello friend.", uses=["ord0"]),
        GeneratedPhrase(target="hola amigo.", native="Hi friend.", uses=["ord0"]),
    ]
    phrases(client, count=2)
    phrases(client, count=2, refresh=True)

    stored = list(db.scalars(select(Phrase)))
    assert len(stored) == 1


def test_phrases_from_another_language_pair_are_left_alone(client, fake, db):
    stock_deck(client)
    db.add(
        Phrase(
            target="Jeg trenger vann.",
            native="I need water.",
            lemmas=["vann"],
            source_lang="en-US",
            target_lang="nb-NO",
        )
    )
    db.commit()

    body = phrases(client, count=2)
    assert all("trenger" not in phrase["target"] for phrase in body["phrases"])


def test_practice_moves_no_schedules(client, fake):
    """Cards carry the deck's memory; phrases are for using what they taught."""
    words = stock_deck(client)
    card = words[0]["cards"][0]
    before = client.get("/words").json()

    phrases(client, count=3)

    after = client.get("/words").json()
    assert before == after, "a practice session must not touch the deck"
    assert card["id"]  # the card is still the one it was


# --------------------------------------------------------------------------- #
# Grading rubrics
# --------------------------------------------------------------------------- #
def test_grade_defaults_to_the_word_rubric(client, fake, db):
    from tests.test_enrichment import seed_profile

    seed_profile(db)
    client.post("/grade", json={"prompt": "dog", "expected": "perro", "given": "perro"})
    assert fake.calls[-1]["kind"] == "word"


@pytest.mark.parametrize("kind", ["sentence", "dictation"])
def test_grade_passes_the_rubric_through(client, fake, db, kind):
    from tests.test_enrichment import seed_profile

    seed_profile(db)
    response = client.post(
        "/grade",
        json={
            "prompt": "",
            "expected": "El perro corre.",
            "given": "el perro corre",
            "kind": kind,
        },
    )
    assert response.status_code == 200, response.text
    assert fake.calls[-1]["kind"] == kind


def test_an_unknown_rubric_is_rejected(client, fake):
    response = client.post(
        "/grade",
        json={"prompt": "", "expected": "a", "given": "b", "kind": "vibes"},
    )
    assert response.status_code == 422
