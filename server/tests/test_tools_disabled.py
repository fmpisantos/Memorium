"""The Agent SDK spawns a Claude Code process, which ships with filesystem and
bash tools enabled by default. This service generates text; it has no business
being able to read or write anything.

These assertions are the reason that stays true after someone edits the options
block six months from now.
"""

from app.llm.agent_sdk import _SANDBOX_CWD, AgentSDKGenerator
from app.llm.base import WordEnrichment, json_schema


def build_options():
    generator = AgentSDKGenerator(model="claude-opus-5")
    return generator._options("system", json_schema(WordEnrichment))


def test_no_tools_are_granted():
    options = build_options()
    assert options.tools == []
    assert options.allowed_tools == []


def test_host_settings_are_not_inherited():
    """Without this, the host's CLAUDE.md, settings.json and MCP servers -- and
    any tools they enable -- would be loaded into a service process."""
    assert build_options().setting_sources == []


def test_working_directory_is_outside_the_project():
    """Belt and braces: if a tool ever did leak through, it should not be
    pointed at the repository."""
    cwd = build_options().cwd
    assert cwd == str(_SANDBOX_CWD)
    assert "Memorium/server/app" not in cwd


def test_structured_output_is_enforced():
    """Schema-forced output is what removes text parsing from the failure path."""
    options = build_options()
    assert options.output_format is not None
    assert options.output_format["type"] == "json_schema"
    assert options.output_format["schema"]["additionalProperties"] is False


def test_generation_is_bounded():
    options = build_options()
    assert options.max_turns is not None and options.max_turns <= 3
