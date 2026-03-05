# E2EE Journal

A Flutter + FastAPI journal app with end-to-end encryption and sharing.

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
