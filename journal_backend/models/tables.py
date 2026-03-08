from sqlalchemy import (
    Column,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id = Column(String, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password_hash = Column(String, nullable=False)
    public_key = Column(Text)
    encrypted_private_key = Column(Text)
    created_at = Column(
        String, nullable=False, server_default=text("(datetime('now'))")
    )


class Entry(Base):
    __tablename__ = "entries"

    id = Column(String, primary_key=True)
    author_id = Column(String, ForeignKey("users.id"), nullable=False)
    content = Column(Text)
    encrypted_blob = Column(Text)
    encrypted_content_key = Column(Text)
    created_at = Column(
        String, nullable=False, server_default=text("(datetime('now'))")
    )
    updated_at = Column(
        String, nullable=False, server_default=text("(datetime('now'))")
    )

    __table_args__ = (
        Index("idx_entries_author", "author_id"),
    )


class Share(Base):
    __tablename__ = "shares"

    id = Column(String, primary_key=True)
    entry_id = Column(
        String,
        ForeignKey("entries.id", ondelete="CASCADE"),
        nullable=False,
    )
    recipient_id = Column(String, ForeignKey("users.id"), nullable=False)
    encrypted_content_key = Column(Text)
    created_at = Column(
        String, nullable=False, server_default=text("(datetime('now'))")
    )

    __table_args__ = (
        UniqueConstraint("entry_id", "recipient_id"),
        Index("idx_shares_recipient", "recipient_id"),
        Index("idx_shares_entry", "entry_id"),
    )
