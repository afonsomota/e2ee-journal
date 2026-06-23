"""
Experiment: XGBoost hyperparameter grid — FHE quantized vs plain sklearn.

Tests meaningful hyperparameter combos to show how model complexity
interacts with FHE quantization (n_bits=3). Uses pre-fitted TF-IDF/LSA
artifacts (no re-fitting). Evaluates on full test set (5,427 samples).
"""

import json
import sys
import time
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import accuracy_score, f1_score
from sklearn.preprocessing import LabelEncoder
from sklearn.utils.class_weight import compute_sample_weight
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from config import ARTIFACTS_DIR, FHE_N_BITS, LABELS, SPLITS_DIR

from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier

# ── Hyperparameter grid ──────────────────────────────────────────────────────

GRID = [
    {"n_estimators": 10, "max_depth": 2, "tag": "minimal"},
    {"n_estimators": 50, "max_depth": 3, "tag": "current_config"},
    {"n_estimators": 100, "max_depth": 3, "tag": "more_trees"},
    {"n_estimators": 50, "max_depth": 5, "tag": "deeper"},
    {"n_estimators": 100, "max_depth": 5, "tag": "larger"},
    {"n_estimators": 200, "max_depth": 3, "tag": "many_shallow"},
]


def load_data():
    """Load train/test splits and pre-fitted feature transformers."""
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    test_df = pd.read_csv(SPLITS_DIR / "test.csv")

    le = LabelEncoder()
    le.classes_ = np.array(LABELS)
    y_train = le.transform(train_df["label"].values)
    y_test = le.transform(test_df["label"].values)

    # Load pre-fitted artifacts
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    # Transform (don't re-fit)
    X_train = normalizer.transform(svd.transform(tfidf.transform(train_df["text"].values)))
    X_test = normalizer.transform(svd.transform(tfidf.transform(test_df["text"].values)))

    sample_weights = compute_sample_weight("balanced", y_train)

    print(f"Train: {X_train.shape[0]} samples, Test: {X_test.shape[0]} samples")
    print(f"Features: {X_train.shape[1]}, Classes: {len(LABELS)}")

    return X_train, y_train, X_test, y_test, sample_weights


def evaluate(y_true, y_pred):
    """Compute accuracy, macro F1, and per-class F1."""
    acc = accuracy_score(y_true, y_pred)
    f1_macro = f1_score(y_true, y_pred, average="macro")
    f1_per = f1_score(y_true, y_pred, average=None, labels=list(range(len(LABELS))))
    per_class = {label: float(f1_per[i]) for i, label in enumerate(LABELS)}
    return {
        "accuracy": float(acc),
        "f1_macro": float(f1_macro),
        "f1_per_class": per_class,
    }


def run_grid():
    X_train, y_train, X_test, y_test, sample_weights = load_data()

    results = {"fhe_n_bits": FHE_N_BITS, "test_samples": len(y_test), "configs": []}

    for combo in GRID:
        n_est = combo["n_estimators"]
        depth = combo["max_depth"]
        tag = combo["tag"]
        config_key = f"n{n_est}_d{depth}"

        print(f"\n{'='*60}")
        print(f"Config: n_estimators={n_est}, max_depth={depth} ({tag})")
        print(f"{'='*60}")

        entry = {
            "n_estimators": n_est,
            "max_depth": depth,
            "tag": tag,
        }

        # ── Plain sklearn XGBoost ────────────────────────────────────────
        print(f"  Training plain XGBoost...", end=" ", flush=True)
        t0 = time.time()
        plain = XGBClassifier(
            n_estimators=n_est,
            max_depth=depth,
            random_state=42,
            use_label_encoder=False,
            eval_metric="mlogloss",
        )
        plain.fit(X_train, y_train, sample_weight=sample_weights)
        y_pred_plain = plain.predict(X_test)
        plain_time = time.time() - t0
        plain_metrics = evaluate(y_test, y_pred_plain)
        entry["plain"] = {**plain_metrics, "train_time_s": round(plain_time, 1)}
        print(f"acc={plain_metrics['accuracy']:.4f}, f1={plain_metrics['f1_macro']:.4f} ({plain_time:.1f}s)")

        # ── FHE XGBoost (n_bits=3, clear predict) ───────────────────────
        print(f"  Training FHE XGBoost (n_bits={FHE_N_BITS})...", end=" ", flush=True)
        t0 = time.time()
        fhe = FHEXGBClassifier(
            n_bits=FHE_N_BITS,
            n_estimators=n_est,
            max_depth=depth,
        )
        fhe.fit(X_train, y_train, sample_weight=sample_weights)
        y_pred_fhe = fhe.predict(X_test)
        fhe_time = time.time() - t0
        fhe_metrics = evaluate(y_test, y_pred_fhe)
        entry["fhe"] = {**fhe_metrics, "train_time_s": round(fhe_time, 1)}
        print(f"acc={fhe_metrics['accuracy']:.4f}, f1={fhe_metrics['f1_macro']:.4f} ({fhe_time:.1f}s)")

        # ── Delta ────────────────────────────────────────────────────────
        acc_delta = fhe_metrics["accuracy"] - plain_metrics["accuracy"]
        f1_delta = fhe_metrics["f1_macro"] - plain_metrics["f1_macro"]
        entry["delta_accuracy"] = round(acc_delta, 4)
        entry["delta_f1_macro"] = round(f1_delta, 4)
        print(f"  Delta (FHE - plain): acc={acc_delta:+.4f}, f1={f1_delta:+.4f}")

        results["configs"].append(entry)

    # ── Summary table ────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print("SUMMARY TABLE")
    print(f"{'='*60}")
    header = f"{'Config':<20} {'Plain Acc':>10} {'Plain F1':>10} {'FHE Acc':>10} {'FHE F1':>10} {'Δ Acc':>8} {'Δ F1':>8}"
    print(header)
    print("-" * len(header))
    for entry in results["configs"]:
        tag = entry["tag"]
        pa = entry["plain"]["accuracy"]
        pf = entry["plain"]["f1_macro"]
        fa = entry["fhe"]["accuracy"]
        ff = entry["fhe"]["f1_macro"]
        da = entry["delta_accuracy"]
        df = entry["delta_f1_macro"]
        print(f"{tag:<20} {pa:>10.4f} {pf:>10.4f} {fa:>10.4f} {ff:>10.4f} {da:>+8.4f} {df:>+8.4f}")

    # ── Per-class breakdown ──────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print("PER-CLASS F1 (FHE)")
    print(f"{'='*60}")
    header2 = f"{'Config':<20}" + "".join(f" {l:>10}" for l in LABELS)
    print(header2)
    print("-" * len(header2))
    for entry in results["configs"]:
        tag = entry["tag"]
        vals = "".join(f" {entry['fhe']['f1_per_class'][l]:>10.4f}" for l in LABELS)
        print(f"{tag:<20}{vals}")

    # ── Save ─────────────────────────────────────────────────────────────────
    out_path = Path(__file__).parent / "exp_hyperparameter_grid_results.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    run_grid()
