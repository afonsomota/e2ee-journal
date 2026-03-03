# models/database.py
#
# [Step 4] Users table gains public_key and encrypted_private_key columns.
# The server stores the encrypted private key blob but cannot decrypt it.

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
                -- [Step 4] Public key stored openly; server can distribute it.
                public_key            TEXT,
                -- [Step 4] Private key encrypted with Argon2-derived key.
                --         Server stores the blob but cannot decrypt it.
                encrypted_private_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS entries (
                id             TEXT PRIMARY KEY,
                author_id      TEXT NOT NULL REFERENCES users(id),
                content        TEXT,
                encrypted_blob TEXT,
                created_at     TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
        """)
        await db.commit()
