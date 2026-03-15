# Native Dart FHE Client

## Goal

Replace the Python sidecar's three FHE endpoints (`/setup`, `/vectorize`, `/decrypt`) with a native Dart implementation. Remove those endpoints from `fhe_client/main.py`. The sidecar disappears entirely — the Flutter app calls Dart code directly.

This unblocks mobile: no Python process on device, no `concrete-ml` packaging problem.

---

## What the Sidecar Does (to replace)

`fhe_client/main.py` has three operations:

| Endpoint | Logic |
|---|---|
| `POST /setup` | Init `FHEModelClient`, generate TFHE keys, return serialized eval key |
| `POST /vectorize` | text → TF-IDF (5000 features) → LSA/SVD (200 components) → L2 normalize → `quantize_encrypt_serialize` → base64 bytes |
| `POST /decrypt` | base64 bytes → `deserialize_decrypt_dequantize` → argmax over 5 classes → emotion label + confidence |

---

## Two Parts to Implement in Dart

### Part A — Vectorization (pure math, no FFI)

TF-IDF + SVD + normalize is deterministic linear algebra. The parameters are frozen in the pkl files. Export them once from Python to portable formats, then implement transforms in Dart.

**Export script** (`emotion_ml/export_dart_assets.py`, run once):
- `tfidf_vectorizer.pkl` → `vocab.json` (word→index map) + `idf_weights.f32` (5000 floats)
- `svd.pkl` → `svd_components.f32` (200×5000 float32 matrix) + `svd_mean.f32` (optional, if fitted)
- `normalizer.pkl` → just L2 normalization, no params needed

**Dart implementation** (`journal_app/lib/fhe/vectorizer.dart`):
- Tokenize text (split on non-word chars, lowercase, strip) → term counts
- Multiply by IDF weights → TF-IDF vector (sparse, 5000-dim)
- Dense matrix multiply with SVD components → 200-dim float vector
- L2 normalize

### Part B — FHE Crypto (Dart FFI → libconcrete)

The quantize/encrypt/decrypt operations require the TFHE runtime from `libconcrete`. The approach:

1. **Extract `libconcrete.so`** from the installed `concrete-python` wheel (already present in `fhe_client/.venv`)
2. **Inspect `client.zip`** contents to understand the serialization format and quantization parameters
3. **Write a thin C wrapper** (`native/fhe_wrapper.cpp`) exposing three functions:
   ```c
   int  fhe_setup(const char* client_zip_path, const char* key_dir);
   int  fhe_encrypt(const float* features, int n, uint8_t** out, int* out_len);
   int  fhe_decrypt(const uint8_t* in, int in_len, float** scores, int* n_classes);
   uint8_t* fhe_get_eval_key(int* key_len);
   ```
4. **Dart FFI bindings** (`journal_app/lib/fhe/fhe_native.dart`) call the wrapper via `dart:ffi`

**libconcrete location:** `fhe_client/.venv/lib/python3.*/site-packages/concrete/` — contains `libconcrete_compiler.so` (Linux) or `.dylib` (macOS). The client-side encrypt/decrypt path does not invoke the MLIR compiler, only the crypto runtime.

---

## Implementation Steps

### 1. Inspect `client.zip` ✅
From `serialized_processing.json`:
- **200 input quantizers** — one per LSA feature, each with its own `scale` and `zero_point`
  - scale range: [0.002192, 0.004656], zero_points vary per feature (0–134)
  - quantize: `q = clip(round(x / scale) + zero_point, 0, 255)` (uint8, unsigned)
- **1 output quantizer** — for all 5 class scores
  - scale=0.006437, zero_point=0, offset=128, signed
  - dequantize: `float = (int_val - zero_point) * scale`
- `ciphertext_format: "concrete"` (concrete-python native format)
- Circuit input shape: `[1, 200, 3]` — 200 LWE ciphertexts (one per feature), each 3 polynomials (LWE dim 2048)
- Circuit output shape: `[1, 5, 200, 2049]` — 5 class LWE ciphertexts

### 2. Write export script (`emotion_ml/export_dart_assets.py`)
Outputs to `journal_app/assets/fhe/`:
- `vocab.json`
- `idf_weights.bin` (5000 × float32, little-endian)
- `svd_components.bin` (200 × 5000 × float32)
- `quantization_params.json` (input/output scale and zero_point from client.zip)

### 3. Implement `Vectorizer` in Dart
`journal_app/lib/fhe/vectorizer.dart`
- Loads assets once (lazy singleton)
- `Future<Float32List> transform(String text)`
- Pure Dart, no FFI

### 4. Write C wrapper + build script
`journal_app/native/fhe_wrapper.cpp` — thin C API over `FHEModelClient` logic
`journal_app/native/CMakeLists.txt` — links against extracted `libconcrete`

Desktop-first: build and test on Linux/macOS before worrying about mobile.

### 5. Dart FFI bindings
`journal_app/lib/fhe/fhe_native.dart`
- Loads the compiled shared library
- Exposes `setup()`, `encrypt(Float32List)`, `decrypt(Uint8List)`, `getEvalKey()`

### 6. New `FheClient` Dart class
`journal_app/lib/fhe/fhe_client.dart`
- Wraps Vectorizer + FheNative
- `Future<String> setup()` → eval key base64
- `Future<String> vectorizeAndEncrypt(String text)` → encrypted vector base64
- `Future<EmotionResult> decryptResult(String encryptedB64)` → EmotionResult

### 7. Update `EmotionService`
`journal_app/lib/services/emotion_service.dart`:
- Remove `_sidecar` Dio client
- Replace sidecar HTTP calls with direct `FheClient` calls:
  - `_sidecar.post('/setup')` → `_fheClient.setup()`
  - `_sidecar.post('/vectorize', ...)` → `_fheClient.vectorizeAndEncrypt(text)`
  - `_sidecar.post('/decrypt', ...)` → `_fheClient.decryptResult(encResultB64)`

### 8. Remove sidecar endpoints
`fhe_client/main.py`: delete `/setup`, `/vectorize`, `/decrypt` endpoints and all supporting code (FHEModelClient, joblib loads, LABELS). The file will effectively be empty/deleted.

---

## Files Changed

| File | Change |
|---|---|
| `emotion_ml/export_dart_assets.py` | NEW — one-time export script |
| `journal_app/assets/fhe/*.bin/*.json` | NEW — exported model params |
| `journal_app/lib/fhe/vectorizer.dart` | NEW — Dart TF-IDF + SVD + normalize |
| `journal_app/native/fhe_wrapper.cpp` | NEW — C API over libconcrete |
| `journal_app/native/CMakeLists.txt` | NEW — build config |
| `journal_app/lib/fhe/fhe_native.dart` | NEW — Dart FFI bindings |
| `journal_app/lib/fhe/fhe_client.dart` | NEW — Dart FHE client |
| `journal_app/lib/services/emotion_service.dart` | EDIT — replace sidecar HTTP with FheClient |
| `fhe_client/main.py` | EDIT — remove /setup, /vectorize, /decrypt |

---

## Risk

**Biggest unknown:** whether `libconcrete`'s C API is stable and accessible enough to wrap cleanly. If it isn't, fallback is to call `concrete-python`'s Python API via a subprocess (still removes the HTTP sidecar). Mobile cross-compilation is a follow-on task once desktop works.

## Verification

1. Run export script, confirm assets written correctly
2. Unit test `Vectorizer.transform("I am happy")` matches Python sidecar output (log the vector before encryption in both)
3. Start backend only (no sidecar), run Flutter app, confirm emotion classification completes end-to-end
4. Confirm `fhe_client/main.py` no longer has FHE endpoints
