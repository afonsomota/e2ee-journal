"""Tests for routers/fhe.py — evaluation key upload and predict endpoint.

The FHE model files (server.zip) may not be present on the test machine, so
we mock the concrete.ml and concrete.fhe imports where needed.
"""

import base64
from unittest.mock import MagicMock, patch

import pytest


class TestUploadEvaluationKey:
    def test_upload_key(self, client):
        fake_key = base64.b64encode(b"fake-eval-key").decode()
        with patch("routers.fhe.fhe") as mock_fhe:
            mock_fhe.EvaluationKeys.deserialize.return_value = MagicMock()
            resp = client.post(
                "/fhe/key",
                json={
                    "client_id": "test-client-1",
                    "evaluation_key_b64": fake_key,
                },
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_upload_key_invalid_base64(self, client):
        import binascii

        with pytest.raises(binascii.Error):
            client.post(
                "/fhe/key",
                json={
                    "client_id": "test-client-2",
                    "evaluation_key_b64": "not-valid-base64!!!",
                },
            )


class TestPredict:
    def test_predict_without_key(self, client):
        fake_input = base64.b64encode(b"encrypted-data").decode()
        resp = client.post(
            "/fhe/predict",
            json={
                "client_id": "no-key-client",
                "encrypted_input_b64": fake_input,
            },
        )
        assert resp.status_code == 400
        assert "Evaluation keys not found" in resp.json()["detail"]

    def test_predict_success(self, client):
        fake_input = base64.b64encode(b"encrypted-input").decode()
        fake_result = b"encrypted-result"

        mock_eval_keys = MagicMock()
        mock_server = MagicMock()
        mock_server.run.return_value = fake_result

        with (
            patch("routers.fhe.fhe") as mock_fhe,
            patch("routers.fhe._get_server", return_value=mock_server),
            patch.dict("routers.fhe._eval_keys", {"pred-client": mock_eval_keys}),
        ):
            mock_fhe.EvaluationKeys.deserialize.return_value = mock_eval_keys
            resp = client.post(
                "/fhe/predict",
                json={
                    "client_id": "pred-client",
                    "encrypted_input_b64": fake_input,
                },
            )

        assert resp.status_code == 200
        result = resp.json()
        assert "encrypted_result_b64" in result
        decoded = base64.b64decode(result["encrypted_result_b64"])
        assert decoded == fake_result

    def test_predict_unwraps_tuple(self, client):
        """server.run() may return a tuple when using tfhers_bridge."""
        fake_input = base64.b64encode(b"encrypted-input").decode()
        fake_result = b"encrypted-result"

        mock_eval_keys = MagicMock()
        mock_server = MagicMock()
        mock_server.run.return_value = (fake_result, b"extra")

        with (
            patch("routers.fhe._get_server", return_value=mock_server),
            patch.dict("routers.fhe._eval_keys", {"tuple-client": mock_eval_keys}),
        ):
            resp = client.post(
                "/fhe/predict",
                json={
                    "client_id": "tuple-client",
                    "encrypted_input_b64": fake_input,
                },
            )

        assert resp.status_code == 200
        decoded = base64.b64decode(resp.json()["encrypted_result_b64"])
        assert decoded == fake_result
