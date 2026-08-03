from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import InvalidIdentity, is_allowed, verify_google_id_token
from app.config import Settings, get_settings
from app.db import get_db
from app.models import Profile


def require_user(
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> str:
    """The authentication boundary: a verified, allowlisted Google account.

    Sync on purpose. FastAPI runs sync dependencies in its threadpool, which
    keeps the one blocking call in here -- fetching Google's signing keys, once
    an hour -- off the event loop.

    Returns the caller's email address, so a route that wants to know who is
    asking can simply depend on it.
    """
    if not settings.google_client_id:
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "MEMORIUM_GOOGLE_CLIENT_ID is unset. Refusing to serve without a way to "
            "check who is calling.",
        )
    allowed = settings.allowed_email_set
    if not allowed:
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "MEMORIUM_ALLOWED_EMAILS is empty. Refusing to serve with nobody allowed.",
        )

    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "Missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        claims = verify_google_id_token(
            authorization.removeprefix("Bearer ").strip(), settings.google_client_id
        )
    except InvalidIdentity as exc:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    email = claims["email"]
    if not is_allowed(email, allowed):
        # 403, not 404 or a vague 401: the sign-in worked and retrying it will
        # not help. The app says so instead of looping the user through Google.
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            f"{email} is not on this server's allowed list.",
        )
    return email


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
