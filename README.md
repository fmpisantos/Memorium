# Memorium

A spaced-repetition companion for Duolingo, built to push past recognition into
actual fluency.

- **Nothing falls off the deck.** An FSRS scheduler keeps learned words in
  rotation at growing intervals instead of retiring them.
- **Both directions.** Every word becomes independently-scheduled recognition
  *and* production cards. Recognition is what Duolingo drills; production is
  what lets you reach for a word mid-sentence.
- **Words live in sentences.** Claude writes examples using only vocabulary you
  already know, so words transfer to speech instead of staying flashcard trivia.

Two pieces: a Python server that owns your deck and talks to Claude, and a
SwiftUI iOS app.

---

## Running the server

**Requires:** Python 3.12+, and the `claude` CLI on PATH
(`npm install -g @anthropic-ai/claude-code`).

```bash
cd server
uv venv --python 3.12
uv pip install -e ".[dev]"

cp .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(32))"   # paste into MEMORIUM_API_TOKEN
claude setup-token                                             # paste into CLAUDE_CODE_OAUTH_TOKEN

# See Configuration below: the Claude token has to reach the process
# environment, which starting uvicorn by hand does not do for you.
export CLAUDE_CODE_OAUTH_TOKEN=...

.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Check it:

```bash
curl -H "Authorization: Bearer $(grep '^MEMORIUM_API_TOKEN=' .env | cut -d= -f2-)" \
  localhost:8000/health
# {"status":"ok","db":"ok","claude_auth":"ok",...}
```

`claude_auth` is the field to watch — it reports whether the Claude credentials
are still good, which is the one thing that expires. See
[Configuration](#configuration) for what to do when it doesn't say `ok`.

Tests: `.venv/bin/python -m pytest` (43 tests).

### On a Raspberry Pi

`server/run.sh` does the venv creation, dependency install, and startup in one
step — useful where you don't want Docker. It still needs `.env` in place first.

```bash
cd server
./run.sh            # port 8000
./run.sh 9000       # or --port 9000; -H sets the bind address
```

First run installs into `.venv` and takes a few minutes; later runs start
immediately. `MEMORIUM_PORT` and `MEMORIUM_HOST` set the defaults if you'd
rather not pass flags. The script exports the Claude credentials out of `.env`
for you, and warns before startup if none are configured.

### Docker

`docker compose up -d` — the Dockerfile installs Node and the Claude CLI, runs
as a non-root user, and mounts `./data` for the SQLite file.

> Not yet verified: Docker isn't installed on the development machine, so the
> image has never been built. The local `uvicorn` path above is the tested one.

### A note on exposure

The shared bearer token is the **only** authentication. Keep the server on your
home network or Tailscale; don't publish it to the open internet without TLS in
front of it.

---

## Configuration

All server configuration lives in `server/.env` (start from
`server/.env.example`; `.env` is gitignored and must stay that way). The iOS app
has no config file — its two settings are entered on the setup screen.

### The two secrets

**`MEMORIUM_API_TOKEN`** — the shared bearer token the app sends on every
request, and the only authentication the server has. Generate a real one:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

The server refuses to answer any request while this is unset or still
`change-me`, returning a 500 that names the variable rather than quietly serving
your deck to anyone who asks. The **same string** goes into the app, in
Onboarding or Settings → *API token*; it's held in the iOS Keychain, not in
`UserDefaults` or the project.

**`CLAUDE_CODE_OAUTH_TOKEN`** — what the enrichment worker authenticates to
Claude with. Generate it with `claude setup-token`.

```bash
claude setup-token
```

This one behaves differently from every other variable here, and it's worth
knowing why. The Agent SDK works by spawning the `claude` CLI, and that CLI
reads its credentials from the **process environment** — while `.env` is parsed
by pydantic-settings, which only looks at `MEMORIUM_`-prefixed keys and never
writes to the environment. So putting the token in `.env` is sufficient only
where something loads the file into the environment:

| Start method | Reads `CLAUDE_CODE_OAUTH_TOKEN` from `.env`? |
|---|---|
| `./run.sh` | Yes — the script exports it |
| `docker compose up` | Yes — via `env_file:` |
| `uvicorn …` by hand | **No** — `export` it in your shell first |

Skip it entirely if the machine already has an interactive `claude` login
(`~/.claude`); the CLI will use that. `ANTHROPIC_API_KEY` works in its place and
is loaded the same way, if you'd rather bill an API key than a subscription.

The token expires. When it does, studying and scheduling carry on and the first
two grading tiers are on-device anyway, so the damage is that new words stop
getting example sentences and tier-3 grading is unavailable — reported, not
fatal. `/health` returns `"claude_auth": "unavailable"` with a `claude_detail`
string, and Settings shows it with the fix. Refresh with `claude setup-token`
and restart the server.

### Everything else

Optional; the defaults are what `.env.example` ships with.

| Variable | Default | What it does |
|---|---|---|
| `MEMORIUM_DATABASE_URL` | `sqlite:///./data/memorium.db` | Deck storage. The path is relative to `server/`, so start the server from there (`run.sh` and Docker handle it). |
| `MEMORIUM_CLAUDE_MODEL` | `claude-opus-5` | Model used for example sentences and tier-3 grading. |
| `MEMORIUM_ENRICHMENT_WORKERS` | `2` | Concurrent enrichment jobs. Each forks a CLI subprocess, so raising it on a Pi mostly buys swap. |
| `MEMORIUM_CLAUDE_TIMEOUT_SECONDS` | `180` | Per-call ceiling, so one wedged generation can't stall the queue. |
| `MEMORIUM_PORT` / `MEMORIUM_HOST` | `8000` / `0.0.0.0` | Read by `run.sh` only; equivalent to its `-p` / `-H` flags. |

**Study defaults** seed the learner profile the first time the database is
created, and are ignored on every later start — once the profile exists, the
app's Settings screen owns these values, and editing `.env` will look like it
does nothing.

| Variable | Default |
|---|---|
| `MEMORIUM_DEFAULT_SOURCE_LANG` | `en-US` |
| `MEMORIUM_DEFAULT_TARGET_LANG` | `es-ES` |
| `MEMORIUM_DEFAULT_DESIRED_RETENTION` | `0.90` |
| `MEMORIUM_DEFAULT_DAILY_NEW_LIMIT` | `10` |
| `MEMORIUM_DEFAULT_TIMEZONE` | `Europe/Lisbon` |

`DESIRED_RETENTION` is the FSRS target — the fraction of cards you want to
recall at review time. Raising it shortens intervals and grows your daily load;
0.90 is the usual starting point.

---

## Running the app

**Requires:** Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
cd ios
xcodegen generate
open Memorium.xcodeproj
```

Deployment target is iOS 26 (needed for on-device Foundation Models). Build and
run, then enter your server URL (e.g. `http://192.168.1.20:8000`) and the
`MEMORIUM_API_TOKEN` value from the server's `.env` on the setup screen — see
[Configuration](#configuration). The token goes to the Keychain, the URL to
`UserDefaults`; both can be changed later in Settings.

Tests: `xcodebuild test -project Memorium.xcodeproj -scheme Memorium \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (14 tests).

To skip onboarding while developing:

```bash
SIMCTL_CHILD_MEMORIUM_DEV_URL=http://localhost:8000 \
SIMCTL_CHILD_MEMORIUM_DEV_TOKEN=your-token \
SIMCTL_CHILD_MEMORIUM_DEV_TARGET=nb-NO \
xcrun simctl launch booted com.memorium.app
```

(DEBUG builds only.)

---

## How the study loop works

**Card types unlock as a word matures**, rather than all appearing at once —
four card types per word from day one would quadruple your review load and ask
you to type a word into a sentence before you could recognise it.

| Card | Appears |
|---|---|
| Recognition — target → your language | Immediately |
| Production — your language → target | Immediately |
| Listening — audio only, no text | Recognition stability ≥ 7 days |
| Cloze — type the word into a sentence | Production stability ≥ 14 days + examples generated |

**Speaking** is a toggle in Settings rather than a card type: it replaces the
answer input on any card whose answer is in the target language.

**Audio auto-plays only when the prompt is already in the target language.** On
a production or cloze card the prompt is in your own language and the target
audio *is* the answer — playing it up front would read the answer aloud. Those
cards stay silent until you reveal, and Repeat works throughout.

**Skipping never records a grade.** A skip is "not now", not "I forgot";
grading it would feed the scheduler a signal you never gave. Skipped cards come
back at the end of the session.

**Offline is expected.** Grades are written to an on-device outbox and flushed
when the network returns. Each carries a client-generated ID, so a retry after a
half-sent request can't double-schedule a card.

---

## Typed answers are graded in three tiers

1. **Normalised match** — instant, offline, free. Folds case, accents, and
   leading articles. Also folds `ø å æ ß ł` and friends, which Unicode won't
   decompose — someone without the Norwegian keyboard installed can't type them.
2. **Apple Foundation Models** — on-device, offline, free. Judges synonyms and
   near-misses. Skipped entirely on devices without Apple Intelligence.
3. **The server (Claude)** — last resort, needs a connection.

If every tier declines, the app says so rather than guessing "wrong" — a false
negative would punish a correct answer and corrupt your schedule.

---

## Adding words

- **One at a time** — the add sheet watches your clipboard, so copying a word in
  Duolingo and switching over offers it immediately, and stays open for a run of
  words.
- **From screenshots** — Deck → ＋ → Import. Vision reads every line with its
  bounding box and infers one- or two-column layout; overlapping shots of a
  scrolling list are deduplicated. Deliberately not a Duolingo-specific parser,
  since Practice Hub's layout varies by course and gets redesigned.

  **Everything lands on a review screen first.** OCR misreads diacritics, and one
  bad card poisons months of reviews.

---

## Layout

```
server/
  app/
    scheduler.py       FSRS wrapper + card-unlock rules
    enrichment.py      background worker pool
    llm/               ContentGenerator protocol + Agent SDK adapter
    routers/           health, words, study, enrich
  tests/               43 tests
ios/
  Memorium/
    Core/              API client, models, settings, Keychain, outbox
    Services/          TTS, speech recognition, grading, OCR
    Features/          Onboarding, Study, Deck, Settings
  MemoriumTests/       14 tests
```

All Claude calls sit behind the `ContentGenerator` protocol in
`server/app/llm/base.py`. Swapping the Agent SDK for a plain API-key client is
one new file, not a refactor.
