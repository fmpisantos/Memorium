import secrets

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_db
from app.models import Profile


def require_token(
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> None:
    """Single shared bearer token guarding every route.

    This is the only authentication boundary on the server, so it is compared
    in constant time and a placeholder value is refused outright.
    """
    if settings.api_token in ("", "change-me"):
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "MEMORIUM_API_TOKEN is unset. Refusing to serve with a default token.",
        )
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "Missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    presented = authorization.removeprefix("Bearer ").strip()
    if not secrets.compare_digest(presented, settings.api_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")


def ensure_profile(db: Session) -> Profile:
    """Fetch the single learner profile, creating it from defaults if absent.

    Called at startup as well as per-request. It used to be created lazily by
    the request dependency alone, which meant background enrichment could run
    before any route had touched it and find no profile at all.
    """
    profile = db.scalar(select(Profile).where(Profile.id == 1))
    if profile is not None:
        return profile

    s = get_settings()
    profile = Profile(
        id=1,
        source_lang=s.default_source_lang,
        target_lang=s.default_target_lang,
        desired_retention=s.default_desired_retention,
        daily_new_limit=s.default_daily_new_limit,
        timezone=s.default_timezone,
    )
    db.add(profile)
    db.commit()
    db.refresh(profile)
    return profile


def get_profile(db: Session = Depends(get_db)) -> Profile:
    return ensure_profile(db)
