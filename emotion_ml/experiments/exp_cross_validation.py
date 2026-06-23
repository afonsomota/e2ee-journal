"""
Experiment 1: 5-fold stratified cross-validation comparing:
  - Plain sklearn XGBoost
  - Concrete ML XGBoost n_bits=3
  - Concrete ML XGBoost n_bits=8

Reports mean accuracy, std, per-class F1, macro F1 for each.
"""

import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics import accuracy_score, f1_score, classification_report
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import LabelEncoder, Normalizer
from sklearn.utils.class_weight import compute_sample_weight
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from config import (
    LABELS,
    LSA_N_COMPONENTS,
    SPLITS_DIR,
    TFIDF_MAX_FEATURES,
    TFIDF_NGRAM_RANGE,
    XGB_MAX_DEPTH,
    XGB_N_ESTIMATORS,
)

from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier


def build_features(X_text_train, X_text_val):
    """Fit TF-IDF + LSA on train, transform both train and val."""
    tfidf = TfidfVectorizer(
        max_features=TFIDF_MAX_FEATURES,
        ngram_range=TFIDF_NGRAM_RANGE,
        sublinear_tf=True,
        strip_accents="unicode",
        min_df=5,
    )
    X_train_tfidf = tfidf.fit_transform(X_text_train)
    X_val_tfidf = tfidf.transform(X_text_val)

    svd = TruncatedSVD(n_components=LSA_N_COMPONENTS, random_state=42)
    normalizer = Normalizer()

    X_train_lsa = normalizer.fit_transform(svd.fit_transform(X_train_tfidf))
    X_val_lsa = normalizer.transform(svd.transform(X_val_tfidf))

    return X_train_lsa, X_val_lsa


def run_cv():
    # Load full training data
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    X_text = train_df["text"].values
    le = LabelEncoder()
    le.classes_ = np.array(LABELS)
    y = le.transform(train_df["label"].values)

    skf = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

    models = {
        "plain_xgb": {"type": "plain"},
        "concrete_n3": {"type": "concrete", "n_bits": 3},
        "concrete_n8": {"type": "concrete", "n_bits": 8},
    }

    results = {name: {"accuracies": [], "f1_macros": [], "f1_per_class": {l: [] for l in LABELS}}
               for name in models}

    for fold_idx, (train_idx, val_idx) in enumerate(skf.split(X_text, y)):
        print(f"\n{'='*60}")
        print(f"FOLD {fold_idx + 1}/5")
        print(f"{'='*60}")

        X_text_train, X_text_val = X_text[train_idx], X_text[val_idx]
        y_train, y_val = y[train_idx], y[val_idx]

        # Build features (re-fit each fold)
        X_train_lsa, X_val_lsa = build_features(X_text_train, X_text_val)
        sample_weights = compute_sample_weight("balanced", y_train)

        for name, cfg in models.items():
            t0 = time.time()
            if cfg["type"] == "plain":
                clf = XGBClassifier(
                    n_estimators=XGB_N_ESTIMATORS,
                    max_depth=XGB_MAX_DEPTH,
                    random_state=42,
                    use_label_encoder=False,
                    eval_metric="mlogloss",
                )
                clf.fit(X_train_lsa, y_train, sample_weight=sample_weights)
                y_pred = clf.predict(X_val_lsa)
            else:
                clf = FHEXGBClassifier(
                    n_bits=cfg["n_bits"],
                    n_estimators=XGB_N_ESTIMATORS,
                    max_depth=XGB_MAX_DEPTH,
                )
                clf.fit(X_train_lsa, y_train, sample_weight=sample_weights)
                y_pred = clf.predict(X_val_lsa)

            acc = accuracy_score(y_val, y_pred)
            f1_macro = f1_score(y_val, y_pred, average="macro")
            f1_per = f1_score(y_val, y_pred, average=None, labels=list(range(len(LABELS))))

            results[name]["accuracies"].append(acc)
            results[name]["f1_macros"].append(f1_macro)
            for i, label in enumerate(LABELS):
                results[name]["f1_per_class"][label].append(f1_per[i])

            elapsed = time.time() - t0
            print(f"  {name}: acc={acc:.4f}, f1_macro={f1_macro:.4f} ({elapsed:.1f}s)")

    # Summarize
    print(f"\n{'='*60}")
    print("SUMMARY (5-fold CV)")
    print(f"{'='*60}")

    summary = {}
    for name in models:
        r = results[name]
        acc_mean = np.mean(r["accuracies"])
        acc_std = np.std(r["accuracies"])
        f1_mean = np.mean(r["f1_macros"])
        f1_std = np.std(r["f1_macros"])

        per_class = {}
        for label in LABELS:
            per_class[label] = {
                "mean": float(np.mean(r["f1_per_class"][label])),
                "std": float(np.std(r["f1_per_class"][label])),
            }

        summary[name] = {
            "accuracy_mean": float(acc_mean),
            "accuracy_std": float(acc_std),
            "f1_macro_mean": float(f1_mean),
            "f1_macro_std": float(f1_std),
            "f1_per_class": per_class,
        }

        print(f"\n{name}:")
        print(f"  Accuracy: {acc_mean:.4f} +/- {acc_std:.4f}")
        print(f"  Macro F1: {f1_mean:.4f} +/- {f1_std:.4f}")
        print(f"  Per-class F1:")
        for label in LABELS:
            m = per_class[label]["mean"]
            s = per_class[label]["std"]
            print(f"    {label:>10s}: {m:.4f} +/- {s:.4f}")

    # Also evaluate on held-out test set with full training data
    print(f"\n{'='*60}")
    print("HELD-OUT TEST SET (trained on full train split)")
    print(f"{'='*60}")

    test_df = pd.read_csv(SPLITS_DIR / "test.csv")
    X_text_test = test_df["text"].values
    y_test = le.transform(test_df["label"].values)

    X_train_lsa, X_test_lsa = build_features(X_text, X_text_test)
    sample_weights_full = compute_sample_weight("balanced", y)

    test_results = {}
    for name, cfg in models.items():
        if cfg["type"] == "plain":
            clf = XGBClassifier(
                n_estimators=XGB_N_ESTIMATORS,
                max_depth=XGB_MAX_DEPTH,
                random_state=42,
                use_label_encoder=False,
                eval_metric="mlogloss",
            )
            clf.fit(X_train_lsa, y, sample_weight=sample_weights_full)
            y_pred = clf.predict(X_test_lsa)
        else:
            clf = FHEXGBClassifier(
                n_bits=cfg["n_bits"],
                n_estimators=XGB_N_ESTIMATORS,
                max_depth=XGB_MAX_DEPTH,
            )
            clf.fit(X_train_lsa, y, sample_weight=sample_weights_full)
            y_pred = clf.predict(X_test_lsa)

        acc = accuracy_score(y_test, y_pred)
        f1_macro = f1_score(y_test, y_pred, average="macro")
        f1_per = f1_score(y_test, y_pred, average=None, labels=list(range(len(LABELS))))

        test_results[name] = {
            "accuracy": float(acc),
            "f1_macro": float(f1_macro),
            "f1_per_class": {label: float(f1_per[i]) for i, label in enumerate(LABELS)},
        }

        print(f"\n{name}:")
        print(f"  Accuracy: {acc:.4f}")
        print(f"  Macro F1: {f1_macro:.4f}")
        print(f"  Per-class F1:")
        for i, label in enumerate(LABELS):
            print(f"    {label:>10s}: {f1_per[i]:.4f}")
        print(f"\n  Classification Report:")
        print(classification_report(y_test, y_pred, target_names=LABELS))

    # Save results
    output = {"cv_5fold": summary, "test_set": test_results}
    out_path = Path(__file__).parent / "cv_results.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    run_cv()
