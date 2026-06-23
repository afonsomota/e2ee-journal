"""
Experiment 2: Timing comparison on 20 test samples.
  - Plain sklearn XGBoost predict time
  - Concrete ML n_bits=3 predict time (clear mode)
  - Concrete ML n_bits=8 predict time (clear mode)

Measures per-sample and total prediction times.
"""

import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import TfidfVectorizer
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

N_SAMPLES = 20
N_WARMUP = 3
N_REPEATS = 5


def main():
    # Load data
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    test_df = pd.read_csv(SPLITS_DIR / "test.csv")

    le = LabelEncoder()
    le.classes_ = np.array(LABELS)

    X_text_train = train_df["text"].values
    y_train = le.transform(train_df["label"].values)

    X_text_test = test_df["text"].values[:N_SAMPLES]
    y_test = le.transform(test_df["label"].values[:N_SAMPLES])

    # Build features
    print("Building TF-IDF + LSA features...")
    tfidf = TfidfVectorizer(
        max_features=TFIDF_MAX_FEATURES,
        ngram_range=TFIDF_NGRAM_RANGE,
        sublinear_tf=True,
        strip_accents="unicode",
        min_df=5,
    )
    X_train_tfidf = tfidf.fit_transform(X_text_train)
    X_test_tfidf = tfidf.transform(X_text_test)

    svd = TruncatedSVD(n_components=LSA_N_COMPONENTS, random_state=42)
    normalizer = Normalizer()
    X_train_lsa = normalizer.fit_transform(svd.fit_transform(X_train_tfidf))
    X_test_lsa = normalizer.transform(svd.transform(X_test_tfidf))

    sample_weights = compute_sample_weight("balanced", y_train)

    # Also time the feature pipeline itself
    print("Timing feature extraction pipeline...")
    feature_times = []
    for _ in range(N_REPEATS):
        t0 = time.perf_counter()
        X_tmp = tfidf.transform(X_text_test)
        X_tmp = normalizer.transform(svd.transform(X_tmp))
        feature_times.append(time.perf_counter() - t0)
    feature_time_mean = np.mean(feature_times)
    feature_time_per_sample = feature_time_mean / N_SAMPLES
    print(f"  Feature extraction: {feature_time_mean*1000:.2f} ms total, "
          f"{feature_time_per_sample*1000:.3f} ms/sample")

    # Train all models
    models = {}

    print("\nTraining plain XGBoost...")
    plain_clf = XGBClassifier(
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
        random_state=42,
        use_label_encoder=False,
        eval_metric="mlogloss",
    )
    plain_clf.fit(X_train_lsa, y_train, sample_weight=sample_weights)
    models["plain_xgb"] = plain_clf

    print("Training Concrete ML n_bits=3...")
    fhe3_clf = FHEXGBClassifier(
        n_bits=3,
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
    )
    fhe3_clf.fit(X_train_lsa, y_train, sample_weight=sample_weights)
    models["concrete_n3"] = fhe3_clf

    print("Training Concrete ML n_bits=8...")
    fhe8_clf = FHEXGBClassifier(
        n_bits=8,
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
    )
    fhe8_clf.fit(X_train_lsa, y_train, sample_weight=sample_weights)
    models["concrete_n8"] = fhe8_clf

    # Timing
    print(f"\nTiming predictions on {N_SAMPLES} samples ({N_WARMUP} warmup + {N_REPEATS} timed runs)...")
    results = {}

    for name, clf in models.items():
        # Warmup
        for _ in range(N_WARMUP):
            clf.predict(X_test_lsa)

        # Timed runs
        times = []
        for _ in range(N_REPEATS):
            t0 = time.perf_counter()
            clf.predict(X_test_lsa)
            elapsed = time.perf_counter() - t0
            times.append(elapsed)

        total_mean = np.mean(times)
        total_std = np.std(times)
        per_sample = total_mean / N_SAMPLES

        results[name] = {
            "total_time_ms": float(total_mean * 1000),
            "total_std_ms": float(total_std * 1000),
            "per_sample_ms": float(per_sample * 1000),
            "n_samples": N_SAMPLES,
            "n_repeats": N_REPEATS,
        }

        print(f"\n  {name}:")
        print(f"    Total ({N_SAMPLES} samples): {total_mean*1000:.2f} +/- {total_std*1000:.2f} ms")
        print(f"    Per sample: {per_sample*1000:.3f} ms")

    # Also time single-sample predictions
    print(f"\nSingle-sample prediction timing ({N_REPEATS} repeats)...")
    single_sample = X_test_lsa[0:1]
    for name, clf in models.items():
        times = []
        for _ in range(N_WARMUP):
            clf.predict(single_sample)
        for _ in range(N_REPEATS * 3):
            t0 = time.perf_counter()
            clf.predict(single_sample)
            times.append(time.perf_counter() - t0)

        mean_t = np.mean(times) * 1000
        results[name]["single_sample_ms"] = float(mean_t)
        print(f"  {name}: {mean_t:.3f} ms")

    # Add feature pipeline timing
    results["feature_pipeline"] = {
        "total_time_ms": float(feature_time_mean * 1000),
        "per_sample_ms": float(feature_time_per_sample * 1000),
        "n_samples": N_SAMPLES,
    }

    # Summary table
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"{'Model':<20} {'Total (ms)':<15} {'Per-sample (ms)':<18} {'Single (ms)':<12}")
    print(f"{'-'*65}")
    for name in ["plain_xgb", "concrete_n3", "concrete_n8"]:
        r = results[name]
        print(f"{name:<20} {r['total_time_ms']:>10.2f}     {r['per_sample_ms']:>12.3f}      {r['single_sample_ms']:>8.3f}")
    print(f"\nFeature pipeline: {results['feature_pipeline']['total_time_ms']:.2f} ms total, "
          f"{results['feature_pipeline']['per_sample_ms']:.3f} ms/sample")

    # Save
    out_path = Path(__file__).parent / "timing_results.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    main()
