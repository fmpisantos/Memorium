import asyncio
import shutil

from fastapi import APIRouter, Depends
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_db
from app.models import EnrichmentStatus, Word

router = APIRouter(tags=["health"])

# Cache the CLI probe: it shells out, and /health may be polled by the app.
_cli_state: dict[str, object] = {"checked": False, "ok": False, "detail": ""}


async def _claude_cli_state() -> tuple[bool, str]:
    """Is the `claude` CLI present and authenticated?

    The Agent SDK spawns this CLI, and its auth token expires. Surfacing that
    here is the difference between the app showing 'reconnect Claude' and the
    user silently wondering why new words never get sentences.
    """
    if _cli_state["checked"]:
        return bool(_cli_state["ok"]), str(_cli_state["detail"])

    path = shutil.which("claude")
    if path is None:
        _cli_state.update(checked=True, ok=False, detail="claude CLI not found on PATH")
        return False, str(_cli_state["detail"])

    try:
        proc = await asyncio.create_subprocess_exec(
            path, "--version",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=20)
    except (TimeoutError, OSError) as exc:
        _cli_state.update(checked=True, ok=False, detail=f"CLI probe failed: {exc}")
        return False, str(_cli_state["detail"])

    if proc.returncode != 0:
        detail = (err or out).decode(errors="replace").strip()[:200] or "non-zero exit"
        _cli_state.update(checked=True, ok=False, detail=detail)
        return False, detail

    _cli_state.update(checked=True, ok=True, detail=out.decode(errors="replace").strip())
    return True, str(_cli_state["detail"])


@router.get("/health")
async def health(db: Session = Depends(get_db), settings: Settings = Depends(get_settings)):
    """Liveness, deliberately open.

    A container healthcheck and a `curl` from another machine both need to work
    before anyone has signed in, and the reply carries no deck content -- only
    whether the process, the database and the Claude credentials are alive.
    """
    try:
        db.execute(text("SELECT 1"))
        db_ok = True
        db_detail = "ok"
    except Exception as exc:  # pragma: no cover - only on a broken volume
        db_ok, db_detail = False, str(exc)[:200]

    cli_ok, cli_detail = await _claude_cli_state()

    queue_depth = db.scalar(
        select(func.count())
        .select_from(Word)
        .where(Word.enrichment_status.in_([EnrichmentStatus.pending, EnrichmentStatus.queued]))
    )
    failed = db.scalar(
        select(func.count())
        .select_from(Word)
        .where(Word.enrichment_status == EnrichmentStatus.failed)
    )

    return {
        "status": "ok" if (db_ok and cli_ok) else "degraded",
        "db": db_detail if not db_ok else "ok",
        "claude_auth": "ok" if cli_ok else "unavailable",
        "claude_detail": cli_detail,
        # Per task, since they no longer have to agree -- reporting only the
        # default would hide an override that is what's actually running.
        "claude_models": settings.task_models,
        "queue_depth": queue_depth or 0,
        "enrichment_failed": failed or 0,
    }
