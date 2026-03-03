# models/database.py
#
# [Step 2] Server-side encryption at rest.
#
# The schema is identical to Step 1.  The difference is at the STORAGE layer:
# the database engine transparently encrypts the file on disk.
#
# Options:
#   - SQLCipher (drop-in replacement for SQLite, AES-256-CBC per page)
#   - AWS RDS encryption, Azure TDE, GCP CMEK
#   - Full-disk encryption (LUKS, FileVault, BitLocker)
#
# What this protects against:
#   + Stolen hard drives / decommissioned servers
#   + Backups accessed by unauthorized parties
#
# What this does NOT protect against:
#   - The server admin (they hold the encryption key)
#   - A subpoena (the server can decrypt on demand)
#   - A compromised server process (data is plaintext in memory at query time)
#
# The client code is unchanged — it still sends and receives plaintext.
# Real-world examples: Dropbox, Google Drive, AWS S3 default encryption.

import aiosqlite
import os

DB_PATH = os.getenv("DB_PATH", "journal.db")


async def get_db():
    """Dependency: yields a database connection per request."""
    # In production with SQLCipher, you would pass `key=...` here.
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
                id         TEXT PRIMARY KEY,
                author_id  TEXT NOT NULL REFERENCES users(id),
                content    TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_entries_author ON entries(author_id);
        """)
        await db.commit()
