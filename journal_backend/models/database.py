# models/database.py
#
# SQLite via aiosqlite for simplicity.  In production: PostgreSQL + asyncpg.
#
# Schema notes:
#
#  users.encrypted_private_key — opaque blob to the server.
#  users.public_key             — distributed openly.
#
#  entries.encrypted_blob       — ciphertext of entry body.
#  entries.encrypted_content_key— content key encrypted for the author.
#
#  shares                       — one row per (entry, recipient).
#  shares.encrypted_content_key — content key encrypted for the recipient.

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
                encrypted_content_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS shares (
                id                    TEXT PRIMARY KEY,
                entry_id              TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                recipient_id          TEXT NOT NULL REFERENCES users(id),
                encrypted_content_key TEXT NOT NULL,
                created_at            TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(entry_id, recipient_id)
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
            CREATE INDEX IF NOT EXISTS idx_shares_recipient ON shares(recipient_id);
            CREATE INDEX IF NOT EXISTS idx_shares_entry ON shares(entry_id);
        """)
        await db.commit()
