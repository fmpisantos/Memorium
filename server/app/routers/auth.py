from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.deps import require_user

router = APIRouter(tags=["auth"])


class MeResponse(BaseModel):
    email: str


@router.get("/me", response_model=MeResponse)
def me(email: str = Depends(require_user)):
    """Whether this Google account may use this server.

    The app calls it once, straight after signing in, so that an address that
    is not on the allowlist is reported there and then -- naming the account,
    which is the one thing that makes the fix obvious -- rather than surfacing
    later as every screen mysteriously failing to load.
    """
    return MeResponse(email=email)
