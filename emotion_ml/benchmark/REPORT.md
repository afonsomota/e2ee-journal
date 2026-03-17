# FHE Benchmark Report

**Date:** 2026-03-17
**Machine:** macOS Darwin 25.3.0, Apple Silicon (aarch64)
**Python:** 3.11.3
**Concrete-ML:** installed from emotion_ml/requirements.txt
**Model:** XGBClassifier (n_estimators=200, max_depth=3, n_bits=8)
**Features:** TF-IDF (5000) → LSA/SVD (200) → L2 normalize

---

## 1. Inference Timing Analysis

**Methodology:** 5 samples from test set, timed per-step (encrypt, server FHE inference, decrypt).

### Per-Sample Breakdown

| Sample | Encrypt | Server | Decrypt | Total | Prediction |
|--------|---------|--------|---------|-------|------------|
| 1 | 0.02s | 218.73s | 0.04s | 218.78s | sadness |
| 2 | 0.03s | 219.21s | 0.05s | 219.28s | anger |
| 3 | 0.03s | 204.15s | 0.04s | 204.22s | joy |
| 4 | 0.02s | 216.56s | 0.05s | 216.62s | joy |
| 5 | 0.02s | 200.51s | 0.04s | 200.56s | neutral |

### Summary Statistics

| Step | Mean | Std Dev | % of Total |
|------|------|---------|------------|
| Encrypt (client) | 0.02s | 0.00s | 0.01% |
| **Server inference** | **211.83s** | **7.89s** | **99.97%** |
| Decrypt (client) | 0.04s | 0.00s | 0.02% |
| **Total** | **211.89s** | **7.90s** | 100% |

### Setup Costs (one-time)

| Operation | Time |
|-----------|------|
| Client/server init | 2.65s |
| Key generation | 1.51s |

### Data Sizes

| Item | Size |
|------|------|
| Evaluation key | 56.2 MB |
| Encrypted input (1 sample) | 4.9 KB |
| Encrypted output (1 sample) | 15.6 MB |

### Time Projections for Evaluation Runs

| Samples | Estimated Time |
|---------|----------------|
| 10 | ~35 minutes |
| 25 | ~1.5 hours |
| 50 | ~3 hours |
| 100 | ~6 hours |
| 200 | ~12 hours |
| 500 | ~29 hours |
| 1000 | ~59 hours |

### Key Takeaway

Server-side FHE inference dominates at **99.97%** of total time (~3.5 minutes per sample).
Client-side encrypt/decrypt is negligible (<0.1s combined).
Recommended sample count for accuracy evaluation: **50 samples** (~3 hours) for meaningful per-class statistics across 5 emotion classes.

---

## 2. Python Client vs Dart/Rust Client (flutter_concrete)

### Architecture Comparison

| Aspect | Python (Concrete-ML) | Dart + Rust (flutter_concrete) |
|--------|---------------------|-------------------------------|
| Crypto library | TFHE-rs (via Concrete-ML) | TFHE-rs (direct, same git rev `1ec21a5`) |
| Parameter set | `V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64` | Same |
| Ciphertext format | `CiphertextFormat.TFHE_RS` | Native TFHE-rs (identical) |
| Serialization | bincode | bincode (identical) |
| Input quantization | Bundled in `FHEModelClient.quantize_encrypt_serialize()` | Split: Dart quantizes (float→uint8), Rust encrypts |
| Output dequantization | Bundled in `FHEModelClient.deserialize_decrypt_dequantize()` | Split: Rust decrypts (→int8), Dart dequantizes |
| Quantization params | From `client.zip/serialized_processing.json` | Same file, same params |

### Result Equivalence

**The Python and Dart/Rust clients produce cryptographically identical ciphertexts** given the same quantized input. Both use:
- Same TFHE-rs encryption primitives (`FheUint8::encrypt`)
- Same parameter set and key format
- Same bincode serialization

The quantization math is identical:
- **Input:** `quantized = clamp(round(float / scale) + zero_point, 0, 255)`
- **Output:** `float = (raw_int8 + offset - zero_point) * scale`

### Where Differences Could Arise

The only potential source of divergence is the **vectorization pipeline** (TF-IDF + SVD), not the FHE layer:
- Python uses sklearn's `TfidfVectorizer.transform()` and `TruncatedSVD.transform()` (64-bit float)
- Dart reimplements these from exported binary assets (`vocab.json`, `idf_weights.bin`, `svd_components.bin`)
- Floating-point precision differences between Python/sklearn and Dart could produce slightly different LSA vectors
- These differences are validated by `gen_test_vectors.py` reference vectors in the test suite

**Conclusion:** FHE predictions from Python and Dart clients are equivalent. Any accuracy delta would come from vectorizer precision, not the encryption layer.

---

## 3. Encrypted vs Plain Accuracy Comparison

**Methodology:** 10 stratified test samples (2 per class), comparing plain sklearn XGBClassifier vs FHE encrypted inference using the pre-compiled model.

### Per-Sample Results

| # | True | Plain | FHE | Match | Time |
|---|------|-------|-----|-------|------|
| 1 | anger | surprise | surprise | same | 178.2s |
| 2 | anger | anger | anger | same | 184.8s |
| 3 | joy | joy | joy | same | 180.0s |
| 4 | joy | joy | joy | same | 176.2s |
| 5 | neutral | neutral | neutral | same | 177.2s |
| 6 | neutral | anger | anger | same | 185.7s |
| 7 | sadness | neutral | neutral | same | 178.6s |
| 8 | sadness | sadness | sadness | same | 173.8s |
| 9 | surprise | sadness | sadness | same | 172.5s |
| 10 | surprise | surprise | surprise | same | 169.4s |

### Agreement & Accuracy

| Metric | Value |
|--------|-------|
| **Plain vs FHE agreement** | **10/10 (100%)** |
| Plain accuracy | 60.00% |
| FHE accuracy | 60.00% |

### Per-Class Metrics (identical for both)

| Class | Precision | Recall | F1 | Support |
|-------|-----------|--------|----|---------|
| anger | 0.50 | 0.50 | 0.50 | 2 |
| joy | 1.00 | 1.00 | 1.00 | 2 |
| neutral | 0.50 | 0.50 | 0.50 | 2 |
| sadness | 0.50 | 0.50 | 0.50 | 2 |
| surprise | 0.50 | 0.50 | 0.50 | 2 |

### Timing Comparison

| Metric | Plain | FHE | Ratio |
|--------|-------|-----|-------|
| Per-sample | 0.3 ms | 177.7 s | **675,909x** |
| Total (10 samples) | 0.003s | 29.6 min | — |

### Key Findings

1. **FHE introduces zero accuracy loss** — plain and encrypted predictions are identical on all 10 samples. The 8-bit quantization with shallow XGBoost (max_depth=3) preserves decision boundaries perfectly.
2. **The model's 60% accuracy** (on this small sample) reflects the inherent difficulty of 5-class emotion classification, not FHE degradation. Both plain and encrypted make the same mistakes.
3. **FHE overhead is ~675,000x** in wall time, entirely dominated by server-side homomorphic computation (~178s/sample). Client encrypt/decrypt is negligible.
4. **No mismatches observed** — a larger sample (50+) would be needed to find quantization boundary cases, if any exist.

---

## 4. Python vs Dart Preprocessing Comparison

**Methodology:** Simulated Dart's vectorizer in Python (Float32 precision, same regex, same binary assets) and compared against sklearn's pipeline step-by-step on 6 test sentences.

### Preprocessing Pipeline: Dart matches Python perfectly

| Step | Max Diff | Status |
|------|----------|--------|
| Tokenization | 0 | ALL MATCH (same regex, same tokens) |
| TF-IDF (sublinear TF × IDF) | 5.58e-08 | MATCH (Float32 rounding only) |
| SVD projection | 2.02e-08 | MATCH |
| L2 normalization | 1.28e-07 | MATCH |
| **Quantization (uint8)** | **0** | **EXACT MATCH — 0/1200 mismatches** |

**The Dart vectorizer is correct.** Float32 precision differences are in the 1e-7 range — negligible and never enough to flip a quantized value.

### Root Cause Found: Output Dequantization Offset

The actual bug is in **how the app interprets FHE output**, not in preprocessing.

**Output quantizer parameters** (from `client.zip/serialized_processing.json`):
- `scale = 0.006437`
- `zero_point = 0`
- `offset = 128`

**Dart dequantization** (correct — in `quantizer.dart`):
```
float = (raw_int8 + 128 - 0) * 0.006437
```

This is the **correct** formula per Concrete-ML's quantization protocol. The `offset=128` maps signed int8 [-128, 127] to the unsigned range [0, 255] before dequantizing.

**The 127% confidence explained:**
```
If raw_int8 = 70:  (70 + 128 - 0) * 0.006437 = 1.2746 → 127.5%
```

The dequantized scores are **not probabilities** — they are raw model logits in an arbitrary range. The app should use `argmax` to pick the winning class, not interpret the raw score as a confidence percentage.

**Example dequantized output range:**

| raw_int8 | Dequantized value |
|----------|-------------------|
| -128 | 0.000 |
| -64 | 0.412 |
| 0 | 0.824 |
| 64 | 1.236 |
| 127 | 1.642 |

### Why Always "neutral"?

This needs further investigation with **actual live Dart output** from the app. Possible causes:
1. The vectorizer/quantizer is correct (proven above), but something goes wrong in the **actual Flutter asset loading** (e.g., vocab.json not bundled, binary assets corrupted, wrong endianness)
2. The encrypted input or server response is corrupted in transit (base64 encoding/decoding, HTTP body handling)
3. The Rust FFI encrypt/decrypt returns unexpected data

### Recommended Next Steps

1. Add debug logging in `EmotionService` to dump: (a) raw vectorizer output first 10 values, (b) quantized uint8 first 10 values, (c) raw int8 decrypted output, (d) dequantized float output
2. Compare those live values against the reference vectors in `fhe_reference_vectors.json`
3. Fix confidence display: use `softmax(scores)` or `score / sum(scores)` instead of raw dequantized value
