from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Server configuration, read from the environment or a .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="MEMORIUM_", extra="ignore")

    # --- storage -------------------------------------------------------------
    database_url: str = "sqlite:///./data/memorium.db"

    # --- auth ----------------------------------------------------------------
    # Single shared bearer token. The app sends it on every request.
    # There is no user system: this token IS the authentication boundary.
    api_token: str = "change-me"

    # --- Claude --------------------------------------------------------------
    # The Agent SDK spawns the `claude` CLI, which authenticates from the
    # environment (CLAUDE_CODE_OAUTH_TOKEN for headless use).
    claude_model: str = "claude-opus-5"
    # Each call forks a CLI subprocess, so keep this small.
    enrichment_workers: int = 2
    # Per-call ceiling so a wedged generation can't hang the queue forever.
    claude_timeout_seconds: int = 180

    # --- study defaults (seeded into the profile on first run) ---------------
    default_source_lang: str = "en-US"
    default_target_lang: str = "es-ES"
    default_desired_retention: float = 0.90
    default_daily_new_limit: int = 10
    default_timezone: str = "Europe/Lisbon"


@lru_cache
def get_settings() -> Settings:
    return Settings()
