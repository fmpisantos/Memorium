#!/usr/bin/env bash
# Run the Memorium server on a Raspberry Pi (or any Linux box).
#
#   ./run.sh                 # port 8000
#   ./run.sh 9000            # port 9000
#   ./run.sh --port 9000     # same
#   ./run.sh -p 9000 -H 127.0.0.1
#
# Creates the virtualenv and installs dependencies on first run; after that it
# just starts uvicorn.
set -euo pipefail

PORT="${MEMORIUM_PORT:-8000}"
HOST="${MEMORIUM_HOST:-0.0.0.0}"
RELOAD=""

usage() {
    cat <<'EOF'
Usage: ./run.sh [PORT] [options]

Options:
  -p, --port PORT   Port to listen on (default: 8000, or $MEMORIUM_PORT)
  -H, --host HOST   Address to bind (default: 0.0.0.0, or $MEMORIUM_HOST)
      --reload      Auto-restart on code changes (development only)
  -h, --help        Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port) PORT="${2:-}"; shift 2 ;;
        -H|--host) HOST="${2:-}"; shift 2 ;;
        --reload)  RELOAD="--reload"; shift ;;
        -h|--help) usage; exit 0 ;;
        [0-9]*)    PORT="$1"; shift ;;
        *)         echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$PORT" in
    ''|*[!0-9]*) echo "Port must be a number, got: '$PORT'" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Port out of range: $PORT" >&2
    exit 2
fi

# Run from the server directory: pydantic-settings reads .env relative to the
# working directory, and the default SQLite path is ./data/memorium.db.
cd "$(dirname "$(readlink -f "$0")")"

if [ ! -f .env ]; then
    echo "No .env found. Create one first:" >&2
    echo "  cp .env.example .env" >&2
    echo "  python3 -c 'import secrets; print(secrets.token_urlsafe(32))'  # MEMORIUM_API_TOKEN" >&2
    echo "  claude setup-token                                            # CLAUDE_CODE_OAUTH_TOKEN" >&2
    exit 1
fi

# pydantic-settings parses .env itself, but only for MEMORIUM_-prefixed fields,
# and it never writes to the process environment. The Agent SDK spawns the
# `claude` CLI, which authenticates from the environment -- so without this the
# Claude token in .env is read by nobody and enrichment fails while the server
# otherwise looks healthy. (docker-compose gets this for free via env_file.)
# Anything already exported wins, so systemd units can override .env.
for key in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; do
    [ -n "${!key:-}" ] && continue
    # Last assignment wins, matching how dotenv parsers read a duplicated key.
    value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$key=//p" .env | tail -n 1)"
    value="${value%$'\r'}"          # tolerate a CRLF .env
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in               # strip one layer of matching quotes
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    [ -n "$value" ] && export "$key=$value"
done
unset key value

PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
    echo "Python 3.12+ is required (found: $("$PYTHON" --version 2>&1 || echo none))." >&2
    echo "On Raspberry Pi OS: sudo apt install python3.12 python3.12-venv" >&2
    exit 1
fi

if [ ! -x .venv/bin/uvicorn ]; then
    echo "Setting up .venv (first run, this takes a few minutes on a Pi)..."
    [ -d .venv ] || "$PYTHON" -m venv .venv
    .venv/bin/pip install --upgrade pip
    .venv/bin/pip install -e .
fi

# The Agent SDK spawns the `claude` CLI. Without it, studying and scheduling
# still work -- only generated examples stop -- so this is a warning, not a stop.
if ! command -v claude >/dev/null 2>&1; then
    echo "Warning: 'claude' CLI not on PATH; enrichment will fail." >&2
    echo "         npm install -g @anthropic-ai/claude-code" >&2
elif [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] \
     && [ ! -d "$HOME/.claude" ]; then
    # The CLI can also authenticate from an interactive login, so only warn when
    # there is no sign of one either.
    echo "Warning: no Claude credentials found; enrichment will fail." >&2
    echo "         claude setup-token   # then set CLAUDE_CODE_OAUTH_TOKEN in .env" >&2
fi

mkdir -p data

echo "Memorium on http://$HOST:$PORT"
exec .venv/bin/uvicorn app.main:app --host "$HOST" --port "$PORT" $RELOAD
