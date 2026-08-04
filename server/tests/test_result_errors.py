"""How a failed CLI turn is reported and retried.

A turn that fails mid-flight is reported twice: once in the result frame, and
again as a non-zero exit that the SDK raises for. The exception from the exit
carries only the subtype -- which is "success" for an API error -- so these
tests pin the reason coming from the result frame instead, and the retry that
keeps a 429 from parking a word in `failed` until someone re-runs it by hand.
"""

import pytest
from claude_agent_sdk import ResultMessage

from app.llm import agent_sdk
from app.llm.agent_sdk import AgentSDKGenerator
from app.llm.base import ContentGenerationError, TranslationOut


def result(
    *, is_error=False, subtype="success", api_error_status=None, text=None, payload=None
) -> ResultMessage:
    return ResultMessage(
        subtype=subtype,
        duration_ms=1,
        duration_api_ms=1,
        is_error=is_error,
        num_turns=1,
        session_id="test",
        result=text,
        structured_output=payload,
        api_error_status=api_error_status,
    )


OK = result(payload={"translation": "hola"})


@pytest.fixture
def cli(monkeypatch):
    """Replaces the CLI with a scripted list of turns.

    Each turn is either a list of messages to yield, or an exception to raise
    after yielding them -- the (messages, exception) shape the SDK produces
    when the process exits badly.
    """
    turns: list = []
    calls: list[int] = []

    async def fake_query(*, prompt, options):
        calls.append(1)
        messages, exc = turns.pop(0)
        for message in messages:
            yield message
        if exc is not None:
            raise exc

    monkeypatch.setattr(agent_sdk, "query", fake_query)
    monkeypatch.setattr(agent_sdk, "_RETRY_BACKOFF_SECONDS", 0)

    def script(*turn_specs):
        turns.extend(turn_specs)
        return calls

    return script


async def generate() -> TranslationOut:
    generator = AgentSDKGenerator(model="test-model")
    return await generator._generate(TranslationOut, "system", "user", task="translate")


# --------------------------------------------------------------------------- #
async def test_the_reason_comes_from_the_result_not_the_subtype(cli):
    """The subtype of an API failure is "success", so a message built from it
    reads "Claude reported an error: success" and helps nobody."""
    overloaded = ([result(is_error=True, api_error_status=529, text="API Error: overloaded")], None)
    cli(overloaded, overloaded)  # 529 is retried, so script both attempts

    with pytest.raises(ContentGenerationError) as exc:
        await generate()

    assert "529" in str(exc.value)
    assert "overloaded" in str(exc.value)


async def test_a_transient_api_error_is_retried(cli):
    """A rate limit hits every worker at once; without this a whole import
    lands in `failed`."""
    calls = cli(
        ([result(is_error=True, api_error_status=429, text="rate limit")], None),
        ([OK], None),
    )

    assert (await generate()).translation == "hola"
    assert len(calls) == 2


async def test_a_transient_error_is_retried_only_once(cli):
    calls = cli(
        ([result(is_error=True, api_error_status=503)], None),
        ([result(is_error=True, api_error_status=503)], None),
    )

    with pytest.raises(ContentGenerationError):
        await generate()
    assert len(calls) == 2


async def test_a_refusal_is_not_retried(cli):
    """Only "the API was busy" is worth a second call. Anything else would
    fail the same way twice at twice the cost."""
    calls = cli(([result(is_error=True, subtype="error_max_turns")], None))

    with pytest.raises(ContentGenerationError) as exc:
        await generate()
    assert "error_max_turns" in str(exc.value)
    assert len(calls) == 1


async def test_a_complete_answer_survives_a_bad_exit(cli):
    """The CLI exits non-zero after a failed turn, but the exit arrives after
    the result either way -- a finished generation is not thrown away for it."""
    cli(([OK], RuntimeError("exit code 1")))

    assert (await generate()).translation == "hola"


async def test_a_bad_exit_with_no_result_still_fails(cli):
    cli(([], RuntimeError("CLI not found")))

    with pytest.raises(ContentGenerationError) as exc:
        await generate()
    assert "CLI not found" in str(exc.value)
