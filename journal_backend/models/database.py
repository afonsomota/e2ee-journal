# models/database.py
#
# SQLite via aiosqlite for simplicity.  In production: PostgreSQL + asyncpg.
#
# Schema notes:
#
#  users.encrypted_private_key — opaque blob to the server. [Step4]
#  users.public_key             — distributed openly. [Step4]
#
#  entries.content              — used in Steps 1 and 2 only.
#  entries.encrypted_blob       — ciphertext of entry body. [Step3+]
#  entries.encrypted_content_key— content key encrypted for the author. [Step5+]
#
#  shares                       — one row per (entry, recipient). [Step6]
#  shares.encrypted_content_key — content key encrypted for the recipient.
#
# BLOG NOTE (Step 2): Server-side encryption at rest would be implemented at
# the database/storage layer (e.g. SQLCipher, AWS RDS encryption).  The schema
# is identical; the difference is the database engine transparently encrypts
# the file on disk.  The server can still read the plaintext at query time.

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
                -- [Step4] Public key stored openly; server can distribute it.
                public_key            TEXT,
                -- [Step4] Private key encrypted with Argon2-derived key.
                --         Server stores the blob but cannot decrypt it.
                encrypted_private_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS entries (
                id                    TEXT PRIMARY KEY,
                author_id             TEXT NOT NULL REFERENCES users(id),
                -- [Step1/2] Plaintext content — used only in Steps 1 and 2.
                content               TEXT,
                -- [Step3+] Encrypted body. Server cannot read this.
                encrypted_blob        TEXT,
                -- [Step5+] Content key encrypted for the author.
                --          Server cannot read this either.
                encrypted_content_key TEXT,
                created_at            TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at            TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS shares (
                id                    TEXT PRIMARY KEY,
                entry_id              TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                recipient_id          TEXT NOT NULL REFERENCES users(id),
                -- [Step6] Content key re-encrypted for the recipient.
                --         Neither the server nor any other user can read this.
                encrypted_content_key TEXT NOT NULL,
                created_at            TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(entry_id, recipient_id)
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
            CREATE INDEX IF NOT EXISTS idx_shares_recipient ON shares(recipient_id);
            CREATE INDEX IF NOT EXISTS idx_shares_entry ON shares(entry_id);
        """)
        await db.commit()
