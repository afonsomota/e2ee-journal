"""Tests for routers/users.py — public key lookup, current user."""


class TestGetPublicKey:
    def test_get_public_key(self, client, register_user):
        register_user(username="pk_owner_1", public_key="my_pub_key")
        header, _ = register_user()  # requester
        resp = client.get("/users/pk_owner_1/public-key", headers=header)
        assert resp.status_code == 200
        data = resp.json()
        assert data["username"] == "pk_owner_1"
        assert data["public_key"] == "my_pub_key"

    def test_get_public_key_nonexistent_user(self, client, register_user):
        header, _ = register_user()
        resp = client.get("/users/nonexistent/public-key", headers=header)
        assert resp.status_code == 404

    def test_get_public_key_no_key_set(self, client, register_user):
        register_user(username="nokey_user_1", public_key=None)
        header, _ = register_user()
        resp = client.get("/users/nokey_user_1/public-key", headers=header)
        assert resp.status_code == 404

    def test_get_public_key_unauthenticated(self, client):
        resp = client.get("/users/anyone/public-key")
        assert resp.status_code == 403


class TestGetMe:
    def test_get_me(self, client, register_user):
        header, user = register_user(username="me_user_1")
        resp = client.get("/users/me", headers=header)
        assert resp.status_code == 200
        data = resp.json()
        assert data["id"] == user["id"]
        assert data["username"] == "me_user_1"
        assert "public_key" in data
