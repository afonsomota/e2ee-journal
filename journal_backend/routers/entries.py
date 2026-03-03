# routers/entries.py
#
# From Step 3 onward the server is essentially a dumb blob store.
# [Step 5] adds encrypted_content_key — the server stores it but cannot read it.

from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from typing import Optional
import uuid
from datetime import datetime

from models.database import get_db
from routers.auth import current_user

router = APIRouter()


class CreateEntryRequest(BaseModel):
    content: Optional[str] = None
    encrypted_blob: Optional[str] = None
    # [Step 5] Content key encrypted for the author.
    encrypted_content_key: Optional[str] = None


class UpdateEntryRequest(BaseModel):
    content: Optional[str] = None
    encrypted_blob: Optional[str] = None


def _serialize_entry(row: dict) -> dict:
    return {
        "id": row["id"],
        "author_id": row["author_id"],
        "author_username": row["author_username"],
        "content": row["content"] or "",
        "encrypted_blob": row["encrypted_blob"],
        "encrypted_content_key": row["encrypted_content_key"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


@router.post("")
async def create_entry(
    req: CreateEntryRequest,
    user=Depends(current_user),
    db=Depends(get_db),
):
    if not req.content and not req.encrypted_blob:
        raise HTTPException(
            status_code=400, detail="Content or encrypted_blob required"
        )

    entry_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()

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
        "created_at": now,
        "updated_at": now,
    }


@router.get("")
async def list_entries(user=Depends(current_user), db=Depends(get_db)):
    async with db.execute(
        """SELECT e.*, u.username as author_username
           FROM entries e
           JOIN users u ON u.id = e.author_id
           WHERE e.author_id = ?
           ORDER BY e.updated_at DESC""",
        (user["id"],),
    ) as cur:
        rows = [dict(r) for r in await cur.fetchall()]

    return [_serialize_entry(row) for row in rows]


@router.put("/{entry_id}")
async def update_entry(
    entry_id: str,
    req: UpdateEntryRequest,
    user=Depends(current_user),
    db=Depends(get_db),
):
    async with db.execute(
        "SELECT author_id FROM entries WHERE id = ?", (entry_id,)
    ) as cur:
        row = await cur.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if row["author_id"] != user["id"]:
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
    async with db.execute(
        "SELECT author_id FROM entries WHERE id = ?", (entry_id,)
    ) as cur:
        row = await cur.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if row["author_id"] != user["id"]:
        raise HTTPException(status_code=403, detail="Not your entry")

    await db.execute("DELETE FROM entries WHERE id = ?", (entry_id,))
    await db.commit()
    return {"ok": True}
