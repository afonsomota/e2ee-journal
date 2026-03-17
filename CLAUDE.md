# E2EE Journal — FHE Emotion Classification

## Project Overview

An end-to-end encrypted journal app with on-device FHE (Fully Homomorphic Encryption) emotion classification. The server performs ML inference on **encrypted** data — it never sees plaintext journal content or emotion predictions.

## Architecture

```
Flutter App (journal_app/)
  │
  ├── flutter_concrete plugin (flutter_concrete/)   ← standalone FFI plugin (git submodule)
  │     • Rust/TFHE-rs native library (built via Cargokit)
  │     • ConcreteClient: keygen, quantize+encrypt, decrypt+dequantize
  │     • FheNative: low-level Dart FFI bindings
  │     • QuantizationParams: input/output quantization
  │
  ├── App FHE Layer (lib/fhe/)                       ← app-specific orchestration
  │     • FheClient: setup/vectorizeAndEncrypt/decryptResult
  │     • Vectorizer: TF-IDF + LSA vectorization (pure Dart)
  │     • Key persistence (flutter_secure_storage)
  │
  └── FastAPI Backend (journal_backend/)             ← cloud server (localhost:8000)
        • Stores opaque ciphertext blobs
        • Runs FHE inference via /fhe/predict
        • Never sees plaintext text or predictions
```

### FHE Flow (orchestrated by Flutter)

1. `FheClient.setup()` → generate/restore TFHE-rs keypair (native Rust, persisted in secure storage)
2. Dart → backend `POST /fhe/key` → upload evaluation key
3. `FheClient.vectorizeAndEncrypt(text)` → encrypted feature vector (TF-IDF + LSA + quantize + encrypt, all in-process)
4. Dart → backend `POST /fhe/predict` → get encrypted result
5. `FheClient.decryptResult(b64)` → emotion label + confidence (decrypt + dequantize in-process)

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
- `journal_app/assets/fhe/client.zip` — bundled in Flutter app (loaded by native Rust via FFI)
- `journal_app/assets/fhe/quantization_params.json` — input/output quantization params for Dart client

## Backend (`journal_backend/`)

- `routers/fhe.py` — `/fhe/key` (upload eval key) + `/fhe/predict` (run FHE inference)
- `routers/auth.py`, `routers/entries.py`, `routers/users.py` — E2EE journal core
- `main.py` — mounts all routers, includes FHE router at `/fhe`
- `requirements.txt` — includes `concrete-ml`

## Flutter Concrete Plugin (`flutter_concrete/`)

Standalone Flutter FFI plugin (git submodule) wrapping TFHE-rs for Concrete ML FHE operations. Native Rust library builds automatically via Cargokit during `flutter build` — no manual build scripts needed.

- `lib/src/concrete_client.dart` — `ConcreteClient`: keygen, quantize+encrypt, decrypt+dequantize
- `lib/src/fhe_native.dart` — `FheNative`: low-level Dart FFI bindings to `libfhe_client`
- `lib/src/quantizer.dart` — `QuantizationParams`, `InputQuantParam`, `OutputQuantParam`
- `lib/flutter_concrete.dart` — barrel export
- `rust/` — Rust crate (`fhe_client`): TFHE-rs keygen, encrypt, decrypt via C FFI
- `cargokit/` — Cargokit submodule (irondash/cargokit) for automatic native builds

## Flutter App (`journal_app/`)

- `lib/fhe/fhe_client.dart` — `FheClient`: high-level orchestration (setup, vectorizeAndEncrypt, decryptResult) using `ConcreteClient` from `flutter_concrete`
- `lib/fhe/vectorizer.dart` — pure-Dart TF-IDF + LSA + L2-norm vectorizer (loads vocab/SVD from assets)
- `lib/services/emotion_service.dart` — `EmotionService` (ChangeNotifier), orchestrates the 5-step FHE flow
  - Tracks in-progress classifications via `_inProgress: Set<String>`
  - Dio `receiveTimeout` 10 minutes for backend FHE inference
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
- **flutter_concrete plugin** — FHE client extracted to standalone Flutter FFI plugin with Cargokit; no manual build scripts needed
- **Native Dart FHE client** — Python sidecar replaced by Rust/TFHE-rs via Dart FFI; no Python runtime required on-device
- Backend FHE inference endpoints implemented with logging
- UI integration: emotion badges on detail/list/editor screens
- Flutter `_inProgress` tracking to prevent stuck spinner UI
- Dio `receiveTimeout` increased to 10 minutes (FHE inference is CPU-intensive)
- `.vscode/launch.json` configured for Cursor with DEBUG log level

🚧 **Testing Required:**
- Test emotion classification end-to-end with native Dart FHE client
- Confirm emotion badge appears after FHE computation completes

⚡ **Future:**
- Persistent evaluation key store (Redis) for production

## Running Locally

**Via Cursor (recommended):**
1. Open `.vscode/launch.json` — has `backend` and `flutter` configs
2. Select target in Run & Debug sidebar and press play
3. Logs output directly to terminal with DEBUG level enabled

**Manual (if needed):**
```bash
# Backend
LOG_LEVEL=DEBUG source journal_backend/.venv/bin/activate && cd journal_backend && uvicorn main:app --reload --port 8000

# Flutter (no sidecar needed — FHE runs natively in-app)
cd journal_app && flutter run
```

**Native Rust library:** Builds automatically via Cargokit during `flutter build` — no manual steps needed. Requires Rust toolchain installed on the build machine.

## Notes & Dependencies

- **Native FHE client:** All on-device FHE ops (keygen, encrypt, decrypt) run in-process via `flutter_concrete` plugin (Rust/TFHE-rs, built by Cargokit) — no Python runtime or manual build scripts required
- **Key persistence:** FHE client/server keypair persisted in `flutter_secure_storage` — expensive keygen (~10–60 s on mobile) is skipped on subsequent launches
- **Evaluation keys:** Stored in-memory in backend (`_eval_keys` dict) — lost on restart; needs Redis/persistent store for production
- **FHE model artifacts:** `journal_backend/fhe_model/server.zip` (backend) and `journal_app/assets/fhe/client.zip` (bundled in Flutter app)
- **UI state tracking:** `EmotionService._inProgress: Set<String>` prevents stuck spinner; `isClassifying(entryId)` checks if classification is running
- **Dio timeout:** `receiveTimeout: Duration(minutes: 10)` — FHE inference on backend is CPU-intensive
- **Logging:** Backend uses `LOG_LEVEL` env var (default INFO)
- **Graceful degradation:** If backend unreachable, `EmotionService.available = false`; auto-recovery via `unawaited(initialize())`
- Local Python environment is made by uv. So use `uv pip` instead of `pip` and remember to load the respective environment: backend or emotion_ml. They are different.
