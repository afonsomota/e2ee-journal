# routers/entries.py

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from log import get_logger
from models.database import get_db
from routers.auth import current_user

router = APIRouter()
logger = get_logger(__name__)


# ── Schemas ────────────────────────────────────────────────────────────────────


class CreateEntryRequest(BaseModel):
    content: str | None = None
    encrypted_blob: str | None = None
    encrypted_content_key: str | None = None


class UpdateEntryRequest(BaseModel):
    content: str | None = None
    encrypted_blob: str | None = None


class ShareRequest(BaseModel):
    recipient_username: str
    encrypted_content_key: str | None = None


# ── Helpers ────────────────────────────────────────────────────────────────────


def _serialize_entry(
    row: dict, shared_with: list[str] | None = None, shared_eck: str | None = None
) -> dict:
    return {
        "id": row["id"],
        "author_id": row["author_id"],
        "author_username": row["author_username"],
        "content": row["content"] or "",
        "encrypted_blob": row["encrypted_blob"],
        "encrypted_content_key": row["encrypted_content_key"],
        "shared_encrypted_content_key": shared_eck,
        "shared_with": shared_with or [],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


# ── Routes ─────────────────────────────────────────────────────────────────────


@router.post("")
async def create_entry(
    req: CreateEntryRequest,
    user=Depends(current_user),
    db=Depends(get_db),
):
    if not req.content and not req.encrypted_blob:
        raise HTTPException(status_code=400, detail="Content or encrypted_blob required")

    entry_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    logger.info(f"Creating entry {entry_id} for user {user['username']}")

    await db.execute(
        """INSERT INTO entries
           (id, author_id, content, encrypted_blob, encrypted_content_key,
            created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (
            entry_id,
            user["id"],
            req.content,
            req.encrypted_blob,
            req.encrypted_content_key,
            now,
            now,
        ),
    )
    await db.commit()

    return {
        "id": entry_id,
        "author_id": user["id"],
        "author_username": user["username"],
        "content": req.content or "",
        "encrypted_blob": req.encrypted_blob,
        "encrypted_content_key": req.encrypted_content_key,
        "shared_encrypted_content_key": None,
        "shared_with": [],
        "created_at": now,
        "updated_at": now,
    }


@router.get("")
async def list_entries(user=Depends(current_user), db=Depends(get_db)):
    """Return the current user's own entries with share lists."""
    logger.debug(f"Listing entries for user {user['username']}")
    async with db.execute(
        """SELECT e.*, u.username as author_username
           FROM entries e
           JOIN users u ON u.id = e.author_id
           WHERE e.author_id = ?
           ORDER BY e.updated_at DESC""",
        (user["id"],),
    ) as cur:
        rows = [dict(r) for r in await cur.fetchall()]

    # Enrich with shared_with lists.
    result = []
    for row in rows:
        async with db.execute(
            """SELECT u.username FROM shares s
               JOIN users u ON u.id = s.recipient_id
               WHERE s.entry_id = ?""",
            (row["id"],),
        ) as cur:
            shared_with = [r["username"] for r in await cur.fetchall()]
        result.append(_serialize_entry(row, shared_with=shared_with))

    return result


@router.get("/shared-with-me")
async def list_shared_with_me(user=Depends(current_user), db=Depends(get_db)):
    """
    Return entries shared with the current user.
    Returns the encrypted_content_key encrypted FOR THIS USER,
    not the one stored with the entry (which is for the author).
    """
    logger.debug(f"Listing shared entries for user {user['username']}")
    async with db.execute(
        """SELECT e.*, u.username as author_username,
                  s.encrypted_content_key as shared_eck
           FROM entries e
           JOIN users u ON u.id = e.author_id
           JOIN shares s ON s.entry_id = e.id
           WHERE s.recipient_id = ?
           ORDER BY e.updated_at DESC""",
        (user["id"],),
    ) as cur:
        rows = [dict(r) for r in await cur.fetchall()]

    return [_serialize_entry(row, shared_eck=row["shared_eck"]) for row in rows]


@router.put("/{entry_id}")
async def update_entry(
    entry_id: str,
    req: UpdateEntryRequest,
    user=Depends(current_user),
    db=Depends(get_db),
):
    logger.info(f"Updating entry {entry_id} for user {user['username']}")
    async with db.execute("SELECT author_id FROM entries WHERE id = ?", (entry_id,)) as cur:
        row = await cur.fetchone()

    if row is None:
        logger.warning(f"Update failed: entry {entry_id} not found")
        raise HTTPException(status_code=404, detail="Entry not found")
    if row["author_id"] != user["id"]:
        logger.warning(f"Update failed: user {user['username']} does not own entry {entry_id}")
        raise HTTPException(status_code=403, detail="Not your entry")

    now = datetime.utcnow().isoformat()
    await db.execute(
        """UPDATE entries
           SET content = COALESCE(?, content),
               encrypted_blob = COALESCE(?, encrypted_blob),
               updated_at = ?
           WHERE id = ?""",
        (req.content, req.encrypted_blob, now, entry_id),
    )
    await db.commit()
    return {"ok": True}


@router.delete("/{entry_id}")
async def delete_entry(
    entry_id: str,
    user=Depends(current_user),
    db=Depends(get_db),
):
    logger.info(f"Deleting entry {entry_id} for user {user['username']}")
    async with db.execute("SELECT author_id FROM entries WHERE id = ?", (entry_id,)) as cur:
        row = await cur.fetchone()

    if row is None:
        logger.warning(f"Delete failed: entry {entry_id} not found")
        raise HTTPException(status_code=404, detail="Entry not found")
    if row["author_id"] != user["id"]:
        logger.warning(f"Delete failed: user {user['username']} does not own entry {entry_id}")
        raise HTTPException(status_code=403, detail="Not your entry")

    # CASCADE deletes shares too.
    await db.execute("DELETE FROM entries WHERE id = ?", (entry_id,))
    await db.commit()
    return {"ok": True}


@router.post("/{entry_id}/share")
async def share_entry(
    entry_id: str,
    req: ShareRequest,
    user=Depends(current_user),
    db=Depends(get_db),
):
    """
    Store a copy of the content key encrypted for the recipient.
    The server just stores a mapping from (entry, recipient) to an encrypted
    key blob.  It cannot verify correctness because it can't read any of the
    underlying keys.
    """
    logger.info(f"Sharing entry {entry_id} with {req.recipient_username} (by {user['username']})")
    # Verify caller owns the entry.
    async with db.execute("SELECT author_id FROM entries WHERE id = ?", (entry_id,)) as cur:
        row = await cur.fetchone()

    if row is None:
        logger.warning(f"Share failed: entry {entry_id} not found")
        raise HTTPException(status_code=404, detail="Entry not found")
    if row["author_id"] != user["id"]:
        logger.warning(f"Share failed: user {user['username']} does not own entry {entry_id}")
        raise HTTPException(status_code=403, detail="Not your entry")

    # Resolve recipient.
    async with db.execute(
        "SELECT id FROM users WHERE username = ?", (req.recipient_username,)
    ) as cur:
        recipient = await cur.fetchone()

    if recipient is None:
        logger.warning(f"Share failed: recipient user '{req.recipient_username}' not found")
        raise HTTPException(status_code=404, detail="Recipient user not found")

    share_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()

    # Upsert: re-sharing with the same user updates the key blob.
    await db.execute(
        """INSERT INTO shares (id, entry_id, recipient_id, encrypted_content_key, created_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(entry_id, recipient_id)
           DO UPDATE SET encrypted_content_key = excluded.encrypted_content_key""",
        (share_id, entry_id, recipient["id"], req.encrypted_content_key, now),
    )
    await db.commit()
    return {"ok": True, "shared_with": req.recipient_username}


@router.delete("/{entry_id}/share/{username}")
async def revoke_share(
    entry_id: str,
    username: str,
    user=Depends(current_user),
    db=Depends(get_db),
):
    """
    Revoke access by deleting the key blob for the recipient.
    They can no longer fetch a key to decrypt the entry.
    Note: if they've cached the decrypted content locally, this won't help.
    True revocation requires re-encryption.
    """
    logger.info(f"Revoking share of entry {entry_id} from {username} (by {user['username']})")
    async with db.execute("SELECT id FROM users WHERE username = ?", (username,)) as cur:
        recipient = await cur.fetchone()

    if recipient:
        await db.execute(
            "DELETE FROM shares WHERE entry_id = ? AND recipient_id = ?",
            (entry_id, recipient["id"]),
        )
        await db.commit()
    return {"ok": True}
