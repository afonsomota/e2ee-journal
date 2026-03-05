# routers/users.py
#
# Public key distribution.

from fastapi import APIRouter, HTTPException, Depends
from models.database import get_db
from routers.auth import current_user

router = APIRouter()


@router.get("/{username}/public-key")
async def get_public_key(
    username: str,
    user=Depends(current_user),  # must be authenticated to look up keys
    db=Depends(get_db),
):
    """
    Return a user's public key.
    Used by the sharing flow: Alice fetches Bob's public key before
    re-encrypting the content key for him.
    """
    async with db.execute(
        "SELECT username, public_key FROM users WHERE username = ?", (username,)
    ) as cur:
        row = await cur.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail="User not found")

    if row["public_key"] is None:
        raise HTTPException(
            status_code=404,
            detail="User has no public key",
        )

    return {
        "username": row["username"],
        "public_key": row["public_key"],
    }


@router.get("/me")
async def get_me(user=Depends(current_user)):
    return {
        "id": user["id"],
        "username": user["username"],
        "public_key": user["public_key"],
    }
