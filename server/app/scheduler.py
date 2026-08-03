"""FSRS scheduling and the card-unlock rules.

Everything that decides *when* you next see a card lives here. The guarantee
this module exists to provide: a word you have learned never leaves the deck.
Its interval grows, but it always comes back.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fsrs import Card as FSRSCard
from fsrs import Rating, Scheduler, State

from app.models import Card, CardKind, Profile, utcnow

# A card failed this many times is fighting you, not teaching you. It gets
# pulled aside for different treatment (mnemonic, fresh sentence) instead of
# grinding through the same failing review.
LEECH_THRESHOLD = 6

# Stability (in days) a word must reach before harder card types unlock.
LISTENING_UNLOCK_STABILITY = 7.0
CLOZE_UNLOCK_STABILITY = 14.0

# Card types every new word starts with.
INITIAL_KINDS = (CardKind.recognition, CardKind.production)


def build_scheduler(profile: Profile) -> Scheduler:
    return Scheduler(desired_retention=profile.desired_retention, enable_fuzzing=True)


def profile_zone(profile: Profile) -> ZoneInfo:
    try:
        return ZoneInfo(profile.timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def local_day_start(profile: Profile, now: datetime | None = None) -> datetime:
    """Start of *today* in the learner's timezone, returned as UTC."""
    now = (now or utcnow()).astimezone(profile_zone(profile))
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.astimezone(UTC)


# --------------------------------------------------------------------------- #
# Conversion between our ORM row and the FSRS value object
# --------------------------------------------------------------------------- #
def to_fsrs(card: Card) -> FSRSCard:
    return FSRSCard(
        card_id=None,
        state=State(card.state),
        step=card.step,
        stability=card.stability,
        difficulty=card.difficulty,
        due=card.due,
        last_review=card.last_review,
    )


def apply_review(
    card: Card,
    rating: Rating | int,
    profile: Profile,
    reviewed_at: datetime | None = None,
) -> float | None:
    """Advance `card` by one review, mutating it in place.

    Returns the elapsed days since the previous review (None if this is the
    first), which the caller records in the immutable review log.
    """
    rating = Rating(int(rating))
    reviewed_at = reviewed_at or utcnow()

    elapsed = None
    if card.last_review is not None:
        elapsed = (reviewed_at - card.last_review).total_seconds() / 86400.0

    updated, _log = build_scheduler(profile).review_card(
        to_fsrs(card), rating, review_datetime=reviewed_at
    )

    card.state = int(updated.state)
    card.step = updated.step
    card.stability = updated.stability
    card.difficulty = updated.difficulty
    card.due = updated.due
    card.last_review = updated.last_review or reviewed_at

    card.reps += 1
    # FSRS does not track lapses; we need them for leech detection.
    if rating is Rating.Again:
        card.lapses += 1
    card.is_leech = card.lapses >= LEECH_THRESHOLD

    return elapsed


# --------------------------------------------------------------------------- #
# Unlock rules
# --------------------------------------------------------------------------- #
def kinds_to_unlock(word_cards: dict[CardKind, Card], has_enrichment: bool) -> list[CardKind]:
    """Which new card kinds this word has earned.

    Creating all four kinds up front would mean 4x the reviews from day one and
    would ask you to type a word into a sentence before you can even recognise
    it. Instead, harder kinds unlock as the word matures.
    """
    unlock: list[CardKind] = []

    recognition = word_cards.get(CardKind.recognition)
    production = word_cards.get(CardKind.production)

    if (
        CardKind.listening not in word_cards
        and recognition is not None
        and (recognition.stability or 0) >= LISTENING_UNLOCK_STABILITY
    ):
        unlock.append(CardKind.listening)

    # Cloze needs a sentence to blank out, so it also waits on enrichment.
    if (
        CardKind.cloze not in word_cards
        and has_enrichment
        and production is not None
        and (production.stability or 0) >= CLOZE_UNLOCK_STABILITY
    ):
        unlock.append(CardKind.cloze)

    return unlock


def new_cards_for_word(word_id: str) -> list[Card]:
    """The cards a freshly added word starts life with.

    Both directions from the start: recognition is what Duolingo drills, and
    production is what turns a word you recognise into a word you can use.
    """
    now = utcnow()
    return [Card(word_id=word_id, kind=kind, due=now) for kind in INITIAL_KINDS]


def audio_autoplays(kind: CardKind) -> bool:
    """Should the question side auto-play pronunciation?

    Only when the prompt is already in the target language. On a production or
    cloze card the prompt is in your native language and the target audio *is*
    the answer -- auto-playing it would read the answer aloud before you tried.
    """
    return kind in (CardKind.recognition, CardKind.listening)


def next_interval_days(card: Card, now: datetime | None = None) -> float:
    now = now or utcnow()
    return max(0.0, (card.due - now).total_seconds() / 86400.0)


__all__ = [
    "LEECH_THRESHOLD",
    "Rating",
    "apply_review",
    "audio_autoplays",
    "build_scheduler",
    "kinds_to_unlock",
    "local_day_start",
    "new_cards_for_word",
    "next_interval_days",
    "profile_zone",
    "timedelta",
    "to_fsrs",
]
