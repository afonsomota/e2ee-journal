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
- `lib/models/emotion_result.dart` — `EmotionResult { emotion, confidence }`
- `lib/main.dart` — registers `EmotionService` in the provider tree

## What's Left To Do

1. **UI integration** — Display emotion result on journal entry view/edit screen
   - Show emotion label + confidence badge after entry is saved/opened
   - `EmotionService.classifyEntry(entryId, plaintext)` is ready to call

2. **Run the full training + compile pipeline** and verify FHE round-trip works:
   ```bash
   cd emotion_ml
   python training/train.py       # trains model, saves sklearn artifacts
   python fhe/fit.py              # fits quantization
   python fhe/compile_fhe.py      # compiles to FHE circuit
   python fhe/test_fhe.py         # end-to-end FHE test
   ```

3. **Copy artifacts** to their serving locations:
   ```bash
   cp -r emotion_ml/artifacts/fhe_model/ journal_backend/fhe_model/
   cp emotion_ml/artifacts/*.pkl fhe_client/assets/
   cp -r emotion_ml/artifacts/fhe_model/ fhe_client/assets/fhe_model/
   ```

4. **Replace Python sidecar with native Dart/C** — production step, currently the sidecar is a FastAPI app

## Running Locally

```bash
# Backend
cd journal_backend && pip install -r requirements.txt && uvicorn main:app --port 8000

# FHE sidecar (after artifacts are built)
cd fhe_client && pip install -r requirements.txt && uvicorn main:app --port 8001

# Flutter
cd journal_app && flutter run
```

## Notes

- The sidecar is intentionally separate from the backend — it runs locally on the user's device and holds private keys
- `FHE_MODEL_DIR` env var can override default model path on the backend
- Evaluation keys are stored in-memory (`_eval_keys` dict in `routers/fhe.py`) — in production use Redis or a persistent store
- The emotion feature is opt-in/graceful: if the sidecar is unreachable, `EmotionService.available` is `false` and the UI should hide the emotion badge
