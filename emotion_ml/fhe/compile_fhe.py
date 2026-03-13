"""Compile the trained XGBoost classifier to FHE using Concrete-ML.

This script trains and compiles in one step since the Concrete-ML
XGBClassifier must be compiled from the same object that was fit.
"""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.preprocessing import LabelEncoder, Normalizer
from sklearn.utils.class_weight import compute_sample_weight

from concrete.ml.deployment import FHEModelDev
from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier

from config import (
    ARTIFACTS_DIR,
    FHE_COMPILE_SAMPLES,
    FHE_N_BITS,
    LABELS,
    LSA_N_COMPONENTS,
    SPLITS_DIR,
    TFIDF_MAX_FEATURES,
    TFIDF_NGRAM_RANGE,
    XGB_MAX_DEPTH,
    XGB_N_ESTIMATORS,
)


def compile_fhe():
    print("Loading data...", flush=True)
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    label_to_int = {l: i for i, l in enumerate(LABELS)}
    y_train = np.array([label_to_int[l] for l in train_df["label"].values])

    # Load pre-fitted feature pipeline
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    X_tfidf = tfidf.transform(train_df["text"].values)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    print(f"Input shape: {X_lsa.shape}", flush=True)
    print(f"FHE config: n_bits={FHE_N_BITS}, compile_samples={FHE_COMPILE_SAMPLES}", flush=True)

    # Train XGBoost
    sample_weights = compute_sample_weight("balanced", y_train)
    model = FHEXGBClassifier(
        n_bits=FHE_N_BITS,
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
    )
    print("Training XGBClassifier...", flush=True)
    model.fit(X_lsa, y_train, sample_weight=sample_weights)

    # Compile
    rng = np.random.RandomState(42)
    idx = rng.choice(len(X_lsa), FHE_COMPILE_SAMPLES, replace=False)
    print("Compiling FHE circuit...", flush=True)
    model.compile(X_lsa[idx])

    # Save FHE deployment artifacts
    fhe_dir = ARTIFACTS_DIR / "fhe_model"
    if fhe_dir.exists():
        shutil.rmtree(fhe_dir)
    fhe_dir.mkdir(parents=True, exist_ok=True)

    print(f"Saving to {fhe_dir}...", flush=True)
    dev = FHEModelDev(path_dir=str(fhe_dir), model=model)
    dev.save()

    print("FHE compilation complete.", flush=True)
    print(f"  Artifacts: {[p.name for p in fhe_dir.iterdir()]}", flush=True)


if __name__ == "__main__":
    compile_fhe()
