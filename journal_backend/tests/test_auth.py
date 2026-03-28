"""Tests for routers/auth.py — registration, login, token validation."""


class TestRegister:
    def test_register_success(self, client, register_user):
        header, user = register_user(username="reg_ok")
        assert user["username"] == "reg_ok"
        assert user["public_key"] == "pk_test"
        assert "id" in user

    def test_register_returns_token(self, client, register_user):
        header, user = register_user()
        # The header was built from the token, so using it should work.
        resp = client.get("/users/me", headers=header)
        assert resp.status_code == 200
        assert resp.json()["username"] == user["username"]

    def test_register_duplicate_username(self, client, register_user):
        register_user(username="dup_user")
        resp = client.post(
            "/auth/register",
            json={"username": "dup_user", "password": "testpass123"},
        )
        assert resp.status_code == 409

    def test_register_short_username(self, client):
        resp = client.post(
            "/auth/register",
            json={"username": "ab", "password": "testpass123"},
        )
        assert resp.status_code == 422  # pydantic validation

    def test_register_short_password(self, client):
        resp = client.post(
            "/auth/register",
            json={"username": "validuser", "password": "short"},
        )
        assert resp.status_code == 422


class TestLogin:
    def test_login_success(self, client, register_user):
        register_user(username="login_ok", password="my_password")
        resp = client.post(
            "/auth/login",
            json={"username": "login_ok", "password": "my_password"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert "access_token" in data
        assert data["user"]["username"] == "login_ok"

    def test_login_wrong_password(self, client, register_user):
        register_user(username="login_wp", password="correctpass")
        resp = client.post(
            "/auth/login",
            json={"username": "login_wp", "password": "wrongpass1"},
        )
        assert resp.status_code == 401

    def test_login_nonexistent_user(self, client):
        resp = client.post(
            "/auth/login",
            json={"username": "ghost_user", "password": "whatever1"},
        )
        assert resp.status_code == 401


class TestTokenValidation:
    def test_invalid_token(self, client):
        resp = client.get(
            "/users/me",
            headers={"Authorization": "Bearer invalidtoken"},
        )
        assert resp.status_code == 401

    def test_missing_token(self, client):
        resp = client.get("/users/me")
        assert resp.status_code == 403  # HTTPBearer returns 403 when missing
