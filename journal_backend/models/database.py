# models/database.py
#
# SQLite via aiosqlite for simplicity.  In production: PostgreSQL + asyncpg.
#
# Schema is managed by Alembic (see alembic/ directory).
# The declarative models live in models/tables.py.
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

import os

import aiosqlite
from alembic.config import Config

from alembic import command

DB_PATH = os.getenv("DB_PATH", "journal.db")


async def get_db():
    """Dependency: yields a database connection per request."""
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        yield db


def run_migrations():
    """Run Alembic migrations to bring the database up to date."""
    alembic_cfg = Config("alembic.ini")
    command.upgrade(alembic_cfg, "head")


async def init_db():
    run_migrations()
