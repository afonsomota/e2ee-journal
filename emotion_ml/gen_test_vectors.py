#!/usr/bin/env python3
"""Generate reference test vectors for Dart vectorizer unit tests.

Runs the full Python pipeline (TF-IDF → L2 norm → SVD → L2 norm → quantize)
on a set of test sentences and outputs JSON that the Dart test can compare against.

Usage:
    python3 gen_test_vectors.py
Output:
    journal_app/test/fhe_reference_vectors.json
"""

import json
import math
import warnings
import sys
import os

# Suppress sklearn version mismatch warnings
warnings.filterwarnings('ignore')

# ── Locate artifacts ──────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
ARTIFACTS_DIR = os.path.join(SCRIPT_DIR, 'artifacts')
FHE_ASSETS_DIR = os.path.join(REPO_ROOT, 'journal_app', 'assets', 'fhe')

import joblib
import numpy as np

print("Loading artifacts...", file=sys.stderr)
tfidf = joblib.load(os.path.join(ARTIFACTS_DIR, 'tfidf_vectorizer.pkl'))
svd   = joblib.load(os.path.join(ARTIFACTS_DIR, 'svd.pkl'))
norm  = joblib.load(os.path.join(ARTIFACTS_DIR, 'normalizer.pkl'))

# Load quantization params (same as in export_dart_assets.py)
quant_path = os.path.join(FHE_ASSETS_DIR, 'quantization_params.json')
with open(quant_path) as f:
    quant_params = json.load(f)

# ── Test sentences ─────────────────────────────────────────────────────────────
TEST_SENTENCES = [
    "I am happy",
    "This makes me so angry and frustrated",
    "I feel nothing today",
    "Today was a great day and I felt wonderful",
    "The quick brown fox jumped over the lazy dog",
    "I am so sad and heartbroken",
    "Wow that was surprising and unexpected",
]

# ── Pipeline helpers ───────────────────────────────────────────────────────────

def python_vectorize(text: str) -> np.ndarray:
    """Full pipeline: text → 200-dim normalised LSA vector."""
    x = tfidf.transform([text])          # sparse (1, 5000), already L2-normed by sklearn
    x = svd.transform(x)                 # (1, 200)
    x = norm.transform(x)                # L2 normalise SVD output
    return x.flatten().astype(np.float32)

def python_quantize(vector: np.ndarray) -> list[int]:
    """Apply input quantizers to the 200-dim vector."""
    inputs = quant_params['input']
    assert len(inputs) == len(vector), f"Expected {len(vector)} quantizers, got {len(inputs)}"
    result = []
    for i, (val, q) in enumerate(zip(vector, inputs)):
        scale = q['scale']
        zero_point = q['zero_point']
        quantized = int(np.clip(round(float(val) / scale) + zero_point, 0, 255))
        result.append(quantized)
    return result

def python_dequantize_output(raw_output_ints: list[int]) -> list[float]:
    """Apply output dequantizer to raw model output ints."""
    out_params = quant_params['output']
    scale = out_params['scale']
    zero_point = out_params['zero_point']
    return [(int_val - zero_point) * scale for int_val in raw_output_ints]

# ── Intermediate step helpers for Dart test verification ──────────────────────

def python_tfidf_only(text: str) -> np.ndarray:
    """TF-IDF step only (before SVD), returns dense float32 array."""
    x = tfidf.transform([text])
    return np.asarray(x.todense(), dtype=np.float32).flatten()

def python_svd_only(text: str) -> np.ndarray:
    """TF-IDF + SVD only (before final L2 norm)."""
    x = tfidf.transform([text])
    x = svd.transform(x)
    return x.flatten().astype(np.float32)

# ── Generate reference data ───────────────────────────────────────────────────
results = {}
for sentence in TEST_SENTENCES:
    print(f"  Processing: {sentence!r}", file=sys.stderr)
    vec = python_vectorize(sentence)
    tfidf_vec = python_tfidf_only(sentence)
    svd_vec = python_svd_only(sentence)
    quant = python_quantize(vec)
    results[sentence] = {
        # First 10 TF-IDF values (after L2 norm) — intermediate check
        'tfidf_first10': tfidf_vec[:10].tolist(),
        # First 10 SVD values (before final L2 norm) — intermediate check
        'svd_first10': svd_vec[:10].tolist(),
        # Full 200-dim final vector (after all normalization)
        'vector': vec.tolist(),
        # First 10 values of the final vector for easy comparison
        'vector_first10': vec[:10].tolist(),
        # Quantized values (200 uint8 values)
        'quantized_first10': quant[:10],
        'quantized_full': quant,
    }

# Output path
OUT_PATH = os.path.join(REPO_ROOT, 'journal_app', 'test', 'fhe_reference_vectors.json')
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
with open(OUT_PATH, 'w') as f:
    json.dump(results, f, indent=2)

print(f"Written: {OUT_PATH}", file=sys.stderr)

# ── Print summary for verification ────────────────────────────────────────────
print("\nReference vectors (first 5 dims of final output):")
for sentence, data in results.items():
    v5 = data['vector_first10'][:5]
    q5 = data['quantized_first10'][:5]
    print(f"  {sentence!r}")
    print(f"    vector[:5]   = {[f'{x:.6f}' for x in v5]}")
    print(f"    quantized[:5]= {q5}")
