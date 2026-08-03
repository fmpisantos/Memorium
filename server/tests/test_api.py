"""Endpoint behaviour, with emphasis on the offline-outbox contract."""

import uuid


def add_word(client, lemma="perro", gloss="dog"):
    r = client.post("/words", json={"lemma": lemma, "native_gloss": gloss})
    assert r.status_code == 201, r.text
    return r.json()


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
def test_every_route_requires_the_token(client):
    for path in ("/health", "/words", "/study/queue", "/profile"):
        assert client.get(path, headers={"Authorization": ""}).status_code == 401, path


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


def test_renaming_a_word_invalidates_its_enrichment(client):
    """Sentences generated for 'perro' do not describe 'gato'."""
    word = add_word(client)
    r = client.patch(f"/words/{word['id']}", json={"lemma": "gato"})
    assert r.status_code == 200
    assert r.json()["enrichment_status"] == "pending"


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


def test_daily_new_limit_is_counted_in_words(client):
    assert client.patch("/profile", json={"daily_new_limit": 2}).status_code == 200

    for lemma in ("uno", "dos", "tres", "cuatro"):
        add_word(client, lemma, lemma)

    q = client.get("/study/queue").json()
    assert len({c["word_id"] for c in q["cards"]}) == 2
    assert q["new_remaining_today"] == 2


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
