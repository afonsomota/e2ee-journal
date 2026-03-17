"""Quick timing analysis of FHE inference to determine sample budget for full eval."""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from concrete.ml.deployment import FHEModelClient, FHEModelServer

from config import ARTIFACTS_DIR, LABELS, SPLITS_DIR


def timing_analysis(n_samples: int = 5):
    # Load feature pipeline
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    test_df = pd.read_csv(SPLITS_DIR / "test.csv")
    texts = test_df["text"].values[:n_samples]

    # Vectorize
    X_tfidf = tfidf.transform(texts)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    # Set up FHE
    fhe_dir = str(ARTIFACTS_DIR / "fhe_model")
    key_dir = str(ARTIFACTS_DIR / "fhe_keys")

    print("Initializing FHE client/server...", flush=True)
    t0 = time.time()
    client = FHEModelClient(path_dir=fhe_dir, key_dir=key_dir)
    server = FHEModelServer(path_dir=fhe_dir)
    server.load()
    setup_time = time.time() - t0
    print(f"  Setup time: {setup_time:.2f}s", flush=True)

    t0 = time.time()
    eval_keys = client.get_serialized_evaluation_keys()
    keygen_time = time.time() - t0
    eval_key_mb = len(eval_keys) / 1024 / 1024
    print(f"  Keygen time: {keygen_time:.2f}s", flush=True)
    print(f"  Eval key size: {eval_key_mb:.1f} MB", flush=True)

    # Time each step per sample
    encrypt_times = []
    server_times = []
    decrypt_times = []
    total_times = []

    print(f"\nRunning {n_samples} samples...\n", flush=True)
    print(f"{'Sample':>6} | {'Encrypt':>10} | {'Server':>10} | {'Decrypt':>10} | {'Total':>10}", flush=True)
    print("-" * 60, flush=True)

    for i in range(n_samples):
        sample = X_lsa[i:i + 1]

        t0 = time.time()
        encrypted = client.quantize_encrypt_serialize(sample)
        t_enc = time.time() - t0

        t0 = time.time()
        encrypted_result = server.run(encrypted, eval_keys)
        t_srv = time.time() - t0

        t0 = time.time()
        result = client.deserialize_decrypt_dequantize(encrypted_result)
        t_dec = time.time() - t0

        t_total = t_enc + t_srv + t_dec

        encrypt_times.append(t_enc)
        server_times.append(t_srv)
        decrypt_times.append(t_dec)
        total_times.append(t_total)

        pred = LABELS[int(np.argmax(result))]
        print(f"{i + 1:>6} | {t_enc:>9.2f}s | {t_srv:>9.2f}s | {t_dec:>9.2f}s | {t_total:>9.2f}s  ({pred})", flush=True)

    # Summary
    print("\n" + "=" * 60, flush=True)
    print("TIMING SUMMARY", flush=True)
    print("=" * 60, flush=True)
    print(f"  Encrypt  — mean: {np.mean(encrypt_times):.2f}s, std: {np.std(encrypt_times):.2f}s", flush=True)
    print(f"  Server   — mean: {np.mean(server_times):.2f}s, std: {np.std(server_times):.2f}s", flush=True)
    print(f"  Decrypt  — mean: {np.mean(decrypt_times):.2f}s, std: {np.std(decrypt_times):.2f}s", flush=True)
    print(f"  Total    — mean: {np.mean(total_times):.2f}s, std: {np.std(total_times):.2f}s", flush=True)

    mean_total = np.mean(total_times)
    print(f"\n  Encrypted input size:  {len(encrypted) / 1024:.1f} KB", flush=True)
    print(f"  Encrypted output size: {len(encrypted_result) / 1024:.1f} KB", flush=True)

    # Projections
    print("\n" + "=" * 60, flush=True)
    print("TIME PROJECTIONS", flush=True)
    print("=" * 60, flush=True)
    for n in [10, 25, 50, 100, 200, 500, 1000]:
        projected = mean_total * n
        hours = projected / 3600
        mins = projected / 60
        if hours >= 1:
            print(f"  {n:>5} samples → ~{hours:.1f} hours", flush=True)
        else:
            print(f"  {n:>5} samples → ~{mins:.1f} minutes", flush=True)


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    timing_analysis(n)
