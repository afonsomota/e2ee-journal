# models/database.py
#
# [Step 2] Server-side encryption at rest — see previous commit.
# [Step 3] Client-side encryption changes the schema: entries now have an
#          encrypted_blob column for ciphertext the server cannot read.

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
                id            TEXT PRIMARY KEY,
                username      TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                created_at    TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS entries (
                id             TEXT PRIMARY KEY,
                author_id      TEXT NOT NULL REFERENCES users(id),
                -- [Step 1/2] Plaintext content.
                content        TEXT,
                -- [Step 3] Encrypted body. Server cannot read this.
                encrypted_blob TEXT,
                created_at     TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
        """)
        await db.commit()
