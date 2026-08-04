"""Claude Agent SDK implementation of `ContentGenerator`.

Two things matter here beyond the prompts:

1. **Tools are disabled.** The Agent SDK spawns a Claude Code process, which
   ships with filesystem and bash tools enabled by default. This service only
   needs text generation, so it runs with `tools=[]`, no inherited settings,
   and a working directory outside the project. Verified by test_tools_disabled.

2. **Output is schema-enforced.** `output_format` forces a structured tool call,
   so the result arrives as a parsed dict on `ResultMessage.structured_output`
   rather than as prose we have to fish JSON out of.
"""

from __future__ import annotations

import asyncio
import logging
import tempfile
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any, Literal, TypeVar

from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query
from pydantic import BaseModel, ValidationError

from app.llm import prompts
from app.llm.base import (
    AnswerJudgement,
    BatchTranslationOut,
    ContentGenerationError,
    GeneratedPhrase,
    GradeKind,
    MnemonicOut,
    PhraseSet,
    StoryOut,
    TranslationOut,
    WordEnrichment,
    json_schema,
)

log = logging.getLogger("memorium.llm")

T = TypeVar("T", bound=BaseModel)
PieceT = TypeVar("PieceT")  # one piece of a bulk request
ResultT = TypeVar("ResultT")  # ...and what running that piece returns


def _clean_translation(text: str) -> str:
    """Strip the quotes models wrap a bare answer in despite being told not to."""
    return text.strip().strip('"“”').strip()


# HTTP statuses that mean "the API was busy, not that the request was wrong".
# A rate limit or an overloaded model hits every worker at once, so without a
# retry a burst of imports lands a whole batch of words in `failed`.
_TRANSIENT_API_STATUSES = frozenset({408, 429, 500, 502, 503, 504, 529})
_RETRY_BACKOFF_SECONDS = 5


class _ResultError(ContentGenerationError):
    """The CLI reported a failed turn, with the API status if it had one."""

    def __init__(self, message: str, api_error_status: int | None):
        super().__init__(message)
        self.api_error_status = api_error_status

    @property
    def is_transient(self) -> bool:
        return self.api_error_status in _TRANSIENT_API_STATUSES


def _describe(result: ResultMessage) -> str:
    """Why a failed result failed, in the most specific terms available.

    Worth assembling by hand: for an API error mid-turn the CLI leaves
    `subtype` as "success" and puts the reason in `api_error_status` and
    `result`, so a message built from the subtype alone reads "Claude reported
    an error: success" and tells nobody anything.
    """
    parts = [result.subtype]
    if result.api_error_status:
        parts.append(f"HTTP {result.api_error_status}")
    parts.extend(result.errors or [])
    if result.result:
        parts.append(result.result[:300])
    return "; ".join(part for part in parts if part)

# The CLI is given a directory of its own. With tools disabled nothing should
# ever touch it -- this is the second lock on the same door.
_SANDBOX_CWD = Path(tempfile.gettempdir()) / "memorium-agent-cwd"


# --------------------------------------------------------------------------- #
# Bulk work
#
# Nothing is ever asked of Claude in one go. A hundred words to translate or a
# dozen sentences to write is split into pieces and the pieces are run one
# after another, because a single call carrying the lot fails in the way that
# costs the most: everything at once. The reasons compound.
#
# * One long answer is one thing to get wrong. A batch translation is paired
#   back to its words by position, so a model that skips an entry mislabels
#   every word after it -- and the only safe response is to throw the whole
#   answer away. Twenty words at a time means a bad piece costs twenty words,
#   not five hundred.
# * A piece that fails is retried, dropped, or timed out on its own, and the
#   rest of the batch still arrives. Whatever came back is kept.
# * Long generations are where the CLI stalls and where the model starts
#   repeating itself. Twelve sentences written in one breath are twelve
#   variations on the first three.
#
# One at a time, not all at once in parallel: each call forks a CLI
# subprocess, and a Raspberry Pi running four of those has stopped serving the
# app. The cost is wall-clock, which `claude_bulk_budget_seconds` bounds.
# --------------------------------------------------------------------------- #

# Defaults for how much goes into one call, overridable per deployment through
# `config`. Measured against a real deck: twenty words cost 6 seconds to
# translate where one costs 4, so splitting an import barely shows. Phrases are
# the opposite -- a call costs about 100 seconds whether you ask it for four
# sentences or twelve, because the time goes on working within the vocabulary
# rather than on writing -- so a piece here is a piece of the learner's waiting.
TRANSLATE_CHUNK = 20
PHRASE_CHUNK = 6

# Below this there is not enough of the budget left to be worth spawning a CLI
# for -- it would only time out mid-answer and bill for it.
_MIN_PIECE_SECONDS = 15


def _split(items: list[PieceT], size: int) -> list[list[PieceT]]:
    return [items[start : start + size] for start in range(0, len(items), size)]


class AgentSDKGenerator:
    def __init__(
        self,
        model: str,
        timeout_seconds: int = 180,
        task_models: dict[str, str] | None = None,
        bulk_budget_seconds: int = 200,
        translate_chunk: int = TRANSLATE_CHUNK,
        phrase_chunk: int = PHRASE_CHUNK,
        thinking: bool = False,
    ):
        self.model = model
        # Per-task overrides, keyed by the task names in `config.task_models`.
        # A missing or empty entry falls back to `model`, so callers that don't
        # care about the split can keep passing a single name.
        self.task_models = task_models or {}
        self.timeout_seconds = timeout_seconds
        # For a whole split-up batch, where `timeout_seconds` governs one piece
        # of it. See the note on bulk work above.
        self.bulk_budget_seconds = bulk_budget_seconds
        # A chunk of zero or less would mean no pieces at all, and a batch that
        # silently returned nothing. One item per call is the smallest split
        # that still does the work.
        self.translate_chunk = max(1, translate_chunk)
        self.phrase_chunk = max(1, phrase_chunk)
        self.thinking = thinking
        _SANDBOX_CWD.mkdir(parents=True, exist_ok=True)

    def model_for(self, task: str) -> str:
        return self.task_models.get(task) or self.model

    # ----------------------------------------------------------------- #
    def _options(
        self, system_prompt: str, schema: dict[str, Any], model: str | None = None
    ) -> ClaudeAgentOptions:
        return ClaudeAgentOptions(
            model=model or self.model,
            system_prompt=system_prompt,
            output_format=schema,
            # Thinking is what makes a phrase call cost a hundred seconds
            # instead of five -- see `config.claude_thinking`. Left to the
            # SDK's own default when it is switched back on.
            **({} if self.thinking else {"thinking": {"type": "disabled"}}),
            # No tools. Not "no dangerous tools" -- none at all.
            tools=[],
            allowed_tools=[],
            # Do not inherit the host's CLAUDE.md, settings, or MCP servers.
            setting_sources=[],
            cwd=str(_SANDBOX_CWD),
            # One assistant turn to emit the structured tool call, one to close.
            max_turns=2,
        )

    async def _generate(
        self,
        model_cls: type[T],
        system_prompt: str,
        user_prompt: str,
        task: str,
        timeout: float | None = None,
    ) -> T:
        """One generation. `timeout` overrides the per-call ceiling downwards,
        which is how a piece of a bulk request is held to what is left of the
        batch's budget rather than to the full call timeout."""
        options = self._options(system_prompt, json_schema(model_cls), self.model_for(task))
        limit = self.timeout_seconds if timeout is None else min(timeout, self.timeout_seconds)

        async def _run() -> dict[str, Any] | None:
            """One CLI invocation.

            The result frame and the process exit are separate events: a failed
            turn is reported in the result *and* exits the CLI non-zero, and the
            SDK then raises for the exit. Hold on to the result either way --
            it is both the only place the real reason is written down and, when
            the generation actually finished, a complete answer that a messy
            exit is no reason to discard.
            """
            result: ResultMessage | None = None
            try:
                async for message in query(prompt=user_prompt, options=options):
                    if isinstance(message, ResultMessage):
                        result = message
            except Exception:
                if result is None:
                    raise
                if not result.is_error:
                    log.warning("%s: the CLI exited badly after a complete result", task)
            if result is None:
                raise ContentGenerationError("Claude returned no result message")
            if result.is_error:
                raise _ResultError(
                    f"Claude reported an error: {_describe(result)}", result.api_error_status
                )
            return result.structured_output

        # A deadline rather than a per-attempt timeout, so the retry below
        # spends what is left of the call's time instead of being granted the
        # whole of it a second time -- which is what would let one piece of a
        # bulk request run past the budget for all of it.
        deadline = time.monotonic() + limit
        retried = False
        while True:
            try:
                payload = await asyncio.wait_for(
                    _run(), timeout=max(deadline - time.monotonic(), 0)
                )
                break
            except TimeoutError as exc:
                raise ContentGenerationError(
                    f"Claude did not respond within {limit:.0f}s"
                ) from exc
            except _ResultError as exc:
                # Retried here rather than by the caller: the enrichment queue
                # marks a word `failed` and only a manual re-run picks it up
                # again, which is a poor answer to a 429.
                if retried or not exc.is_transient:
                    raise
                retried = True
                log.warning("retrying %s after a transient failure: %s", task, exc)
                await asyncio.sleep(_RETRY_BACKOFF_SECONDS)
            except ContentGenerationError:
                raise
            except Exception as exc:  # CLI missing, auth expired, transport died
                raise ContentGenerationError(f"{type(exc).__name__}: {exc}") from exc

        if payload is None:
            raise ContentGenerationError("Claude returned no structured output")

        try:
            return model_cls.model_validate(payload)
        except ValidationError as exc:
            raise ContentGenerationError(f"Response did not match schema: {exc}") from exc

    # ----------------------------------------------------------------- #
    # The bulk pipeline
    # ----------------------------------------------------------------- #
    async def _pipeline(
        self,
        pieces: list[PieceT],
        run: Callable[[PieceT, float], Awaitable[ResultT]],
        *,
        task: str,
    ) -> list[ResultT | None]:
        """Run the pieces of a split-up bulk request, one at a time.

        Each piece gets whatever is left of the batch's budget, capped at the
        per-call timeout, and is handed that as its deadline. A piece that
        fails becomes `None` in the results and the next one still runs: the
        point of splitting the work up is that one bad answer costs one piece
        of the batch rather than all of it. Callers decide what a hole means --
        an untranslated word, or simply a shorter set of sentences.

        Every piece failing is a different matter, and raises: that is not a
        partial result, it is Claude being unreachable, and the callers above
        have real fallbacks for it (the stored phrase pool, a 503 the app
        answers by translating one word at a time).
        """
        deadline = time.monotonic() + self.bulk_budget_seconds
        results: list[ResultT | None] = []
        first_failure: Exception | None = None

        for index, piece in enumerate(pieces):
            remaining = deadline - time.monotonic()
            # The first piece always runs. Coming back with nothing because a
            # clock said so would be a worse answer than a slow one.
            if index and remaining < _MIN_PIECE_SECONDS:
                log.warning(
                    "%s: out of time after %d of %d pieces; the rest are unanswered",
                    task,
                    index,
                    len(pieces),
                )
                results.extend([None] * (len(pieces) - index))
                break
            try:
                results.append(await run(piece, remaining))
            except ContentGenerationError as exc:
                log.warning(
                    "%s: piece %d of %d failed: %s", task, index + 1, len(pieces), exc
                )
                first_failure = first_failure or exc
                results.append(None)

        if pieces and all(result is None for result in results):
            raise ContentGenerationError(
                str(first_failure) if first_failure else "Claude answered none of the batch"
            )
        return results

    # ----------------------------------------------------------------- #
    async def enrich_word(
        self,
        lemma: str,
        native_gloss: str,
        source_lang: str,
        target_lang: str,
        known_words: list[str],
    ) -> WordEnrichment:
        enrichment = await self._generate(
            WordEnrichment,
            prompts.ENRICH_SYSTEM,
            prompts.enrich_prompt(lemma, native_gloss, source_lang, target_lang, known_words),
            task="enrich",
        )
        # A cloze card blanks out `cloze_word` by substring match. If the model
        # returned a form that isn't actually in the sentence, the blank would
        # never appear and the card would show the answer. Drop those.
        enrichment.sentences = [
            s for s in enrichment.sentences if s.cloze_word and s.cloze_word in s.target
        ]
        return enrichment

    async def grade_answer(
        self,
        prompt: str,
        expected: str,
        given: str,
        source_lang: str,
        target_lang: str,
        kind: GradeKind = "word",
    ) -> AnswerJudgement:
        return await self._generate(
            AnswerJudgement,
            prompts.grade_system(kind),
            prompts.grade_prompt(prompt, expected, given, source_lang, target_lang, kind),
            task="grade",
        )

    async def practice_phrases(
        self,
        count: int,
        known_words: list[str],
        focus_words: list[str],
        source_lang: str,
        target_lang: str,
    ) -> PhraseSet:
        """A set of sentences, written a few at a time.

        Splitting this one is not only about failure. A batch written in a
        single pass is a batch written in one idea -- ten sentences about
        needing things, or every one of them starting "I". Each piece here is
        shown what the pieces before it produced and told to write something
        else, which is a better lever on variety than any amount of asking for
        it in the system prompt.
        """
        if count <= 0:
            return PhraseSet(phrases=[])

        chunk = self.phrase_chunk
        sizes = [min(chunk, count - start) for start in range(0, count, chunk)]
        # The words closest to being forgotten are dealt out between the pieces
        # rather than repeated to each. Naming all eight every time would have
        # every piece reaching for the same two.
        pieces = [
            (size, focus_words[index :: len(sizes)]) for index, size in enumerate(sizes)
        ]

        written: list[GeneratedPhrase] = []
        seen: set[str] = set()

        async def run(piece: tuple[int, list[str]], remaining: float) -> int:
            size, focus = piece
            result = await self._generate(
                PhraseSet,
                prompts.PHRASE_SYSTEM,
                prompts.phrase_prompt(
                    size,
                    known_words,
                    focus,
                    source_lang,
                    target_lang,
                    # Sequential, so this is everything the earlier pieces
                    # actually produced -- not a guess at it.
                    avoid=[phrase.target for phrase in written],
                ),
                task="phrase",
                timeout=remaining,
            )
            fresh = 0
            for phrase in result.phrases:
                target = phrase.target.strip()
                # A sentence missing either side is unusable: the learner is
                # asked to produce one from the other, and both directions are
                # offered. A repeat of one already written is not practice.
                if not target or not phrase.native.strip():
                    continue
                if target.casefold() in seen:
                    continue
                seen.add(target.casefold())
                written.append(phrase)
                fresh += 1
            return fresh

        await self._pipeline(pieces, run, task="phrase")
        return PhraseSet(phrases=written[:count])

    async def mnemonic(
        self, lemma: str, native_gloss: str, source_lang: str, target_lang: str
    ) -> MnemonicOut:
        return await self._generate(
            MnemonicOut,
            prompts.MNEMONIC_SYSTEM,
            prompts.mnemonic_prompt(lemma, native_gloss, source_lang, target_lang),
            task="mnemonic",
        )

    async def translate(
        self,
        text: str,
        into: Literal["source", "target"],
        source_lang: str,
        target_lang: str,
    ) -> TranslationOut:
        result = await self._generate(
            TranslationOut,
            prompts.TRANSLATE_SYSTEM,
            prompts.translate_prompt(text, into, source_lang, target_lang),
            task="translate",
        )
        # Models like to wrap a bare answer in quotes despite being told not
        # to, and the stray character would end up in the deck.
        result.translation = _clean_translation(result.translation)
        return result

    async def translate_batch(
        self,
        texts: list[str],
        into: Literal["source", "target"],
        source_lang: str,
        target_lang: str,
    ) -> BatchTranslationOut:
        if not texts:
            return BatchTranslationOut(translations=[])

        pieces = _split(texts, self.translate_chunk)

        async def run(piece: list[str], remaining: float) -> list[str]:
            result = await self._generate(
                BatchTranslationOut,
                prompts.BATCH_TRANSLATE_SYSTEM,
                prompts.batch_translate_prompt(piece, into, source_lang, target_lang),
                # The same task as a single translation, so
                # MEMORIUM_TRANSLATE_MODEL governs both rather than the batch
                # quietly running on a different model to the one-at-a-time path.
                task="translate",
                timeout=remaining,
            )
            translations = [_clean_translation(text) for text in result.translations]

            # Length is the one thing the caller cannot recover from, because
            # it pairs translations back to words by position. A model that
            # returned the wrong number of them has mislabelled an unknown
            # subset, so this piece is discarded rather than written into the
            # deck wrong. Splitting the batch is what makes that affordable:
            # the words in the other pieces are unaffected.
            if len(translations) != len(piece):
                raise ContentGenerationError(
                    f"Asked for {len(piece)} translations and got {len(translations)}"
                )
            return translations

        answers = await self._pipeline(pieces, run, task="translate")

        # Position is the contract, so a piece that failed leaves its words
        # blank rather than shortening the list. The endpoint turns a blank
        # into a null, which the app shows as a word to fill in by hand.
        translations: list[str] = []
        for piece, answer in zip(pieces, answers):
            translations.extend(answer if answer is not None else [""] * len(piece))
        return BatchTranslationOut(translations=translations)

    async def daily_story(
        self, lemmas: list[str], source_lang: str, target_lang: str
    ) -> StoryOut:
        return await self._generate(
            StoryOut,
            prompts.STORY_SYSTEM,
            prompts.story_prompt(lemmas, source_lang, target_lang),
            task="story",
        )
