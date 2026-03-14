# E2EE Journal — FHE Emotion Classification

## Project Overview

An end-to-end encrypted journal app with on-device FHE (Fully Homomorphic Encryption) emotion classification. The server performs ML inference on **encrypted** data — it never sees plaintext journal content or emotion predictions.

## Architecture

```
Flutter App (journal_app/)
  │
  ├── Local Python Sidecar (fhe_client/)       ← runs on user's device (localhost:8001)
  │     • TF-IDF + LSA vectorization
  │     • FHE encrypt (quantize → encrypt → serialize)
  │     • FHE decrypt (deserialize → decrypt → dequantize → argmax → label)
  │
  └── FastAPI Backend (journal_backend/)        ← cloud server (localhost:8000)
        • Stores opaque ciphertext blobs
        • Runs FHE inference via /fhe/predict
        • Never sees plaintext text or predictions
```

### FHE Flow (orchestrated by Flutter)

1. Dart → sidecar `POST /setup` → get `client_id` + serialized evaluation key
2. Dart → backend `POST /fhe/key` → upload evaluation key
3. Dart → sidecar `POST /vectorize` → get encrypted feature vector
4. Dart → backend `POST /fhe/predict` → get encrypted result
5. Dart → sidecar `POST /decrypt` → get emotion label + confidence

## ML Pipeline (`emotion_ml/`)

**Dataset:** GoEmotions (Google), mapped to 5 Ekman classes: `anger`, `joy`, `neutral`, `sadness`, `surprise`

**Pipeline:** TF-IDF (5000 features, 1-2 grams) → LSA/TruncatedSVD (200 components) → L2 normalize → XGBClassifier (FHE-compatible)

**Why XGBoost instead of Logistic Regression:** Concrete-ML's `LogisticRegression` has issues with the LR setup (multi-class / regularization config) that caused compilation/accuracy problems. XGBoost (`concrete.ml.sklearn.XGBClassifier`) compiles cleanly to FHE circuit with `n_bits=8`.

**Key files:**
- `emotion_ml/config.py` — all hyperparameters and label mapping
- `emotion_ml/training/train.py` — trains TF-IDF + LSA + XGBClassifier, saves sklearn artifacts
- `emotion_ml/fhe/compile_fhe.py` — compiles trained model to FHE circuit, saves `server.zip` + `client.zip`
- `emotion_ml/fhe/fit.py` — fits quantization on calibration samples
- `emotion_ml/fhe/test_fhe.py` — end-to-end FHE test (encrypt → server run → decrypt)

**Artifacts produced:**
- `emotion_ml/artifacts/tfidf_vectorizer.pkl`
- `emotion_ml/artifacts/svd.pkl`
- `emotion_ml/artifacts/normalizer.pkl`
- `emotion_ml/artifacts/label_encoder.pkl`
- `journal_backend/fhe_model/server.zip` — loaded by `FHEModelServer`
- `fhe_client/assets/fhe_model/client.zip` — loaded by `FHEModelClient`
- `fhe_client/assets/tfidf_vectorizer.pkl` (copy)
- `fhe_client/assets/svd.pkl` (copy)
- `fhe_client/assets/normalizer.pkl` (copy)

## Backend (`journal_backend/`)

- `routers/fhe.py` — `/fhe/key` (upload eval key) + `/fhe/predict` (run FHE inference)
- `routers/auth.py`, `routers/entries.py`, `routers/users.py` — E2EE journal core
- `main.py` — mounts all routers, includes FHE router at `/fhe`
- `requirements.txt` — includes `concrete-ml`

## Flutter App (`journal_app/`)

- `lib/services/emotion_service.dart` — `EmotionService` (ChangeNotifier), orchestrates the 5-step FHE flow
  - Tracks in-progress classifications via `_inProgress: Set<String>`
  - Increased Dio `receiveTimeout` to 10 minutes for long FHE computations
  - Auto-recovery on backend restart
- `lib/models/emotion_result.dart` — `EmotionResult { emotion, confidence }`
- `lib/screens/entry_detail_screen.dart` — shows emotion badge with loading state
- `lib/screens/journal_list_screen.dart` — emotion chip in entry cards
- `lib/screens/entry_editor_screen.dart` — emotion bar in edit mode
- `lib/main.dart` — registers `EmotionService` in the provider tree

## Status

✅ **Completed:**
- Full FHE pipeline infrastructure (setup → vectorize → predict → decrypt)
- ML model training, quantization, and FHE compilation
- Sidecar and backend endpoints implemented with logging
- UI integration: emotion badges on detail/list/editor screens
- Flutter `_inProgress` tracking to prevent stuck spinner UI
- Dio `receiveTimeout` increased to 10 minutes (FHE inference is CPU-intensive)
- `.vscode/launch.json` configured for Cursor with DEBUG log level for all targets
- Python environments specified in launch configs

🚧 **Testing Required:**
- FHE inference now has sufficient timeout; test emotion classification end-to-end via Cursor
- Monitor backend and sidecar logs during classification to verify pipeline flow
- Confirm emotion badge appears after FHE computation completes

⚡ **Future:**
- Replace Python sidecar with native Dart/C implementation
- Persistent evaluation key store (Redis) for production

## Running Locally

**Via Cursor (recommended):**
1. Open `.vscode/launch.json` — has `backend`, `fhe-sidecar`, and `flutter` configs
2. Select target in Run & Debug sidebar (e.g., "backend") and press play
3. Logs output directly to terminal with DEBUG level enabled
4. All targets automatically set `LOG_LEVEL=DEBUG` for detailed tracing

**Manual (if needed):**
```bash
# Backend (from worktree root, uses fhe_client/.venv which has concrete-ml)
LOG_LEVEL=DEBUG source fhe_client/.venv/bin/activate && cd journal_backend && uvicorn main:app --reload --port 8000

# FHE sidecar
cd fhe_client && LOG_LEVEL=DEBUG source .venv/bin/activate && uvicorn main:app --reload --port 8001

# Flutter
cd journal_app && flutter run
```

## Notes & Dependencies

- **Sidecar separation:** Intentionally separate from backend — runs on user's device, holds private keys for FHE decrypt
- **Virtual env:** Both backend and sidecar use `fhe_client/.venv` (contains `concrete-ml` and all deps)
- **Evaluation keys:** Stored in-memory in backend (`_eval_keys` dict) — lost on restart; needs Redis/persistent store for production
- **FHE model artifacts:** Located in `journal_backend/fhe_model/` (server.zip) and `fhe_client/assets/fhe_model/` (client.zip)
- **UI state tracking:** `EmotionService._inProgress: Set<String>` prevents stuck spinner by tracking active classifications; `isClassifying(entryId)` checks if classification is running
- **Dio timeout:** `receiveTimeout: Duration(minutes: 10)` in `emotion_service.dart` — FHE inference is CPU-intensive and can take several minutes; timeout must be generous
- **Logging:** Both backend (`main.py`) and sidecar (`main.py`) use `LOG_LEVEL` env var (default INFO). All endpoints log request/response sizes and execution stages
- **Graceful degradation:** If sidecar unreachable, `EmotionService.available = false` and UI hides emotion features; auto-recovery on backend restart via `unawaited(initialize())`
- **Branch:** Working on `dev` branch, not `main`
- **Python paths:** `.vscode/launch.json` specifies `${workspaceFolder}/fhe_client/.venv/bin/python` for both backend and sidecar targets
