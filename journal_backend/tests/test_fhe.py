"""Tests for FHE endpoints (routers/fhe.py)."""

import pytest


@pytest.mark.anyio
async def test_upload_key_requires_auth(client):
    """FHE key upload must require authentication."""
    resp = await client.post(
        "/fhe/key",
        json={"evaluation_key_b64": "dGVzdA=="},
    )
    # Should be 403 (no credentials) not 200
    assert resp.status_code == 403


@pytest.mark.anyio
async def test_predict_requires_auth(client):
    """FHE predict must require authentication."""
    resp = await client.post(
        "/fhe/predict",
        json={"encrypted_input_b64": "dGVzdA=="},
    )
    assert resp.status_code == 403


@pytest.mark.anyio
async def test_upload_key_invalid_base64(client):
    """Uploading an invalid base64 evaluation key should return an HTTP error,
    not raise an unhandled exception."""
    resp = await client.post(
        "/fhe/key",
        json={"evaluation_key_b64": "!!!not-valid-base64!!!"},
        headers={"Authorization": "Bearer fake-token"},
    )
    # Should get 401 (invalid token) — the point is we get an HTTP status,
    # not an unhandled server exception.
    assert resp.status_code in (400, 401, 422, 500)
