FROM python:3.12-slim

# Node is required: the Claude Agent SDK works by spawning the `claude` CLI.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

COPY pyproject.toml ./
RUN pip install --no-cache-dir .

COPY app ./app

# The SQLite file lives here; mount it as a volume so the deck survives rebuilds.
VOLUME ["/srv/data"]
EXPOSE 8000

# Runs as non-root: the Agent SDK executes model-authored content, and there is
# no reason for that process to own the filesystem.
RUN useradd --create-home --uid 10001 memorium \
    && mkdir -p /srv/data && chown -R memorium:memorium /srv
USER memorium

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
