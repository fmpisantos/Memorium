"""Each Claude task picks its own model.

The point of the split is that one task can be raised to a bigger model without
dragging the other four (and their cost) up with it. That only holds if the
per-task name actually reaches `ClaudeAgentOptions.model`, which is what these
assertions pin down.
"""

from app.config import Settings
from app.llm.agent_sdk import AgentSDKGenerator
from app.llm.base import WordEnrichment, json_schema


def options_for(generator: AgentSDKGenerator, task: str):
    return generator._options("system", json_schema(WordEnrichment), generator.model_for(task))


def test_tasks_fall_back_to_the_default_model():
    generator = AgentSDKGenerator(model="default-model")
    for task in ("translate", "enrich", "grade", "mnemonic", "story"):
        assert options_for(generator, task).model == "default-model"


def test_an_override_reaches_the_agent_options():
    generator = AgentSDKGenerator(
        model="default-model", task_models={"translate": "cheap-model"}
    )
    assert options_for(generator, "translate").model == "cheap-model"
    # And only that task: an override must not leak into its neighbours.
    assert options_for(generator, "enrich").model == "default-model"


def test_blank_override_is_treated_as_unset():
    """Empty is how `.env` spells "no override" -- it must not become the model."""
    generator = AgentSDKGenerator(model="default-model", task_models={"enrich": ""})
    assert options_for(generator, "enrich").model == "default-model"


def test_settings_resolve_blanks_to_the_default():
    settings = Settings(claude_model="base", enrich_model="bigger")
    assert settings.task_models == {
        "translate": "base",
        "enrich": "bigger",
        "grade": "base",
        "mnemonic": "base",
        "story": "base",
    }


def test_default_model_is_the_cheap_one():
    """A frontier model translating one word is the bug this guards against."""
    assert Settings().claude_model == "claude-haiku-4-5"
