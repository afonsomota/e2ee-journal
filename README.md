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
