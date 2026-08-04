"""Endpoint behaviour, with emphasis on the offline-outbox contract."""

import uuid


def add_word(client, lemma="perro", gloss="dog"):
    r = client.post("/words", json={"lemma": lemma, "native_gloss": gloss})
    assert r.status_code == 201, r.text
    return r.json()


def grade(client, card_id, rating=3):
    r = client.post(
        "/study/grade",
        json={
            "grades": [
                {"client_grade_id": str(uuid.uuid4()), "card_id": card_id, "rating": rating}
            ]
        },
    )
    assert r.status_code == 200, r.text
    return r.json()["results"][0]


def study_everything(client, **params):
    """Work through a queue the way the app does, and hand back what was in it."""
    cards = client.get("/study/queue", params=params).json()["cards"]
    for card in cards:
        grade(client, card["card_id"])
    return cards


# Auth lives in test_auth.py: every route is checked there, against tokens
# signed with a test key. /health is deliberately open.


# --------------------------------------------------------------------------- #
# Deck
# --------------------------------------------------------------------------- #
def test_new_word_gets_both_direction_cards(client):
    word = add_word(client)
    kinds = sorted(c["kind"] for c in word["cards"])
    assert kinds == ["production", "recognition"]


def test_duplicate_lemma_is_rejected(client):
    add_word(client)
    assert client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).status_code == 409


def test_lemma_is_whitespace_normalised(client):
    word = add_word(client, lemma="  el   gato  ")
    assert word["lemma"] == "el gato"


def test_the_same_word_in_another_case_is_the_same_word(client):
    """The translator hands back 'Perro' for a word typed as 'perro'."""
    add_word(client)
    r = client.post("/words", json={"lemma": "Perro", "native_gloss": "dog"})
    assert r.status_code == 409


def test_case_folding_reaches_past_ascii(client):
    """SQLite's own lower() would file Öl and öl as two words."""
    add_word(client, lemma="Öl", gloss="oil")
    assert client.post("/words", json={"lemma": "öl", "native_gloss": "oil"}).status_code == 409


def test_a_word_keeps_the_case_it_was_typed_in(client):
    """German nouns are capitalised; deduplicating must not lowercase the deck."""
    assert add_word(client, lemma="Öl", gloss="oil")["lemma"] == "Öl"


def test_batch_skips_duplicates_instead_of_failing_the_whole_import(client):
    """One repeat in a 200-word OCR import must not discard the other 199."""
    add_word(client, "perro", "dog")
    r = client.post(
        "/words/batch",
        json={
            "words": [
                {"lemma": "perro", "native_gloss": "dog"},
                {"lemma": "gato", "native_gloss": "cat"},
                {"lemma": "casa", "native_gloss": "house"},
            ]
        },
    )
    assert r.status_code == 201
    body = r.json()
    assert sorted(w["lemma"] for w in body["created"]) == ["casa", "gato"]
    assert "perro" in body["duplicates"]


def test_batch_collapses_a_word_it_lists_twice(client):
    """Overlapping screenshots show the same word twice, in whatever case."""
    r = client.post(
        "/words/batch",
        json={
            "words": [
                {"lemma": "gato", "native_gloss": "cat"},
                {"lemma": "Gato", "native_gloss": "cat"},
            ]
        },
    )
    assert r.status_code == 201
    body = r.json()
    # One word, spelled the way it was first sent, and nothing to report: the
    # learner listed it twice, the deck did not already have it.
    assert [w["lemma"] for w in body["created"]] == ["gato"]
    assert body["duplicates"] == []


def test_batch_reports_a_case_variant_of_a_word_already_in_the_deck(client):
    add_word(client, "perro", "dog")
    body = client.post(
        "/words/batch", json={"words": [{"lemma": "Perro", "native_gloss": "dog"}]}
    ).json()
    assert body["created"] == []
    # Reported as it was sent, so it can be found in the list on screen.
    assert body["duplicates"] == ["Perro"]


def test_renaming_a_word_invalidates_its_enrichment(client):
    """Sentences generated for 'perro' do not describe 'gato'."""
    word = add_word(client)
    r = client.patch(f"/words/{word['id']}", json={"lemma": "gato"})
    assert r.status_code == 200
    assert r.json()["enrichment_status"] == "pending"


def test_renaming_onto_another_word_is_refused_whatever_the_case(client):
    add_word(client, "perro", "dog")
    gato = add_word(client, "gato", "cat")
    assert client.patch(f"/words/{gato['id']}", json={"lemma": "Perro"}).status_code == 409


def test_a_word_can_be_recased_into_itself(client):
    """Fixing 'perro' to 'Perro' is a rename, not a clash with itself."""
    word = add_word(client)
    r = client.patch(f"/words/{word['id']}", json={"lemma": "Perro"})
    assert r.status_code == 200
    assert r.json()["lemma"] == "Perro"
    # And the deck still refuses the word it now holds.
    assert client.post("/words", json={"lemma": "perro", "native_gloss": "dog"}).status_code == 409


def test_delete_cascades_to_cards(client, db):
    from app.models import Card

    word = add_word(client)
    assert client.delete(f"/words/{word['id']}").status_code == 204
    assert db.query(Card).filter(Card.word_id == word["id"]).count() == 0


# --------------------------------------------------------------------------- #
# Study queue
# --------------------------------------------------------------------------- #
def test_queue_serves_new_cards_with_correct_audio_rules(client):
    add_word(client)
    q = client.get("/study/queue").json()

    by_kind = {c["kind"]: c for c in q["cards"]}
    recog, prod = by_kind["recognition"], by_kind["production"]

    assert recog["prompt"] == "perro" and recog["answer"] == "dog"
    assert recog["audio_autoplay"] is True

    assert prod["prompt"] == "dog" and prod["answer"] == "perro"
    # The whole point of the correction: this would speak the answer.
    assert prod["audio_autoplay"] is False
    # Audio is still available on demand for the Repeat button after reveal.
    assert prod["speech_text"] == "perro"


def test_queue_never_puts_a_word_next_to_its_mirror_card(client):
    """"hei -> hi" followed by "hi -> hei" hands you the answer you just read."""
    for lemma, gloss in (("hei", "hi"), ("takk", "thanks"), ("ja", "yes")):
        add_word(client, lemma, gloss)

    cards = client.get("/study/queue").json()["cards"]
    assert len(cards) == 6

    word_ids = [c["word_id"] for c in cards]
    assert all(a != b for a, b in zip(word_ids, word_ids[1:], strict=False))


def test_sibling_spacing_degrades_instead_of_dropping_cards(client):
    """A one-word queue cannot be spaced. It still has to serve both cards."""
    add_word(client)
    cards = client.get("/study/queue").json()["cards"]
    assert sorted(c["kind"] for c in cards) == ["production", "recognition"]


def test_daily_new_limit_is_counted_in_words(client):
    assert client.patch("/profile", json={"daily_new_limit": 2}).status_code == 200

    for lemma in ("uno", "dos", "tres", "cuatro"):
        add_word(client, lemma, lemma)

    q = client.get("/study/queue").json()
    assert len({c["word_id"] for c in q["cards"]}) == 2
    assert q["new_remaining_today"] == 2


# --------------------------------------------------------------------------- #
# Extra rounds: studying past the daily goal
# --------------------------------------------------------------------------- #
def test_extra_round_hands_out_more_new_words_once_the_day_is_spent(client):
    """The daily limit paces new words. It is not a cap on wanting to study."""
    client.patch("/profile", json={"daily_new_limit": 2})
    for lemma in ("uno", "dos", "tres", "cuatro"):
        add_word(client, lemma, lemma)

    done = study_everything(client)
    assert len({c["word_id"] for c in done}) == 2

    # The day's queue is finished and offers nothing more...
    day = client.get("/study/queue").json()
    assert day["cards"] == []
    assert day["new_remaining_today"] == 0

    # ...but asking for another round gets the next two words anyway.
    extra = client.get("/study/queue", params={"extra": True}).json()
    assert extra["extra"] is True
    assert extra["new_count"] == 4  # two words, both their cards
    assert {c["lemma"] for c in extra["cards"] if c["is_new"]} == {"tres", "cuatro"}
    # The round is topped up with the two words already learned, as practice.
    assert {c["lemma"] for c in extra["cards"] if c["is_practice"]} == {"uno", "dos"}


def test_extra_round_falls_back_to_words_you_already_know(client):
    """With no new words left, an extra round is still never empty."""
    for lemma in ("uno", "dos", "tres"):
        add_word(client, lemma, lemma)
    study_everything(client)

    extra = client.get("/study/queue", params={"extra": True}).json()
    assert extra["new_count"] == 0
    assert extra["practice_count"] == 6
    assert all(c["is_practice"] for c in extra["cards"])


def test_extra_rounds_do_not_come_in_a_memorisable_order(client):
    """A fixed order is one you learn, and then you are reciting, not recalling."""
    for i in range(12):
        add_word(client, f"palabra{i}", f"word{i}")
    study_everything(client, limit=500)

    first = [c["card_id"] for c in client.get("/study/queue", params={"extra": True}).json()["cards"]]
    second = [
        c["card_id"] for c in client.get("/study/queue", params={"extra": True}).json()["cards"]
    ]
    assert first and first != second


def test_extra_round_prefers_what_you_have_not_just_answered(client, db):
    """Re-asking a word from five minutes ago tests the last five minutes."""
    from datetime import timedelta

    from app.models import Card

    add_word(client, "reciente", "recent")
    old = add_word(client, "antigua", "old")
    study_everything(client)

    # Move one word's review back beyond the cooldown, as the clock would.
    for card in db.query(Card).filter(Card.word_id == old["id"]):
        card.last_review = card.last_review - timedelta(hours=3)
        db.add(card)
    db.commit()

    extra = client.get("/study/queue", params={"extra": True, "limit": 2}).json()
    assert {c["lemma"] for c in extra["cards"]} == {"antigua"}


def test_practising_early_is_logged_but_leaves_the_schedule_alone(client, db):
    """The reward for practising more must not be being tested more often."""
    from app.models import Card, ReviewLog

    word = add_word(client)
    card_id = word["cards"][0]["id"]
    grade(client, card_id)

    db.expire_all()
    card = db.get(Card, card_id)
    due_before, reps_before, stability_before = card.due, card.reps, card.stability
    assert due_before > card.last_review  # It is genuinely not due yet.

    result = grade(client, card_id)

    assert result["accepted"] is True
    assert result["practice"] is True
    db.expire_all()
    card = db.get(Card, card_id)
    assert (card.due, card.reps, card.stability) == (due_before, reps_before, stability_before)

    # It still happened, and the log says so.
    logs = db.query(ReviewLog).filter(ReviewLog.card_id == card_id).all()
    assert [entry.practice for entry in logs] == [False, True]


def test_a_card_that_is_actually_due_still_reschedules_in_an_extra_round(client, db):
    """Practice is decided by the card's due date, not by which round it came from."""
    from datetime import timedelta

    from app.models import Card

    word = add_word(client)
    card_id = word["cards"][0]["id"]
    grade(client, card_id)

    card = db.get(Card, card_id)
    card.due = card.due - timedelta(days=999)
    db.add(card)
    db.commit()
    due_before = card.due

    result = grade(client, card_id)
    assert result["practice"] is False
    db.expire_all()
    assert db.get(Card, card_id).due > due_before


# --------------------------------------------------------------------------- #
# Grading + the offline outbox contract
# --------------------------------------------------------------------------- #
def test_grading_schedules_the_card_forward(client):
    word = add_word(client)
    card_id = word["cards"][0]["id"]
    r = client.post(
        "/study/grade",
        json={"grades": [{"client_grade_id": str(uuid.uuid4()), "card_id": card_id, "rating": 3}]},
    )
    res = r.json()["results"][0]
    assert res["accepted"] and not res["duplicate"]
    assert res["interval_days"] > 0


def test_replayed_grade_does_not_double_schedule(client, db):
    """The app flushes its outbox; a retry after a dropped connection is normal.

    A replay must report state, not review the card a second time -- otherwise
    a flaky train ride quietly corrupts the schedule.
    """
    from app.models import Card, ReviewLog

    word = add_word(client)
    card_id = word["cards"][0]["id"]
    grade = {"client_grade_id": str(uuid.uuid4()), "card_id": card_id, "rating": 3}

    first = client.post("/study/grade", json={"grades": [grade]}).json()["results"][0]
    due_after_first = db.get(Card, card_id).due
    reps_after_first = db.get(Card, card_id).reps

    second = client.post("/study/grade", json={"grades": [grade]}).json()["results"][0]

    assert first["duplicate"] is False
    assert second["duplicate"] is True
    db.expire_all()
    assert db.get(Card, card_id).reps == reps_after_first == 1
    assert db.get(Card, card_id).due == due_after_first
    assert db.query(ReviewLog).filter(ReviewLog.card_id == card_id).count() == 1


def test_batch_of_grades_applies_all_of_them(client):
    word = add_word(client)
    grades = [
        {"client_grade_id": str(uuid.uuid4()), "card_id": c["id"], "rating": 3}
        for c in word["cards"]
    ]
    results = client.post("/study/grade", json={"grades": grades}).json()["results"]
    assert len(results) == 2
    assert all(r["accepted"] for r in results)


def test_grade_for_unknown_card_is_reported_not_fatal(client):
    """A stale outbox entry for a deleted word must not block the flush."""
    word = add_word(client)
    good = {"client_grade_id": str(uuid.uuid4()), "card_id": word["cards"][0]["id"], "rating": 3}
    bad = {"client_grade_id": str(uuid.uuid4()), "card_id": "does-not-exist", "rating": 3}

    results = client.post("/study/grade", json={"grades": [bad, good]}).json()["results"]
    by_card = {r["card_id"]: r for r in results}
    assert by_card["does-not-exist"]["accepted"] is False
    assert by_card[word["cards"][0]["id"]]["accepted"] is True


def test_reviewed_card_leaves_the_new_queue_and_returns_when_due(client, db):
    from datetime import timedelta

    from app.models import Card

    word = add_word(client)
    card_id = word["cards"][0]["id"]
    client.post(
        "/study/grade",
        json={"grades": [{"client_grade_id": str(uuid.uuid4()), "card_id": card_id, "rating": 3}]},
    )

    ids_now = {c["card_id"] for c in client.get("/study/queue").json()["cards"]}
    assert card_id not in ids_now

    # Fast-forward past its due date: it must come back.
    card = db.get(Card, card_id)
    card.due = card.due - timedelta(days=999)
    db.add(card)
    db.commit()

    q = client.get("/study/queue").json()
    assert card_id in {c["card_id"] for c in q["cards"]}
    assert q["due_count"] >= 1
