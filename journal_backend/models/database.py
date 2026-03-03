# models/database.py
#
# Schema notes:
#   users.encrypted_private_key — opaque blob to the server. [Step 4]
#   users.public_key            — distributed openly. [Step 4]
#   entries.content             — used in Steps 1 and 2 only.
#   entries.encrypted_blob      — ciphertext of entry body. [Step 3+]
#   entries.encrypted_content_key — content key encrypted for the author. [Step 5+]

import aiosqlite
import os

DB_PATH = os.getenv("DB_PATH", "journal.db")


async def get_db():
    """Dependency: yields a database connection per request."""
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        yield db


async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id                    TEXT PRIMARY KEY,
                username              TEXT UNIQUE NOT NULL,
                password_hash         TEXT NOT NULL,
                public_key            TEXT,
                encrypted_private_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS entries (
                id                    TEXT PRIMARY KEY,
                author_id             TEXT NOT NULL REFERENCES users(id),
                content               TEXT,
                encrypted_blob        TEXT,
                -- [Step 5] Content key encrypted for the author.
                encrypted_content_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
        """)
        await db.commit()
