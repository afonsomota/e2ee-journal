# routers/users.py
#
# Public key distribution.
#
# BLOG NOTE: This endpoint is the trust boundary.
# A malicious server could return a different public key than the one the user
# registered with.  The client would then encrypt the content key for the
# attacker, who could decrypt it.
#
# TODO: Mitigations (not implemented here):
#   • Key transparency log: every public key upload is appended to an
#     append-only audit log.  Anyone can verify a key hasn't been swapped.
#   • Out-of-band fingerprint verification: users compare key fingerprints
#     via a side channel (e.g. QR code in person, Signal safety numbers).
#   • TOFU (Trust On First Use): client remembers the first key seen for a
#     username and warns if it changes.

from fastapi import APIRouter, Depends, HTTPException

from log import get_logger
from models.database import get_db
from routers.auth import current_user

router = APIRouter()
logger = get_logger(__name__)


@router.get("/{username}/public-key")
async def get_public_key(
    username: str,
    user=Depends(current_user),  # must be authenticated to look up keys
    db=Depends(get_db),
) -> dict[str, str]:
    """
    Return a user's public key.
    Used by the sharing flow: Alice fetches Bob's public key before
    re-encrypting the content key for him.
    """
    logger.debug(f"Fetching public key for user {username} (requested by {user['username']})")
    async with db.execute(
        "SELECT username, public_key FROM users WHERE username = ?", (username,)
    ) as cur:
        row = await cur.fetchone()

    if row is None:
        logger.warning(f"Public key lookup failed: user '{username}' not found")
        raise HTTPException(status_code=404, detail="User not found")

    if row["public_key"] is None:
        logger.warning(f"Public key lookup failed: user '{username}' has no public key")
        raise HTTPException(
            status_code=404,
            detail="User has no public key",
        )

    return {
        "username": row["username"],
        "public_key": row["public_key"],
    }


@router.get("/me")
async def get_me(user=Depends(current_user)) -> dict:
    logger.debug(f"Fetching profile for user {user['username']}")
    return {
        "id": user["id"],
        "username": user["username"],
        "public_key": user["public_key"],
    }
