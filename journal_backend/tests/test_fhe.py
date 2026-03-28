"""Tests for routers/fhe.py — evaluation key upload and predict endpoint.

The FHE model files (server.zip) may not be present on the test machine, so
we mock the concrete.ml and concrete.fhe imports where needed.

FHE endpoints require authentication (JWT). Tests use the register_user
fixture to obtain auth headers.
"""

import base64
from unittest.mock import MagicMock, patch


class TestFheAuthentication:
    """Verify FHE endpoints require authentication."""

    def test_upload_key_requires_auth(self, client):
        resp = client.post(
            "/fhe/key",
            json={"evaluation_key_b64": "dGVzdA=="},
        )
        assert resp.status_code == 403

    def test_predict_requires_auth(self, client):
        resp = client.post(
            "/fhe/predict",
            json={"encrypted_input_b64": "dGVzdA=="},
        )
        assert resp.status_code == 403


class TestFlutterClientAuthBug:
    """Regression test for the 403 Forbidden error from the Flutter app.

    Root cause: security hardening added Depends(current_user) to both FHE
    endpoints (/fhe/key and /fhe/predict), but EmotionService._backend (Dio)
    is configured without an Authorization header / auth interceptor.

    Compare:
      - journal_service.dart: adds "Authorization: Bearer <token>" via
        an InterceptorsWrapper on every request.
      - emotion_service.dart: creates a plain Dio(BaseOptions(...)) with
        NO auth interceptor — so all calls hit the backend unauthenticated.

    Flutter-side fix needed (emotion_service.dart):
      EmotionService needs access to the AuthService token and must include
      an Authorization header on _backend, e.g. via an interceptor like
      JournalService._dio does:
          opts.headers['Authorization'] = 'Bearer ${_auth!.token}';
    """

    def test_upload_key_without_auth_returns_403(self, client):
        """Reproduces the exact request EmotionService.initialize() sends.

        EmotionService posts to /fhe/key with no Authorization header,
        which results in a 403 because the endpoint requires current_user.
        """
        resp = client.post(
            "/fhe/key",
            json={
                "evaluation_key_b64": "dGVzdA==",
            },
            # No Authorization header — this is what the Flutter app does
        )
        assert resp.status_code == 403, (
            f"Expected 403 Forbidden (no auth token), got {resp.status_code}"
        )

    def test_predict_without_auth_returns_403(self, client):
        """Reproduces the request EmotionService.classifyEntry() sends.

        EmotionService posts to /fhe/predict with no Authorization header.
        """
        resp = client.post(
            "/fhe/predict",
            json={
                "encrypted_input_b64": "dGVzdA==",
            },
        )
        assert resp.status_code == 403, (
            f"Expected 403 Forbidden (no auth token), got {resp.status_code}"
        )

    def test_upload_key_with_auth_succeeds(self, client, register_user):
        """Same request but WITH the auth token — this is the expected fix."""
        auth_header, _user = register_user()
        with patch("routers.fhe.fhe") as mock_fhe:
            mock_fhe.EvaluationKeys.deserialize.return_value = MagicMock()
            resp = client.post(
                "/fhe/key",
                json={"evaluation_key_b64": "dGVzdA=="},
                headers=auth_header,
            )
        assert resp.status_code == 200


class TestUploadEvaluationKey:
    def test_upload_key(self, client, register_user):
        auth_header, _user = register_user()
        fake_key = base64.b64encode(b"fake-eval-key").decode()
        with patch("routers.fhe.fhe") as mock_fhe:
            mock_fhe.EvaluationKeys.deserialize.return_value = MagicMock()
            resp = client.post(
                "/fhe/key",
                json={"evaluation_key_b64": fake_key},
                headers=auth_header,
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_upload_key_invalid_base64(self, client, register_user):
        auth_header, _ = register_user()
        resp = client.post(
            "/fhe/key",
            json={"evaluation_key_b64": "not-valid-base64!!!"},
            headers=auth_header,
        )
        # Should get an HTTP error, not an unhandled exception
        assert resp.status_code in (400, 422, 500)


class TestPredict:
    def test_predict_without_key(self, client, register_user):
        auth_header, _user = register_user()
        fake_input = base64.b64encode(b"encrypted-data").decode()
        resp = client.post(
            "/fhe/predict",
            json={"encrypted_input_b64": fake_input},
            headers=auth_header,
        )
        assert resp.status_code == 400
        assert "Evaluation keys not found" in resp.json()["detail"]

    def test_predict_success(self, client, register_user):
        auth_header, _user = register_user()
        fake_input = base64.b64encode(b"encrypted-input").decode()
        fake_result = b"encrypted-result"

        mock_eval_keys = MagicMock()
        mock_server = MagicMock()
        mock_server.run.return_value = fake_result

        with (
            patch("routers.fhe.fhe") as mock_fhe,
            patch("routers.fhe._get_server", return_value=mock_server),
            patch.dict("routers.fhe._eval_keys", {_user["id"]: mock_eval_keys}),
        ):
            mock_fhe.EvaluationKeys.deserialize.return_value = mock_eval_keys
            resp = client.post(
                "/fhe/predict",
                json={"encrypted_input_b64": fake_input},
                headers=auth_header,
            )

        assert resp.status_code == 200
        result = resp.json()
        assert "encrypted_result_b64" in result
        decoded = base64.b64decode(result["encrypted_result_b64"])
        assert decoded == fake_result

    def test_predict_unwraps_tuple(self, client, register_user):
        """server.run() may return a tuple when using tfhers_bridge."""
        auth_header, _user = register_user()
        fake_input = base64.b64encode(b"encrypted-input").decode()
        fake_result = b"encrypted-result"

        mock_eval_keys = MagicMock()
        mock_server = MagicMock()
        mock_server.run.return_value = (fake_result, b"extra")

        with (
            patch("routers.fhe._get_server", return_value=mock_server),
            patch.dict("routers.fhe._eval_keys", {_user["id"]: mock_eval_keys}),
        ):
            resp = client.post(
                "/fhe/predict",
                json={"encrypted_input_b64": fake_input},
                headers=auth_header,
            )

        assert resp.status_code == 200
        decoded = base64.b64decode(resp.json()["encrypted_result_b64"])
        assert decoded == fake_result
