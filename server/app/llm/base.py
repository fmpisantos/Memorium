"""The contract between the app and whatever is generating content.

Everything Claude-specific sits behind `ContentGenerator`. Swapping the Agent
SDK for a plain API-key client later means writing one new implementation of
this protocol -- not touching the enrichment queue, the routers, or the app.
"""

from __future__ import annotations

from typing import Any, Literal, Protocol, runtime_checkable

from pydantic import BaseModel, ConfigDict


class ContentGenerationError(RuntimeError):
    """Generation failed in a way the caller should record, not retry forever."""


class _Strict(BaseModel):
    # Anthropic structured outputs require additionalProperties:false, which
    # pydantic emits only under extra="forbid".
    model_config = ConfigDict(extra="forbid")


# --------------------------------------------------------------------------- #
# Output shapes
#
# Every field is required and non-nullable: a field with a default is omitted
# from the schema's `required` list, and the model then feels free to skip it.
# Absence is spelled "" and normalised away on store.
# --------------------------------------------------------------------------- #
class GeneratedSentence(_Strict):
    target: str
    native: str
    cloze_word: str


class WordEnrichment(_Strict):
    lemma: str
    pos: str
    gender: str
    article: str
    plural_form: str
    native_gloss: str
    notes: str
    sentences: list[GeneratedSentence]


class GeneratedPhrase(_Strict):
    target: str
    native: str
    # The supplied vocabulary this sentence was built from, in the dictionary
    # form it was given in -- so a phrase can be retired when its words leave
    # the deck.
    uses: list[str]


class PhraseSet(_Strict):
    phrases: list[GeneratedPhrase]


# What kind of answer is being graded. A word, a sentence the learner
# translated, and a sentence they transcribed from audio are three different
# questions: the first two accept any wording that means the same thing, and
# the third has exactly one right answer.
GradeKind = Literal["word", "sentence", "dictation"]


class AnswerJudgement(_Strict):
    verdict: Literal["correct", "close", "wrong"]
    reason: str


class MnemonicOut(_Strict):
    mnemonic: str


class TranslationOut(_Strict):
    translation: str


class BatchTranslationOut(_Strict):
    """One translation per input, in the order they were sent.

    A word the model cannot translate comes back as an empty string rather than
    being omitted: a shorter list would silently shift every translation after
    it onto the wrong word, which is the failure this whole endpoint exists to
    avoid.
    """

    translations: list[str]


class StoryOut(_Strict):
    title: str
    target: str
    native: str


def json_schema(model: type[BaseModel]) -> dict[str, Any]:
    """Wrap a pydantic model as the SDK's `output_format` payload."""
    return {"type": "json_schema", "schema": model.model_json_schema()}


@runtime_checkable
class ContentGenerator(Protocol):
    async def enrich_word(
        self,
        lemma: str,
        native_gloss: str,
        source_lang: str,
        target_lang: str,
        known_words: list[str],
    ) -> WordEnrichment: ...

    async def grade_answer(
        self,
        prompt: str,
        expected: str,
        given: str,
        source_lang: str,
        target_lang: str,
        kind: GradeKind = "word",
    ) -> AnswerJudgement: ...

    async def practice_phrases(
        self,
        count: int,
        known_words: list[str],
        focus_words: list[str],
        source_lang: str,
        target_lang: str,
    ) -> PhraseSet: ...

    async def mnemonic(
        self, lemma: str, native_gloss: str, source_lang: str, target_lang: str
    ) -> MnemonicOut: ...

    async def translate(
        self,
        text: str,
        into: Literal["source", "target"],
        source_lang: str,
        target_lang: str,
    ) -> TranslationOut: ...

    async def translate_batch(
        self,
        texts: list[str],
        into: Literal["source", "target"],
        source_lang: str,
        target_lang: str,
    ) -> BatchTranslationOut: ...

    async def daily_story(
        self, lemmas: list[str], source_lang: str, target_lang: str
    ) -> StoryOut: ...
