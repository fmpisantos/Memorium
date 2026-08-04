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
    # Practice phrases. The task most worth raising to a bigger model: every
    # other one is read once, while a phrase is dictated, transcribed and
    # graded -- so a wrong ending in it is a wrong ending the learner practises.
    phrase_model: str = ""
    # Extended thinking, off by default. Not a cost decision so much as a
    # latency one: asked for six practice sentences with thinking left on, the
    # model spent 11,183 output tokens and 104 seconds deliberating about which
    # words were on the vocabulary list before writing 400 tokens of answer.
    # The same request with thinking disabled took 5.3 seconds and produced the
    # same six sentences. Every task here is small, structured and schema-bound,
    # which is the shape of work that gains least from it.
    claude_thinking: bool = False
    # Each call forks a CLI subprocess, so keep this small.
    enrichment_workers: int = 2
    # Per-call ceiling so a wedged generation can't hang the queue forever.
    claude_timeout_seconds: int = 180
    # Ceiling for a whole bulk request instead of one call of it. A batch is
    # split into pieces run one after another (see `agent_sdk`), so without a
    # budget for the set an import of five hundred words could sit there for
    # twenty-five separate call timeouts. When it runs out the pieces already
    # done are returned and the rest come back empty, which for a translation
    # means a blank the learner fills in and for phrases means a shorter set.
    # Keep it under the app's own request timeout (240s in `APIClient`), or the
    # phone stops listening before the server stops working.
    claude_bulk_budget_seconds: int = 200
    # How much of a bulk request goes into one Claude call. Measured on this
    # deck: a translation call costs about the same for twenty words as for one
    # (4s against 6s), so splitting an import is nearly free and worth it for
    # the failure isolation. A phrase call costs about 100 seconds whatever you
    # ask it for -- the time goes on the constraint, not the sentences -- so
    # every extra piece is another 100 seconds of the learner waiting. Raise
    # `phrase_chunk_size` to `practice.BATCH_SIZE` to stop splitting phrases.
    translate_chunk_size: int = 20
    phrase_chunk_size: int = 6

    # --- the phrase pool ---------------------------------------------------- #
    # Sentences are written ahead of being asked for, because writing them takes
    # a minute or two and nobody opens a practice screen to watch a spinner.
    #
    # How many unanswered sentences to keep in store. Big enough that several
    # sessions can happen back to back without the writer catching up, small
    # enough that a deck of thirty words is not asked for two hundred sentences
    # about them.
    phrase_pool_size: int = 40
    # How often the writer looks at the pool when nothing has asked it to. A
    # session also wakes it on the spot, so this is the floor, not the pace.
    phrase_pool_interval_seconds: int = 600
    # The background writer itself. Off in tests, which drive it by hand.
    phrase_pool_enabled: bool = True
    # How long a sentence answered wrong sits out before it can be asked again.
    # Long enough that the answer is recalled rather than remembered.
    phrase_retry_hours: float = 6.0

    @property
    def task_models(self) -> dict[str, str]:
        """Model per task, with `claude_model` filling in the blanks."""
        return {
            task: getattr(self, f"{task}_model") or self.claude_model
            for task in ("translate", "enrich", "grade", "mnemonic", "story", "phrase")
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
