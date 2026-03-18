"""Compare plain (sklearn) vs FHE (encrypted) predictions on the same samples.

Uses plain sklearn XGBClassifier (not Concrete-ML wrapper) for the plain
baseline to avoid memory issues, then compares against FHE inference using
the pre-compiled model artifacts.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import classification_report
from sklearn.utils.class_weight import compute_sample_weight
from xgboost import XGBClassifier

from config import (
    ARTIFACTS_DIR, LABELS, SPLITS_DIR,
    XGB_N_ESTIMATORS, XGB_MAX_DEPTH,
)

PLAIN_MODEL_PATH = ARTIFACTS_DIR / "plain_xgb.pkl"


def get_plain_model(X_train, y_train, sample_weights):
    """Train or load a plain sklearn XGBClassifier (no FHE wrapper)."""
    if PLAIN_MODEL_PATH.exists():
        print(f"Loading cached plain model from {PLAIN_MODEL_PATH}", flush=True)
        return joblib.load(PLAIN_MODEL_PATH)

    print("Training plain XGBClassifier (sklearn, no FHE)...", flush=True)
    model = XGBClassifier(
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
        use_label_encoder=False,
        eval_metric="mlogloss",
    )
    model.fit(X_train, y_train, sample_weight=sample_weights)
    joblib.dump(model, PLAIN_MODEL_PATH)
    print(f"Saved plain model to {PLAIN_MODEL_PATH}", flush=True)
    return model


def run_comparison(n_samples: int = 10):
    # Load feature pipeline
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    # Load data
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    test_df = pd.read_csv(SPLITS_DIR / "test.csv")
    label_to_int = {l: i for i, l in enumerate(LABELS)}

    # Stratified sampling: pick samples across all classes
    sampled = test_df.groupby("label", group_keys=False).apply(
        lambda g: g.sample(n=min(len(g), max(1, n_samples // len(LABELS))),
                           random_state=42)
    ).reset_index(drop=True)
    if len(sampled) < n_samples:
        remaining = test_df.drop(sampled.index).sample(
            n=n_samples - len(sampled), random_state=42)
        sampled = pd.concat([sampled, remaining]).reset_index(drop=True)
    sampled = sampled.head(n_samples)

    texts = sampled["text"].values
    y_true = np.array([label_to_int[l] for l in sampled["label"].values])
    y_true_str = sampled["label"].values

    print(f"Test samples: {n_samples}")
    print(f"Class distribution: {dict(zip(*np.unique(y_true_str, return_counts=True)))}")

    # Vectorize test samples
    X_tfidf = tfidf.transform(texts)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    # ── Plain model ─────────────────────────────────────────────────────────
    print("\n" + "=" * 70)
    print("PLAIN MODEL (sklearn XGBClassifier, no FHE)")
    print("=" * 70)

    X_train_tfidf = tfidf.transform(train_df["text"].values)
    X_train_lsa = normalizer.transform(svd.transform(X_train_tfidf))
    y_train = np.array([label_to_int[l] for l in train_df["label"].values])
    sample_weights = compute_sample_weight("balanced", y_train)

    plain_model = get_plain_model(X_train_lsa, y_train, sample_weights)

    t0 = time.time()
    y_pred_plain = plain_model.predict(X_lsa)
    plain_time = time.time() - t0
    y_pred_plain_str = np.array([LABELS[i] for i in y_pred_plain])

    y_proba_plain = plain_model.predict_proba(X_lsa)

    print(f"Plain inference: {plain_time:.4f}s for {n_samples} samples "
          f"({plain_time / n_samples * 1000:.1f}ms/sample)", flush=True)

    # ── FHE model ───────────────────────────────────────────────────────────
    print("\n" + "=" * 70)
    print("FHE ENCRYPTED INFERENCE")
    print("=" * 70, flush=True)

    from concrete.ml.deployment import FHEModelClient, FHEModelServer

    fhe_dir = str(ARTIFACTS_DIR / "fhe_model")
    key_dir = str(ARTIFACTS_DIR / "fhe_keys")

    client = FHEModelClient(path_dir=fhe_dir, key_dir=key_dir)
    server = FHEModelServer(path_dir=fhe_dir)
    server.load()
    eval_keys = client.get_serialized_evaluation_keys()

    y_pred_fhe = []
    y_scores_fhe = []
    fhe_times = []

    for i in range(n_samples):
        sample = X_lsa[i:i + 1]

        t0 = time.time()
        encrypted = client.quantize_encrypt_serialize(sample)
        encrypted_result = server.run(encrypted, eval_keys)
        result = client.deserialize_decrypt_dequantize(encrypted_result)
        elapsed = time.time() - t0

        pred = int(np.argmax(result))
        y_pred_fhe.append(pred)
        y_scores_fhe.append(result[0])
        fhe_times.append(elapsed)

        true_l = LABELS[y_true[i]]
        pred_l = LABELS[pred]
        plain_l = y_pred_plain_str[i]
        match_true = "OK" if pred_l == true_l else "miss"
        match_plain = "same" if pred_l == plain_l else "DIFF"

        print(f"  [{i + 1:2d}] true={true_l:<10} plain={plain_l:<10} "
              f"fhe={pred_l:<10} {match_true} ({match_plain}) "
              f"[{elapsed:.1f}s]", flush=True)

    y_pred_fhe = np.array(y_pred_fhe)
    y_pred_fhe_str = np.array([LABELS[i] for i in y_pred_fhe])

    # ── Comparison Report ───────────────────────────────────────────────────
    print("\n" + "=" * 70)
    print("RESULTS COMPARISON")
    print("=" * 70)

    # Agreement
    agreement = np.sum(y_pred_plain_str == y_pred_fhe_str)
    print(f"\nPlain vs FHE agreement: {agreement}/{n_samples} "
          f"({agreement / n_samples * 100:.0f}%)")

    # Accuracy
    plain_acc = np.mean(y_pred_plain_str == y_true_str)
    fhe_acc = np.mean(y_pred_fhe_str == y_true_str)
    print(f"Plain accuracy:  {plain_acc:.2%}")
    print(f"FHE accuracy:    {fhe_acc:.2%}")

    # Per-class report: Plain
    print(f"\n{'─' * 35} PLAIN {'─' * 35}")
    print(classification_report(y_true_str, y_pred_plain_str,
                                labels=LABELS, zero_division=0))

    # Per-class report: FHE
    print(f"{'─' * 36} FHE {'─' * 36}")
    print(classification_report(y_true_str, y_pred_fhe_str,
                                labels=LABELS, zero_division=0))

    # Timing comparison
    print(f"\n{'─' * 30} TIMING COMPARISON {'─' * 30}")
    mean_fhe = np.mean(fhe_times)
    mean_plain = plain_time / n_samples
    print(f"Plain:  {mean_plain * 1000:.1f} ms/sample")
    print(f"FHE:    {mean_fhe:.1f} s/sample")
    print(f"Slowdown: {mean_fhe / mean_plain:.0f}x")
    print(f"Total FHE wall time: {sum(fhe_times):.0f}s ({sum(fhe_times) / 60:.1f} min)")

    # Score comparison (show raw scores for mismatches)
    mismatches = np.where(y_pred_plain_str != y_pred_fhe_str)[0]
    if len(mismatches) > 0:
        print(f"\n{'─' * 30} MISMATCHED SAMPLES {'─' * 30}")
        for idx in mismatches:
            print(f"\n  Sample {idx + 1}: \"{texts[idx][:80]}\"")
            print(f"    True:  {LABELS[y_true[idx]]}")
            print(f"    Plain: {y_pred_plain_str[idx]} "
                  f"(proba: {y_proba_plain[idx]})")
            print(f"    FHE:   {y_pred_fhe_str[idx]} "
                  f"(raw scores: {y_scores_fhe[idx]})")
    else:
        print("\nNo mismatches — plain and FHE predictions are identical.")


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    run_comparison(n)
