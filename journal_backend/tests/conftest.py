"""Shared test fixtures for journal_backend tests."""

import os
import pytest
import pytest_asyncio
from unittest.mock import patch, AsyncMock

# Set environment before importing app modules
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("DB_PATH", ":memory:")

from httpx import ASGITransport, AsyncClient


@pytest_asyncio.fixture
async def client():
    """Async HTTP test client backed by the FastAPI app.

    Patches init_db to avoid running Alembic migrations in tests,
    and sets up an in-memory SQLite database.
    """
    with patch("main.init_db", new_callable=AsyncMock):
        from main import app

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            yield ac
