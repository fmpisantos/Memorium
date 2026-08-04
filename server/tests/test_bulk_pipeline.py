"""Bulk work is split before it reaches Claude, and the pieces run one at a time.

The behaviour that matters is what happens when a piece goes wrong. A batch
translation is paired back to its words by position, so the rule is that a
failed piece leaves holes exactly where its own words were and every other
word still arrives. A set of phrases has no positions to keep, so a failed
piece there simply means fewer sentences.
"""

from __future__ import annotations

import asyncio

import pytest
from app.llm.agent_sdk import AgentSDKGenerator
from app.llm.base import (
    BatchTranslationOut,
    ContentGenerationError,
    GeneratedPhrase,
    PhraseSet,
)


class RecordingGenerator(AgentSDKGenerator):
    """A generator whose only real part is the pipeline.

    `_generate` is replaced with something that answers instantly and writes
    down what it was asked, which is where every assertion below comes from:
    how many calls there were, how big each one was, and what the prompt for
    the later ones said about the earlier ones.
    """

    def __init__(self, *, fail_on: set[int] | None = None, **kwargs):
        super().__init__(model="test", **kwargs)
        self.fail_on = fail_on or set()
        self.prompts: list[str] = []
        self.in_flight = 0
        self.max_in_flight = 0

    async def _generate(self, model_cls, system_prompt, user_prompt, task, timeout=None):
        self.in_flight += 1
        self.max_in_flight = max(self.max_in_flight, self.in_flight)
        try:
            # A real call awaits the CLI; without a suspension point here two
            # overlapping pieces would be indistinguishable from two sequential
            # ones and `max_in_flight` would prove nothing.
            await asyncio.sleep(0)
            index = len(self.prompts)
            self.prompts.append(user_prompt)
            if index in self.fail_on:
                raise ContentGenerationError(f"piece {index} refused")
            return self._answer(model_cls, user_prompt, index)
        finally:
            self.in_flight -= 1

    def _answer(self, model_cls, user_prompt, index):
        if model_cls is BatchTranslationOut:
            words = [
                line.split(". ", 1)[1]
                for line in user_prompt.splitlines()
                if line[:1].isdigit() and ". " in line
            ]
            return BatchTranslationOut(translations=[f"{word}!" for word in words])
        count = int(user_prompt.rsplit("Write ", 1)[1].split(" ")[0])
        return PhraseSet(
            phrases=[
                GeneratedPhrase(target=f"t{index}-{n}", native=f"n{index}-{n}", uses=["a"])
                for n in range(count)
            ]
        )


def translate(generator, texts):
    return asyncio.run(generator.translate_batch(texts, "source", "en-US", "nb-NO")).translations


def phrases(generator, count, focus=()):
    return asyncio.run(
        generator.practice_phrases(
            count=count,
            known_words=["hus", "bil", "vann"],
            focus_words=list(focus),
            source_lang="en-US",
            target_lang="nb-NO",
        )
    ).phrases


# --------------------------------------------------------------------------- #
# Translations
# --------------------------------------------------------------------------- #
def test_a_batch_is_split_into_pieces_of_the_configured_size():
    generator = RecordingGenerator(translate_chunk=20)
    words = [f"ord{index}" for index in range(50)]

    assert translate(generator, words) == [f"{word}!" for word in words]
    assert len(generator.prompts) == 3
    assert [prompt.count("\n1. ") for prompt in generator.prompts] == [1, 1, 1]
    assert "Give 20 translations" in generator.prompts[0]
    assert "Give 10 translations" in generator.prompts[2]


def test_a_short_batch_is_still_one_piece():
    """Splitting is a ceiling, not a quota -- three words are one call."""
    generator = RecordingGenerator(translate_chunk=20)
    assert translate(generator, ["a", "b", "c"]) == ["a!", "b!", "c!"]
    assert len(generator.prompts) == 1


def test_the_pieces_run_one_at_a_time():
    """Each call forks a CLI subprocess; four at once is a Pi that stops serving."""
    generator = RecordingGenerator(translate_chunk=2)
    translate(generator, [f"ord{index}" for index in range(10)])
    assert len(generator.prompts) == 5
    assert generator.max_in_flight == 1


def test_a_failed_piece_costs_its_own_words_and_no_others():
    """The whole point of splitting: one bad answer is not the whole import."""
    generator = RecordingGenerator(translate_chunk=2, fail_on={1})
    assert translate(generator, ["a", "b", "c", "d", "e", "f"]) == [
        "a!",
        "b!",
        "",  # the failed piece: blank, and still in the right slot...
        "",
        "e!",  # ...so the words after it are not shifted onto the wrong entry
        "f!",
    ]


def test_every_piece_failing_is_a_failure_not_a_batch_of_blanks():
    """A blank means Claude declined a word. Silence means Claude is down, and
    the endpoint owes the app a 503 so it can fall back to one at a time."""
    generator = RecordingGenerator(translate_chunk=2, fail_on={0, 1})
    with pytest.raises(ContentGenerationError, match="piece 0 refused"):
        translate(generator, ["a", "b", "c", "d"])


def test_the_budget_stops_the_pipeline_and_the_rest_come_back_blank():
    generator = RecordingGenerator(translate_chunk=2, bulk_budget_seconds=0)
    # The first piece runs regardless -- coming back with nothing at all
    # because a clock said so would be worse than being slow.
    assert translate(generator, ["a", "b", "c", "d", "e", "f"]) == ["a!", "b!", "", "", "", ""]
    assert len(generator.prompts) == 1


def test_a_chunk_size_of_zero_does_not_swallow_the_batch():
    generator = RecordingGenerator(translate_chunk=0)
    assert translate(generator, ["a", "b"]) == ["a!", "b!"]
    assert len(generator.prompts) == 2


# --------------------------------------------------------------------------- #
# Phrases
# --------------------------------------------------------------------------- #
def test_phrases_are_written_a_few_at_a_time():
    generator = RecordingGenerator(phrase_chunk=6)
    written = phrases(generator, 12)
    assert len(written) == 12
    assert len(generator.prompts) == 2
    assert "Write 6 sentences" in generator.prompts[0]


def test_each_piece_is_shown_what_the_pieces_before_it_wrote():
    """Otherwise the third piece writes the first piece again in other words."""
    generator = RecordingGenerator(phrase_chunk=2)
    phrases(generator, 6)

    assert "Already written" not in generator.prompts[0]
    assert "- t0-0" in generator.prompts[1]
    assert "- t0-1" in generator.prompts[1]
    # And the last one sees everything, not just the piece immediately before.
    assert "- t0-0" in generator.prompts[2]
    assert "- t1-0" in generator.prompts[2]


def test_a_repeat_between_pieces_is_dropped():
    """Told twice is not practised twice: the pool is keyed on the sentence."""

    class Repeating(RecordingGenerator):
        def _answer(self, model_cls, user_prompt, index):
            return PhraseSet(
                phrases=[GeneratedPhrase(target="Jeg har et hus.", native="I have a house.", uses=[])]
            )

    generator = Repeating(phrase_chunk=1)
    written = phrases(generator, 4)
    assert len(generator.prompts) == 4
    assert len(written) == 1


def test_a_failed_piece_leaves_a_shorter_set_not_an_empty_one():
    generator = RecordingGenerator(phrase_chunk=2, fail_on={1})
    written = phrases(generator, 6)
    assert [phrase.target for phrase in written] == ["t0-0", "t0-1", "t2-0", "t2-1"]


def test_every_piece_failing_leaves_the_stored_pool_to_answer():
    """The practice router catches this and serves what it already has."""
    generator = RecordingGenerator(phrase_chunk=2, fail_on={0, 1, 2})
    with pytest.raises(ContentGenerationError):
        phrases(generator, 6)


def test_the_words_going_stale_are_dealt_between_the_pieces():
    """All eight named to every piece would have every piece using the same two."""
    generator = RecordingGenerator(phrase_chunk=2)
    phrases(generator, 4, focus=["en", "to", "tre", "fire"])

    first, second = generator.prompts
    assert "en, tre" in first
    assert "to, fire" in second


def test_asking_for_nothing_calls_nobody():
    generator = RecordingGenerator(phrase_chunk=6)
    assert phrases(generator, 0) == []
    assert generator.prompts == []
