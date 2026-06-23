"""
Experiment: LSA dimensions + n_bits=8 interaction.

Tests how increasing LSA components (50 vs 200) interacts with n_bits=8
quantization. Re-fits TF-IDF/LSA/Normalizer per config since LSA dimension
varies. Evaluates both plain XGBoost and Concrete ML FHE XGBoost on the
full test set (5,427 samples) using .predict() clear mode.
"""

import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics import accuracy_score, f1_score
from sklearn.preprocessing import LabelEncoder, Normalizer
from sklearn.utils.class_weight import compute_sample_weight
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from config import LABELS, SPLITS_DIR

from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier

# ── Experiment grid ─────────────────────────────────────────────────────────

GRID = [
    {"lsa": 50,  "n_estimators": 50,  "max_depth": 3, "n_bits": 8, "tag": "cur_cfg_8bit"},
    {"lsa": 50,  "n_estimators": 100, "max_depth": 5, "n_bits": 8, "tag": "best_grid_8bit"},
    {"lsa": 200, "n_estimators": 200, "max_depth": 3, "n_bits": 8, "tag": "old_bench_8bit"},
    {"lsa": 200, "n_estimators": 200, "max_depth": 3, "n_bits": 3, "tag": "old_bench_3bit"},
    {"lsa": 200, "n_estimators": 50,  "max_depth": 3, "n_bits": 3, "tag": "more_lsa_3bit"},
    {"lsa": 200, "n_estimators": 50,  "max_depth": 3, "n_bits": 8, "tag": "more_lsa_8bit"},
]

# ── TF-IDF params (constant across all configs) ────────────────────────────

TFIDF_KWARGS = dict(
    max_features=5000,
    ngram_range=(1, 2),
    sublinear_tf=True,
    strip_accents="unicode",
    min_df=5,
)


def load_raw_data():
    """Load train/test CSVs and encode labels."""
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    test_df = pd.read_csv(SPLITS_DIR / "test.csv")

    le = LabelEncoder()
    le.classes_ = np.array(LABELS)
    y_train = le.transform(train_df["label"].values)
    y_test = le.transform(test_df["label"].values)

    sample_weights = compute_sample_weight("balanced", y_train)

    print(f"Train: {len(y_train)} samples, Test: {len(y_test)} samples")
    return train_df["text"].values, y_train, test_df["text"].values, y_test, sample_weights


def build_features(texts_train, texts_test, n_components):
    """Fit TF-IDF + TruncatedSVD + L2 normalizer and transform both sets."""
    tfidf = TfidfVectorizer(**TFIDF_KWARGS)
    X_train_tfidf = tfidf.fit_transform(texts_train)
    X_test_tfidf = tfidf.transform(texts_test)

    svd = TruncatedSVD(n_components=n_components, random_state=42)
    X_train_svd = svd.fit_transform(X_train_tfidf)
    X_test_svd = svd.transform(X_test_tfidf)

    normalizer = Normalizer(norm="l2")
    X_train = normalizer.fit_transform(X_train_svd)
    X_test = normalizer.transform(X_test_svd)

    return X_train, X_test


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


def run_experiment():
    texts_train, y_train, texts_test, y_test, sample_weights = load_raw_data()

    # Cache features by LSA dimension to avoid redundant re-fitting
    feature_cache = {}
    results = {"test_samples": len(y_test), "configs": []}

    for combo in GRID:
        lsa = combo["lsa"]
        n_est = combo["n_estimators"]
        depth = combo["max_depth"]
        n_bits = combo["n_bits"]
        tag = combo["tag"]

        print(f"\n{'='*70}")
        print(f"Config: LSA={lsa}, n_estimators={n_est}, max_depth={depth}, n_bits={n_bits} ({tag})")
        print(f"{'='*70}")

        # Build or reuse features for this LSA dimension
        if lsa not in feature_cache:
            print(f"  Fitting TF-IDF + LSA({lsa}) + L2 norm...", end=" ", flush=True)
            t0 = time.time()
            X_train, X_test = build_features(texts_train, texts_test, lsa)
            feat_time = time.time() - t0
            feature_cache[lsa] = (X_train, X_test)
            print(f"done ({feat_time:.1f}s, features={X_train.shape[1]})")
        else:
            X_train, X_test = feature_cache[lsa]
            print(f"  Using cached LSA({lsa}) features ({X_train.shape[1]} dims)")

        entry = {
            "lsa_components": lsa,
            "n_estimators": n_est,
            "max_depth": depth,
            "n_bits": n_bits,
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

        # ── FHE XGBoost (clear predict) ─────────────────────────────────
        print(f"  Training FHE XGBoost (n_bits={n_bits})...", end=" ", flush=True)
        t0 = time.time()
        fhe = FHEXGBClassifier(
            n_bits=n_bits,
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
    print(f"\n{'='*90}")
    print("SUMMARY TABLE")
    print(f"{'='*90}")
    header = (
        f"{'Tag':<20} {'LSA':>4} {'nEst':>5} {'Dep':>4} {'nB':>3}"
        f" {'Plain Acc':>10} {'Plain F1':>10}"
        f" {'FHE Acc':>10} {'FHE F1':>10}"
        f" {'d_Acc':>8} {'d_F1':>8}"
    )
    print(header)
    print("-" * len(header))
    for e in results["configs"]:
        print(
            f"{e['tag']:<20} {e['lsa_components']:>4} {e['n_estimators']:>5} {e['max_depth']:>4} {e['n_bits']:>3}"
            f" {e['plain']['accuracy']:>10.4f} {e['plain']['f1_macro']:>10.4f}"
            f" {e['fhe']['accuracy']:>10.4f} {e['fhe']['f1_macro']:>10.4f}"
            f" {e['delta_accuracy']:>+8.4f} {e['delta_f1_macro']:>+8.4f}"
        )

    # ── Per-class F1 breakdown (FHE) ────────────────────────────────────────
    print(f"\n{'='*90}")
    print("PER-CLASS F1 (FHE)")
    print(f"{'='*90}")
    header2 = f"{'Tag':<20} {'nB':>3}" + "".join(f" {l:>10}" for l in LABELS)
    print(header2)
    print("-" * len(header2))
    for e in results["configs"]:
        vals = "".join(f" {e['fhe']['f1_per_class'][l]:>10.4f}" for l in LABELS)
        print(f"{e['tag']:<20} {e['n_bits']:>3}{vals}")

    # ── Save ─────────────────────────────────────────────────────────────────
    out_path = Path(__file__).parent / "exp_lsa_and_nbits8_results.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    run_experiment()
