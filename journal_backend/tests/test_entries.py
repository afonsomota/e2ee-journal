"""Tests for routers/entries.py — CRUD operations, sharing, access control."""


class TestCreateEntry:
    def test_create_entry_with_content(self, client, register_user):
        header, user = register_user()
        resp = client.post(
            "/entries",
            json={"content": "Hello world"},
            headers=header,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["content"] == "Hello world"
        assert data["author_id"] == user["id"]
        assert data["id"]

    def test_create_entry_with_encrypted_blob(self, client, register_user):
        header, _ = register_user()
        resp = client.post(
            "/entries",
            json={
                "encrypted_blob": "base64ciphertext",
                "encrypted_content_key": "base64key",
            },
            headers=header,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["encrypted_blob"] == "base64ciphertext"
        assert data["encrypted_content_key"] == "base64key"

    def test_create_entry_requires_content_or_blob(self, client, register_user):
        header, _ = register_user()
        resp = client.post("/entries", json={}, headers=header)
        assert resp.status_code == 400

    def test_create_entry_unauthenticated(self, client):
        resp = client.post("/entries", json={"content": "nope"})
        assert resp.status_code == 403


class TestListEntries:
    def test_list_own_entries(self, client, register_user):
        header, _ = register_user()
        client.post("/entries", json={"content": "e1"}, headers=header)
        client.post("/entries", json={"content": "e2"}, headers=header)
        resp = client.get("/entries", headers=header)
        assert resp.status_code == 200
        entries = resp.json()
        assert len(entries) >= 2

    def test_entries_isolated_per_user(self, client, register_user):
        h1, _ = register_user()
        h2, _ = register_user()
        client.post("/entries", json={"content": "user1 entry"}, headers=h1)

        resp = client.get("/entries", headers=h2)
        entries = resp.json()
        contents = [e["content"] for e in entries]
        assert "user1 entry" not in contents


class TestUpdateEntry:
    def test_update_own_entry(self, client, register_user):
        header, _ = register_user()
        create_resp = client.post(
            "/entries", json={"content": "original"}, headers=header
        )
        entry_id = create_resp.json()["id"]
        resp = client.put(
            f"/entries/{entry_id}",
            json={"content": "updated"},
            headers=header,
        )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    def test_update_other_users_entry(self, client, register_user):
        h1, _ = register_user()
        h2, _ = register_user()
        create_resp = client.post(
            "/entries", json={"content": "mine"}, headers=h1
        )
        entry_id = create_resp.json()["id"]
        resp = client.put(
            f"/entries/{entry_id}",
            json={"content": "hacked"},
            headers=h2,
        )
        assert resp.status_code == 403

    def test_update_nonexistent_entry(self, client, register_user):
        header, _ = register_user()
        resp = client.put(
            "/entries/nonexistent-id",
            json={"content": "x"},
            headers=header,
        )
        assert resp.status_code == 404


class TestDeleteEntry:
    def test_delete_own_entry(self, client, register_user):
        header, _ = register_user()
        create_resp = client.post(
            "/entries", json={"content": "to delete"}, headers=header
        )
        entry_id = create_resp.json()["id"]
        resp = client.delete(f"/entries/{entry_id}", headers=header)
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    def test_delete_other_users_entry(self, client, register_user):
        h1, _ = register_user()
        h2, _ = register_user()
        create_resp = client.post(
            "/entries", json={"content": "mine"}, headers=h1
        )
        entry_id = create_resp.json()["id"]
        resp = client.delete(f"/entries/{entry_id}", headers=h2)
        assert resp.status_code == 403

    def test_delete_nonexistent_entry(self, client, register_user):
        header, _ = register_user()
        resp = client.delete("/entries/nonexistent-id", headers=header)
        assert resp.status_code == 404


class TestSharing:
    def test_share_entry(self, client, register_user):
        h_owner, _ = register_user()
        _, recipient = register_user(username="share_recipient_1")
        create_resp = client.post(
            "/entries", json={"content": "shared"}, headers=h_owner
        )
        entry_id = create_resp.json()["id"]
        resp = client.post(
            f"/entries/{entry_id}/share",
            json={
                "recipient_username": "share_recipient_1",
                "encrypted_content_key": "eck_for_recipient",
            },
            headers=h_owner,
        )
        assert resp.status_code == 200
        assert resp.json()["shared_with"] == "share_recipient_1"

    def test_shared_with_me(self, client, register_user):
        h_owner, _ = register_user()
        h_recipient, r_user = register_user(username="share_reader_1")
        create_resp = client.post(
            "/entries",
            json={"content": "secret", "encrypted_blob": "blob1"},
            headers=h_owner,
        )
        entry_id = create_resp.json()["id"]
        client.post(
            f"/entries/{entry_id}/share",
            json={
                "recipient_username": "share_reader_1",
                "encrypted_content_key": "eck_for_reader",
            },
            headers=h_owner,
        )
        resp = client.get("/entries/shared-with-me", headers=h_recipient)
        assert resp.status_code == 200
        entries = resp.json()
        ids = [e["id"] for e in entries]
        assert entry_id in ids

    def test_share_nonexistent_entry(self, client, register_user):
        h_owner, _ = register_user()
        register_user(username="share_ghost_1")
        resp = client.post(
            "/entries/nonexistent-id/share",
            json={"recipient_username": "share_ghost_1"},
            headers=h_owner,
        )
        assert resp.status_code == 404

    def test_share_not_owner(self, client, register_user):
        h_owner, _ = register_user()
        h_other, _ = register_user()
        register_user(username="share_target_1")
        create_resp = client.post(
            "/entries", json={"content": "mine"}, headers=h_owner
        )
        entry_id = create_resp.json()["id"]
        resp = client.post(
            f"/entries/{entry_id}/share",
            json={"recipient_username": "share_target_1"},
            headers=h_other,
        )
        assert resp.status_code == 403

    def test_share_nonexistent_recipient(self, client, register_user):
        h_owner, _ = register_user()
        create_resp = client.post(
            "/entries", json={"content": "x"}, headers=h_owner
        )
        entry_id = create_resp.json()["id"]
        resp = client.post(
            f"/entries/{entry_id}/share",
            json={"recipient_username": "nobody_exists"},
            headers=h_owner,
        )
        assert resp.status_code == 404

    def test_revoke_share(self, client, register_user):
        h_owner, _ = register_user()
        h_recipient, _ = register_user(username="revoke_target_1")
        create_resp = client.post(
            "/entries", json={"content": "revokable"}, headers=h_owner
        )
        entry_id = create_resp.json()["id"]
        client.post(
            f"/entries/{entry_id}/share",
            json={"recipient_username": "revoke_target_1"},
            headers=h_owner,
        )
        resp = client.delete(
            f"/entries/{entry_id}/share/revoke_target_1",
            headers=h_owner,
        )
        assert resp.status_code == 200

        # Verify it's gone from shared-with-me.
        resp = client.get("/entries/shared-with-me", headers=h_recipient)
        ids = [e["id"] for e in resp.json()]
        assert entry_id not in ids
