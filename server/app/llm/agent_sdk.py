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
from pathlib import Path
from typing import Any, Literal, TypeVar

from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query
from pydantic import BaseModel, ValidationError

from app.llm import prompts
from app.llm.base import (
    AnswerJudgement,
    BatchTranslationOut,
    ContentGenerationError,
    MnemonicOut,
    StoryOut,
    TranslationOut,
    WordEnrichment,
    json_schema,
)

log = logging.getLogger("memorium.llm")

T = TypeVar("T", bound=BaseModel)


def _clean_translation(text: str) -> str:
    """Strip the quotes models wrap a bare answer in despite being told not to."""
    return text.strip().strip('"“”').strip()

# The CLI is given a directory of its own. With tools disabled nothing should
# ever touch it -- this is the second lock on the same door.
_SANDBOX_CWD = Path(tempfile.gettempdir()) / "memorium-agent-cwd"


class AgentSDKGenerator:
    def __init__(
        self,
        model: str,
        timeout_seconds: int = 180,
        task_models: dict[str, str] | None = None,
    ):
        self.model = model
        # Per-task overrides, keyed by the task names in `config.task_models`.
        # A missing or empty entry falls back to `model`, so callers that don't
        # care about the split can keep passing a single name.
        self.task_models = task_models or {}
        self.timeout_seconds = timeout_seconds
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
        self, model_cls: type[T], system_prompt: str, user_prompt: str, task: str
    ) -> T:
        options = self._options(system_prompt, json_schema(model_cls), self.model_for(task))

        async def _run() -> dict[str, Any] | None:
            result: ResultMessage | None = None
            async for message in query(prompt=user_prompt, options=options):
                if isinstance(message, ResultMessage):
                    result = message
            if result is None:
                raise ContentGenerationError("Claude returned no result message")
            if result.is_error:
                raise ContentGenerationError(
                    f"Claude reported an error: {result.subtype} {result.errors or ''}".strip()
                )
            return result.structured_output

        try:
            payload = await asyncio.wait_for(_run(), timeout=self.timeout_seconds)
        except TimeoutError as exc:
            raise ContentGenerationError(
                f"Claude did not respond within {self.timeout_seconds}s"
            ) from exc
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
    ) -> AnswerJudgement:
        return await self._generate(
            AnswerJudgement,
            prompts.GRADE_SYSTEM,
            prompts.grade_prompt(prompt, expected, given, source_lang, target_lang),
            task="grade",
        )

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

        result = await self._generate(
            BatchTranslationOut,
            prompts.BATCH_TRANSLATE_SYSTEM,
            prompts.batch_translate_prompt(texts, into, source_lang, target_lang),
            # The same task as a single translation, so MEMORIUM_TRANSLATE_MODEL
            # governs both rather than the batch quietly running on a different
            # model to the one-at-a-time path.
            task="translate",
        )
        translations = [_clean_translation(text) for text in result.translations]

        # Length is the one thing the caller cannot recover from, because it
        # pairs translations back to words by position. A model that returned
        # the wrong number of them has mislabelled an unknown subset, so the
        # whole batch is discarded rather than written into the deck wrong --
        # the caller falls back to translating one at a time.
        if len(translations) != len(texts):
            raise ContentGenerationError(
                f"Asked for {len(texts)} translations and got {len(translations)}"
            )
        result.translations = translations
        return result

    async def daily_story(
        self, lemmas: list[str], source_lang: str, target_lang: str
    ) -> StoryOut:
        return await self._generate(
            StoryOut,
            prompts.STORY_SYSTEM,
            prompts.story_prompt(lemmas, source_lang, target_lang),
            task="story",
        )
