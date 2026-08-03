"""The scheduling guarantees this app exists to provide.

The headline requirement is that a word you have learned never falls out of
rotation. That is a property worth asserting, not assuming.
"""

from datetime import timedelta

import pytest

from app.models import Card, CardKind, utcnow
from app.scheduler import (
    LEECH_THRESHOLD,
    apply_review,
    audio_autoplays,
    kinds_to_unlock,
    new_cards_for_word,
)

AGAIN, HARD, GOOD, EASY = 1, 2, 3, 4


def make_card(kind=CardKind.recognition) -> Card:
    return Card(id="c1", word_id="w1", kind=kind, due=utcnow())


def test_new_word_starts_in_both_directions():
    """Recognition alone is the Duolingo gap; production is the whole point."""
    kinds = {c.kind for c in new_cards_for_word("w1")}
    assert kinds == {CardKind.recognition, CardKind.production}


def test_good_rating_schedules_into_the_future(profile):
    card = make_card()
    before = utcnow()
    apply_review(card, GOOD, profile, reviewed_at=before)
    assert card.due > before
    assert card.reps == 1
    assert card.lapses == 0


def test_easy_pushes_further_out_than_hard(profile):
    now = utcnow()
    easy, hard = make_card(), make_card()
    # Mature both identically first, so we compare review-state intervals.
    for card in (easy, hard):
        apply_review(card, GOOD, profile, reviewed_at=now)
        apply_review(card, GOOD, profile, reviewed_at=now + timedelta(days=1))

    t = now + timedelta(days=10)
    apply_review(easy, EASY, profile, reviewed_at=t)
    apply_review(hard, HARD, profile, reviewed_at=t)

    assert easy.due > hard.due


def test_again_counts_a_lapse_and_shortens_the_interval(profile):
    now = utcnow()
    card = make_card()
    apply_review(card, GOOD, profile, reviewed_at=now)
    apply_review(card, GOOD, profile, reviewed_at=now + timedelta(days=1))
    apply_review(card, GOOD, profile, reviewed_at=now + timedelta(days=10))

    t = now + timedelta(days=40)
    long_due = card.due
    apply_review(card, AGAIN, profile, reviewed_at=t)

    assert card.lapses == 1
    assert card.due < long_due  # forgotten -> comes back soon


def test_mature_card_keeps_growing_and_never_retires(profile):
    """The core promise: known words stay in rotation at growing intervals.

    A card reviewed correctly over and over must keep coming back -- further
    out each time, but always scheduled. Nothing is ever marked 'done'.
    """
    card = make_card()
    now = utcnow()
    intervals = []

    for _ in range(12):
        apply_review(card, GOOD, profile, reviewed_at=now)
        interval = (card.due - now).total_seconds() / 86400.0
        intervals.append(interval)
        now = card.due  # review exactly when it comes due

    # Always scheduled -- there is no terminal state.
    assert card.due is not None
    # Intervals grow into months, not days.
    assert intervals[-1] > intervals[0]
    assert intervals[-1] > 30, f"mature interval only reached {intervals[-1]:.1f} days"
    # And it is still a real future review, not an infinity sentinel.
    assert intervals[-1] < 36600


def test_leech_flag_raised_after_repeated_failure(profile):
    card = make_card()
    now = utcnow()
    for i in range(LEECH_THRESHOLD):
        assert card.is_leech is False, f"flagged early at lapse {i}"
        apply_review(card, AGAIN, profile, reviewed_at=now + timedelta(minutes=i))
    assert card.is_leech is True
    assert card.lapses == LEECH_THRESHOLD


# --------------------------------------------------------------------------- #
# Audio rules -- the correction to the original card-flow spec
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    ("kind", "expected"),
    [
        (CardKind.recognition, True),
        (CardKind.listening, True),
        (CardKind.production, False),
        (CardKind.cloze, False),
    ],
)
def test_audio_only_autoplays_when_it_is_not_the_answer(kind, expected):
    """On a native-language prompt, auto-playing target audio reads the answer aloud."""
    assert audio_autoplays(kind) is expected


# --------------------------------------------------------------------------- #
# Unlock rules
# --------------------------------------------------------------------------- #
def test_nothing_unlocks_for_a_brand_new_word():
    cards = {c.kind: c for c in new_cards_for_word("w1")}
    assert kinds_to_unlock(cards, has_enrichment=True) == []


def test_listening_unlocks_once_recognition_is_stable():
    cards = {c.kind: c for c in new_cards_for_word("w1")}
    cards[CardKind.recognition].stability = 8.0
    assert kinds_to_unlock(cards, has_enrichment=False) == [CardKind.listening]


def test_cloze_waits_for_enrichment_even_when_stable():
    """A cloze card needs a sentence to blank out; without one there is no card."""
    cards = {c.kind: c for c in new_cards_for_word("w1")}
    cards[CardKind.production].stability = 20.0
    assert CardKind.cloze not in kinds_to_unlock(cards, has_enrichment=False)
    assert CardKind.cloze in kinds_to_unlock(cards, has_enrichment=True)


def test_kinds_do_not_unlock_twice():
    cards = {c.kind: c for c in new_cards_for_word("w1")}
    cards[CardKind.recognition].stability = 30.0
    cards[CardKind.production].stability = 30.0
    cards[CardKind.listening] = Card(word_id="w1", kind=CardKind.listening, due=utcnow())
    cards[CardKind.cloze] = Card(word_id="w1", kind=CardKind.cloze, due=utcnow())
    assert kinds_to_unlock(cards, has_enrichment=True) == []
