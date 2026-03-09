# E2EE Journal — Blog Series Source Code

A Flutter + FastAPI journal app that progressively adds end-to-end encryption
across 6 steps. Each git tag is a complete, working app.

## Steps

| Tag | Title | What changes |
|-----|-------|------|
| `step-1` | No Encryption | Baseline — plaintext CRUD |
| `step-2` | Server-Side Encryption at Rest | Conceptual — server encrypts on disk |
| `step-3` | Client-Side Symmetric Encryption | Argon2id KDF + XSalsa20-Poly1305 secretbox |
| `step-4` | Asymmetric Keypair Generation | X25519 keypair; private key encrypted locally |
| `step-5` | Hybrid Encryption | Per-entry random content key + sealed box |
| `step-6` | Sharing | Content key re-encrypted for each recipient |

## Navigating the Code

```bash
# Check out any step
git checkout step-3

# See what changed between two steps
git diff step-3..step-4

# Return to the complete version
git checkout complete
```

## Running the App

### Backend

```bash
cd journal_backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

API docs at http://localhost:8000/docs

### Flutter Client

```bash
cd journal_app
flutter pub get
flutter run
```

Update `baseUrl` in the service files to point to your FastAPI server
(use `10.0.2.2` for Android emulator, `localhost` for iOS simulator / desktop).

## Architecture

```
journal_app/          Flutter client (Dart)
├── lib/
│   ├── main.dart
│   ├── models/       Data classes
│   ├── services/     Auth, crypto, journal orchestration
│   └── screens/      UI

journal_backend/      FastAPI server (Python)
├── main.py
├── models/           Database schema
└── routers/          API endpoints
```

## Known Limitations

This project is a teaching companion for a blog series. Several simplifications
were made deliberately to keep the focus on E2EE concepts. They are documented
inline with `BLOG NOTE` comments throughout the code.

### Cryptographic / Security

| # | Limitation | Detail |
|---|-----------|--------|
| 1 | **No MITM protection on key distribution** | The server is the sole source of public keys (`GET /users/{username}/public-key`). A malicious server operator could substitute a user's public key with their own and silently intercept shared entries. Mitigations such as key transparency logs, out-of-band fingerprint verification (Signal safety numbers), and TOFU (Trust On First Use) are not implemented. |
| 2 | **Deterministic KDF salt derived from username** | The Argon2id salt is derived from the username (zero-padded to 16 bytes) so the key can be reproduced across devices without a server round-trip. In production, a random per-user salt should be stored server-side. |
| 3 | **Revocation does not prevent cached access** | Revoking a share deletes the encrypted key blob on the server, but if the recipient has already decrypted and cached the content locally, they retain access. True forward-secure revocation would require re-encrypting the entry with a new content key. |
| 4 | **No server-side encryption at rest** | The SQLite database file is not encrypted on disk. Entry content is E2EE (unreadable by the server), but metadata — usernames, timestamps, share relationships — is stored in plaintext. |

### Deployment / Infrastructure

| # | Limitation | Detail |
|---|-----------|--------|
| 5 | **Hardcoded JWT secret fallback** | `JWT_SECRET` defaults to `"change-me-in-production"` if the environment variable is not set. |
| 6 | **CORS allows all origins** | `allow_origins=["*"]` — must be restricted to the application's domain(s) before deployment. |
| 7 | **SQLite instead of a production database** | Used for simplicity; production deployments should use PostgreSQL + asyncpg or equivalent. |
