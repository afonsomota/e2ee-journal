"""Compare Python sklearn preprocessing vs Dart vectorizer output.

Runs the Python pipeline step-by-step and dumps intermediate values
that can be compared against Dart's output (either from reference vectors
or live Flutter debug logs).

Also checks for known issues:
  - Tokenization differences (regex mismatch)
  - Float32 vs float64 precision loss
  - Quantization edge cases (all-zero vectors → all-zero_point)
  - Output dequantization offset handling
"""

import json
import math
import sys
import os
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np

from config import ARTIFACTS_DIR, LABELS

# ── Load artifacts ────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).parent.parent.parent
FHE_ASSETS_DIR = REPO_ROOT / "journal_app" / "assets" / "fhe"
REF_VECTORS_PATH = REPO_ROOT / "journal_app" / "test" / "fhe_reference_vectors.json"

tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

# Load quantization params from client.zip
client_zip_proc = ARTIFACTS_DIR / "fhe_model" / "client" / "serialized_processing.json"
with open(client_zip_proc) as f:
    proc_data = json.load(f)


def extract_val(v):
    if isinstance(v, dict):
        return v["serialized_value"]
    return v


input_quants = []
for q in proc_data["input_quantizers"]:
    sv = q["serialized_value"]
    input_quants.append({
        "scale": extract_val(sv["scale"]),
        "zero_point": extract_val(sv["zero_point"]),
        "offset": sv.get("offset", 0),
    })

out_sv = proc_data["output_quantizers"][0]["serialized_value"]
output_quant = {
    "scale": extract_val(out_sv["scale"]),
    "zero_point": extract_val(out_sv["zero_point"]),
    "offset": out_sv.get("offset", 0),
}

# Load Dart-exported assets for binary comparison
vocab_json = json.loads((FHE_ASSETS_DIR / "vocab.json").read_text())
idf_bin = np.frombuffer(
    (FHE_ASSETS_DIR / "idf_weights.bin").read_bytes(), dtype=np.float32
)
svd_bin = np.frombuffer(
    (FHE_ASSETS_DIR / "svd_components.bin").read_bytes(), dtype=np.float32
).reshape(200, 5000)


# ── Test sentences ────────────────────────────────────────────────────────────

TEST_SENTENCES = [
    "I am happy",
    "This makes me so angry and frustrated",
    "I feel nothing today",
    "Today was a great day and I felt wonderful",
    "I am so sad and heartbroken",
    "Wow that was surprising and unexpected",
]


# ── Python pipeline (step by step) ───────────────────────────────────────────

def python_tokenize(text):
    """Replicate sklearn's (?u)\\b\\w\\w+\\b tokenizer."""
    import re
    pattern = r"(?u)\b\w\w+\b"
    tokens = re.findall(pattern, text.lower())
    return tokens


def dart_tokenize(text):
    """Replicate Dart's [a-zA-Z0-9_]{2,} tokenizer."""
    import re
    pattern = r"[a-zA-Z0-9_]{2,}"
    tokens = re.findall(pattern, text.lower())
    return tokens


def python_full_pipeline(text):
    """Return intermediate results at each step."""
    results = {}

    # Step 1: Tokenize
    py_tokens = python_tokenize(text)
    dart_tokens = dart_tokenize(text)
    results["py_tokens"] = py_tokens
    results["dart_tokens"] = dart_tokens
    results["token_match"] = py_tokens == dart_tokens

    # Step 2: sklearn TF-IDF (includes sublinear_tf + L2 norm)
    X_tfidf_sparse = tfidf.transform([text])
    X_tfidf = np.asarray(X_tfidf_sparse.todense(), dtype=np.float64).flatten()
    results["tfidf_nnz"] = int(np.count_nonzero(X_tfidf))
    results["tfidf_norm"] = float(np.linalg.norm(X_tfidf))
    results["tfidf_first10"] = X_tfidf[:10].tolist()

    # Step 2b: Simulate Dart's TF-IDF (manual sublinear_tf + IDF + L2 norm)
    dart_tfidf = simulate_dart_tfidf(text)
    results["dart_tfidf_nnz"] = int(np.count_nonzero(dart_tfidf))
    results["dart_tfidf_norm"] = float(np.linalg.norm(dart_tfidf))
    results["dart_tfidf_first10"] = dart_tfidf[:10].tolist()
    tfidf_diff = np.abs(X_tfidf - dart_tfidf.astype(np.float64))
    results["tfidf_max_diff"] = float(np.max(tfidf_diff))
    results["tfidf_mean_diff"] = float(np.mean(tfidf_diff[tfidf_diff > 0])) if np.any(tfidf_diff > 0) else 0.0

    # Step 3: SVD (Python sklearn)
    X_svd = svd.transform(X_tfidf_sparse)  # (1, 200)
    X_svd = X_svd.flatten()
    results["svd_first10"] = X_svd[:10].tolist()

    # Step 3b: Simulate Dart's SVD (manual matrix multiply using exported binary)
    dart_svd = simulate_dart_svd(dart_tfidf)
    results["dart_svd_first10"] = dart_svd[:10].tolist()
    svd_diff = np.abs(X_svd - dart_svd.astype(np.float64))
    results["svd_max_diff"] = float(np.max(svd_diff))

    # Step 4: L2 normalize (Python)
    X_norm = normalizer.transform(X_svd.reshape(1, -1)).flatten()
    results["norm_first10"] = X_norm[:10].tolist()

    # Step 4b: Simulate Dart's L2 normalize
    dart_norm = l2_normalize_f32(dart_svd.copy())
    results["dart_norm_first10"] = dart_norm[:10].tolist()
    norm_diff = np.abs(X_norm - dart_norm.astype(np.float64))
    results["norm_max_diff"] = float(np.max(norm_diff))

    # Step 5: Quantize (Python — using float64 vector)
    py_quantized = quantize_input(X_norm)
    results["py_quantized_first10"] = py_quantized[:10]

    # Step 5b: Quantize (simulated Dart — using float32 vector)
    dart_quantized = quantize_input(dart_norm)
    results["dart_quantized_first10"] = dart_quantized[:10]

    quant_diff = np.abs(np.array(py_quantized) - np.array(dart_quantized))
    results["quant_mismatches"] = int(np.sum(quant_diff > 0))
    results["quant_max_diff"] = int(np.max(quant_diff))

    # Check for all-same quantized values (the "always neutral" symptom)
    results["dart_quant_unique"] = len(set(dart_quantized))
    results["dart_quant_most_common"] = max(set(dart_quantized), key=dart_quantized.count)

    # Full vectors for detailed comparison
    results["py_vector"] = X_norm.tolist()
    results["dart_vector"] = dart_norm.tolist()
    results["py_quantized"] = py_quantized
    results["dart_quantized"] = dart_quantized

    return results


def simulate_dart_tfidf(text):
    """Simulate Dart's TF-IDF exactly (Float32 precision)."""
    # Tokenize like Dart
    import re
    pattern = r"[a-zA-Z0-9_]{2,}"
    lower = text.lower()
    unigrams = re.findall(pattern, lower)

    counts = {}  # vocab_idx -> count

    # Unigrams
    for token in unigrams:
        idx = vocab_json.get(token)
        if idx is not None:
            counts[idx] = counts.get(idx, 0) + 1

    # Bigrams
    for i in range(len(unigrams) - 1):
        bigram = f"{unigrams[i]} {unigrams[i + 1]}"
        idx = vocab_json.get(bigram)
        if idx is not None:
            counts[idx] = counts.get(idx, 0) + 1

    # Sublinear TF * IDF (float32 precision like Dart)
    tfidf_vec = np.zeros(5000, dtype=np.float32)
    for idx, count in counts.items():
        tf = np.float32(1.0 + np.float32(math.log(count)))
        tfidf_vec[idx] = tf * idf_bin[idx]

    # L2 normalize
    l2_normalize_f32(tfidf_vec)

    return tfidf_vec


def simulate_dart_svd(tfidf_vec):
    """Simulate Dart's SVD projection (Float32 precision, sparse dot product)."""
    result = np.zeros(200, dtype=np.float32)
    nonzero = np.nonzero(tfidf_vec)[0]
    for j in range(200):
        s = np.float32(0.0)
        for i in nonzero:
            s += tfidf_vec[i] * svd_bin[j, i]
        result[j] = s
    return result


def l2_normalize_f32(v):
    """L2 normalize in float32 (like Dart)."""
    norm = np.float32(0.0)
    for x in v:
        norm += np.float32(x) * np.float32(x)
    if norm == 0.0:
        return v
    inv_norm = np.float32(1.0) / np.float32(math.sqrt(float(norm)))
    for i in range(len(v)):
        v[i] = np.float32(v[i]) * inv_norm
    return v


def quantize_input(vector):
    """Quantize float vector to uint8 using per-feature params."""
    result = []
    for i, val in enumerate(vector):
        scale = input_quants[i]["scale"]
        zp = input_quants[i]["zero_point"]
        q = int(np.clip(round(float(val) / scale) + zp, 0, 255))
        result.append(q)
    return result


# ── Output dequantization analysis ────────────────────────────────────────────

def analyze_output_dequant():
    """Analyze the output dequantization difference between Python and Dart."""
    print("\n" + "=" * 70)
    print("OUTPUT DEQUANTIZATION ANALYSIS")
    print("=" * 70)
    print(f"\nOutput quantizer params:")
    print(f"  scale:      {output_quant['scale']}")
    print(f"  zero_point: {output_quant['zero_point']}")
    print(f"  offset:     {output_quant['offset']}")

    print(f"\nDart formula:   float = (raw_int8 + offset - zero_point) * scale")
    print(f"                float = (raw_int8 + {output_quant['offset']} - {output_quant['zero_point']}) * {output_quant['scale']:.6f}")
    print(f"\nPython formula: float = (raw_int8 - zero_point) * scale")
    print(f"                float = (raw_int8 - {output_quant['zero_point']}) * {output_quant['scale']:.6f}")

    # Simulate: what if all 5 output classes return the same raw value?
    print(f"\nExample raw outputs and their dequantized values:")
    print(f"  {'raw_int8':>10} | {'Dart':>12} | {'Python (no offset)':>20} | {'Diff':>10}")
    print(f"  {'-' * 60}")
    for raw in [-128, -64, -1, 0, 1, 64, 127]:
        dart_val = (raw + output_quant["offset"] - output_quant["zero_point"]) * output_quant["scale"]
        py_val = (raw - output_quant["zero_point"]) * output_quant["scale"]
        print(f"  {raw:>10} | {dart_val:>12.6f} | {py_val:>20.6f} | {dart_val - py_val:>10.6f}")

    # The 127% confidence scenario
    print(f"\n  If a class gets raw_int8 = 70:")
    raw = 70
    dart_val = (raw + output_quant["offset"] - output_quant["zero_point"]) * output_quant["scale"]
    print(f"    Dart: ({raw} + {output_quant['offset']} - {output_quant['zero_point']}) * {output_quant['scale']:.6f} = {dart_val:.4f}")
    print(f"    As percentage: {dart_val * 100:.1f}%")

    # What raw value gives ~127%?
    target = 1.27
    needed_raw = target / output_quant["scale"] - output_quant["offset"] + output_quant["zero_point"]
    print(f"\n  To get 127% confidence, raw_int8 would need to be ~{needed_raw:.0f}")
    print(f"  (int8 range is -128 to 127)")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 70)
    print("PYTHON vs DART PREPROCESSING COMPARISON")
    print("=" * 70)

    # Load reference vectors if available
    ref_vectors = None
    if REF_VECTORS_PATH.exists():
        with open(REF_VECTORS_PATH) as f:
            ref_vectors = json.load(f)
        print(f"Loaded reference vectors from {REF_VECTORS_PATH}")

    all_results = {}

    for sentence in TEST_SENTENCES:
        print(f"\n{'─' * 70}")
        print(f"TEXT: \"{sentence}\"")
        print(f"{'─' * 70}")

        results = python_full_pipeline(sentence)
        all_results[sentence] = results

        # Tokenization
        if results["token_match"]:
            print(f"  Tokens: MATCH ({len(results['py_tokens'])} tokens)")
        else:
            print(f"  Tokens: MISMATCH!")
            print(f"    Python: {results['py_tokens']}")
            print(f"    Dart:   {results['dart_tokens']}")

        # TF-IDF
        print(f"  TF-IDF: nnz={results['tfidf_nnz']} (py) vs {results['dart_tfidf_nnz']} (dart)")
        print(f"    norm: {results['tfidf_norm']:.6f} (py) vs {results['dart_tfidf_norm']:.6f} (dart)")
        print(f"    max_diff: {results['tfidf_max_diff']:.2e}")

        # SVD
        print(f"  SVD:    max_diff: {results['svd_max_diff']:.2e}")

        # Normalized
        print(f"  L2norm: max_diff: {results['norm_max_diff']:.2e}")

        # Quantized
        print(f"  Quantized: {results['quant_mismatches']}/200 mismatches "
              f"(max diff: {results['quant_max_diff']})")
        print(f"    unique values: {results['dart_quant_unique']} "
              f"(most common: {results['dart_quant_most_common']})")

        # Compare with reference vectors
        if ref_vectors and sentence in ref_vectors:
            ref = ref_vectors[sentence]
            ref_vec = np.array(ref["vector"], dtype=np.float32)
            dart_vec = np.array(results["dart_vector"], dtype=np.float32)
            ref_diff = np.abs(ref_vec - dart_vec)
            print(f"  vs reference: max_diff={float(np.max(ref_diff)):.2e}")

    # Output dequantization
    analyze_output_dequant()

    # Summary
    print(f"\n{'=' * 70}")
    print("SUMMARY")
    print(f"{'=' * 70}")

    total_quant_mismatches = sum(r["quant_mismatches"] for r in all_results.values())
    max_norm_diff = max(r["norm_max_diff"] for r in all_results.values())
    all_tokens_match = all(r["token_match"] for r in all_results.values())

    print(f"  Tokenization: {'ALL MATCH' if all_tokens_match else 'MISMATCHES FOUND'}")
    print(f"  Max L2-norm vector diff: {max_norm_diff:.2e}")
    print(f"  Total quantized mismatches: {total_quant_mismatches} / {len(TEST_SENTENCES) * 200}")
    print(f"  Output dequant offset: {output_quant['offset']} "
          f"({'ZERO - safe' if output_quant['offset'] == 0 else 'NON-ZERO - check Dart handling!'})")


if __name__ == "__main__":
    main()
