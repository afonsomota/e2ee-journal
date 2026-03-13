"""Verify FHE client/server protocol works with real samples."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from concrete.ml.deployment import FHEModelClient, FHEModelServer

from config import ARTIFACTS_DIR, LABELS, SPLITS_DIR


def test_fhe(n_samples: int = 10):
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    test_df = pd.read_csv(SPLITS_DIR / "test.csv")
    label_to_int = {l: i for i, l in enumerate(LABELS)}

    texts = test_df["text"].values[:n_samples]
    y_true = [label_to_int[l] for l in test_df["label"].values[:n_samples]]

    # Feature pipeline: text -> TF-IDF -> LSA -> normalize
    X_tfidf = tfidf.transform(texts)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    # Set up FHE client/server
    fhe_dir = str(ARTIFACTS_DIR / "fhe_model")
    key_dir = str(ARTIFACTS_DIR / "fhe_keys")

    client = FHEModelClient(path_dir=fhe_dir, key_dir=key_dir)
    server = FHEModelServer(path_dir=fhe_dir)
    server.load()

    eval_keys = client.get_serialized_evaluation_keys()
    print(f"Eval key size: {len(eval_keys) / 1024 / 1024:.1f} MB")

    correct = 0
    for i in range(n_samples):
        sample = X_lsa[i : i + 1]

        # Client encrypts
        encrypted = client.quantize_encrypt_serialize(sample)

        # Server runs FHE inference
        encrypted_result = server.run(encrypted, eval_keys)

        # Client decrypts
        result = client.deserialize_decrypt_dequantize(encrypted_result)
        pred = int(np.argmax(result))

        true_label = LABELS[y_true[i]]
        pred_label = LABELS[pred]
        match = "OK" if true_label == pred_label else "miss"
        if true_label == pred_label:
            correct += 1

        print(f"  [{i + 1:2d}] true={true_label:<10} pred={pred_label:<10} {match}")

    print(f"\nAccuracy: {correct}/{n_samples} ({correct / n_samples * 100:.0f}%)")
    print("FHE client/server protocol verified.")


if __name__ == "__main__":
    test_fhe()
