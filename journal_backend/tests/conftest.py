"""Shared test fixtures for the journal_backend test suite.

Uses a temporary SQLite database that is created fresh for each test session.
Alembic migrations run against the temp DB so the schema matches production.
"""

import os
import tempfile

import pytest

# Point the database at a temp file BEFORE importing app modules.
_tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp.close()
os.environ["DB_PATH"] = _tmp.name

from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from main import app  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _run_migrations():
    """Run Alembic migrations once per test session."""
    cfg = Config("alembic.ini")
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{_tmp.name}")
    command.upgrade(cfg, "head")
    yield
    # Cleanup temp DB after the entire session.
    try:
        os.unlink(_tmp.name)
    except OSError:
        pass


@pytest.fixture()
def client():
    """A synchronous FastAPI TestClient for making HTTP requests."""
    with TestClient(app) as c:
        yield c


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_user_counter = 0


def _unique_username(prefix: str = "user") -> str:
    global _user_counter
    _user_counter += 1
    return f"{prefix}_{_user_counter}"


@pytest.fixture()
def register_user(client):
    """Factory fixture: register a user and return (auth_header, user_dict)."""

    def _register(
        username: str | None = None,
        password: str = "testpass123",
        public_key: str | None = "pk_test",
        encrypted_private_key: str | None = "epk_test",
    ):
        username = username or _unique_username()
        resp = client.post(
            "/auth/register",
            json={
                "username": username,
                "password": password,
                "public_key": public_key,
                "encrypted_private_key": encrypted_private_key,
            },
        )
        assert resp.status_code == 200, resp.text
        data = resp.json()
        token = data["access_token"]
        header = {"Authorization": f"Bearer {token}"}
        return header, data["user"]

    return _register
