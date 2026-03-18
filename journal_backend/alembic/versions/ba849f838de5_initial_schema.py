"""initial schema

Revision ID: ba849f838de5
Revises:
Create Date: 2026-03-05 01:08:29.170826

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "ba849f838de5"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("username", sa.String(), nullable=False, unique=True),
        sa.Column("password_hash", sa.String(), nullable=False),
        sa.Column("public_key", sa.Text()),
        sa.Column("encrypted_private_key", sa.Text()),
        sa.Column(
            "created_at",
            sa.String(),
            nullable=False,
            server_default=sa.text("(datetime('now'))"),
        ),
    )

    op.create_table(
        "entries",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column(
            "author_id",
            sa.String(),
            sa.ForeignKey("users.id"),
            nullable=False,
        ),
        sa.Column("content", sa.Text()),
        sa.Column("encrypted_blob", sa.Text()),
        sa.Column("encrypted_content_key", sa.Text()),
        sa.Column(
            "created_at",
            sa.String(),
            nullable=False,
            server_default=sa.text("(datetime('now'))"),
        ),
        sa.Column(
            "updated_at",
            sa.String(),
            nullable=False,
            server_default=sa.text("(datetime('now'))"),
        ),
    )
    op.create_index("idx_entries_author", "entries", ["author_id"])

    op.create_table(
        "shares",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column(
            "entry_id",
            sa.String(),
            sa.ForeignKey("entries.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "recipient_id",
            sa.String(),
            sa.ForeignKey("users.id"),
            nullable=False,
        ),
        sa.Column("encrypted_content_key", sa.Text()),
        sa.Column(
            "created_at",
            sa.String(),
            nullable=False,
            server_default=sa.text("(datetime('now'))"),
        ),
        sa.UniqueConstraint("entry_id", "recipient_id"),
    )
    op.create_index("idx_shares_recipient", "shares", ["recipient_id"])
    op.create_index("idx_shares_entry", "shares", ["entry_id"])


def downgrade() -> None:
    op.drop_index("idx_shares_entry", table_name="shares")
    op.drop_index("idx_shares_recipient", table_name="shares")
    op.drop_table("shares")
    op.drop_index("idx_entries_author", table_name="entries")
    op.drop_table("entries")
    op.drop_table("users")
