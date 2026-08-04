from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Server configuration, read from the environment or a .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="MEMORIUM_", extra="ignore")

    # --- storage -------------------------------------------------------------
    database_url: str = "sqlite:///./data/memorium.db"

    # --- auth ----------------------------------------------------------------
    # Identity comes from Google: the app sends the ID token it already holds,
    # and the server checks the signature, the audience, and then the address
    # against the allowlist below. There is no password and no user table.
    #
    # The OAuth *client ID* of the iOS app, from the Google Cloud console. It
    # is the expected `aud` of every ID token, which is what stops a token
    # minted for some other app being replayed at this one.
    google_client_id: str = ""
    # Who may use this server, comma-separated. Anyone not on it is refused
    # even with a perfectly valid Google login.
    allowed_emails: str = ""

    @property
    def allowed_email_set(self) -> frozenset[str]:
        """The allowlist, case-folded -- addresses are not case-sensitive."""
        raw = self.allowed_emails.replace(";", ",").replace("\n", ",")
        return frozenset(entry.strip().casefold() for entry in raw.split(",") if entry.strip())

    # --- Claude --------------------------------------------------------------
    # The Agent SDK spawns the `claude` CLI, which authenticates from the
    # environment (CLAUDE_CODE_OAUTH_TOKEN for headless use).
    #
    # Haiku is the default because every task here is small: a word, a couple of
    # sentences, a five-sentence story. Nothing needs a frontier model, and each
    # call forks its own subprocess, so the cheap model is also the fast one.
    claude_model: str = "claude-haiku-4-5"
    # Per-task overrides. Empty means "use claude_model", so raising one task to
    # a bigger model is an env var (MEMORIUM_ENRICH_MODEL=...) rather than a
    # code change.
    translate_model: str = ""
    enrich_model: str = ""
    grade_model: str = ""
    mnemonic_model: str = ""
    story_model: str = ""
    # Each call forks a CLI subprocess, so keep this small.
    enrichment_workers: int = 2
    # Per-call ceiling so a wedged generation can't hang the queue forever.
    claude_timeout_seconds: int = 180

    @property
    def task_models(self) -> dict[str, str]:
        """Model per task, with `claude_model` filling in the blanks."""
        return {
            task: getattr(self, f"{task}_model") or self.claude_model
            for task in ("translate", "enrich", "grade", "mnemonic", "story")
        }

    # --- study defaults (seeded into the profile on first run) ---------------
    default_source_lang: str = "en-US"
    default_target_lang: str = "es-ES"
    default_desired_retention: float = 0.90
    default_daily_new_limit: int = 10
    default_timezone: str = "Europe/Lisbon"


@lru_cache
def get_settings() -> Settings:
    return Settings()
