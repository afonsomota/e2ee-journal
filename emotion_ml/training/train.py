"""Train TF-IDF + LSA + XGBClassifier for emotion classification."""

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

from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier

from config import (
    ARTIFACTS_DIR,
    FHE_N_BITS,
    LABELS,
    LSA_N_COMPONENTS,
    SPLITS_DIR,
    TFIDF_MAX_FEATURES,
    TFIDF_NGRAM_RANGE,
    XGB_MAX_DEPTH,
    XGB_N_ESTIMATORS,
)


def load_splits():
    train = pd.read_csv(SPLITS_DIR / "train.csv")
    val = pd.read_csv(SPLITS_DIR / "validation.csv")
    test = pd.read_csv(SPLITS_DIR / "test.csv")
    return train, val, test


def train_model(train_df: pd.DataFrame):
    """Train TF-IDF + LSA + XGBClassifier pipeline."""
    X_text = train_df["text"].values

    # Encode string labels as integers (required by Concrete-ML)
    le = LabelEncoder()
    le.classes_ = np.array(LABELS)
    y = le.transform(train_df["label"].values)

    # TF-IDF with large vocabulary
    print(f"TF-IDF: max_features={TFIDF_MAX_FEATURES}, ngram_range={TFIDF_NGRAM_RANGE}")
    tfidf = TfidfVectorizer(
        max_features=TFIDF_MAX_FEATURES,
        ngram_range=TFIDF_NGRAM_RANGE,
        sublinear_tf=True,
        strip_accents="unicode",
        min_df=5,
    )
    X_tfidf = tfidf.fit_transform(X_text)
    print(f"  TF-IDF shape: {X_tfidf.shape}")

    # LSA dimensionality reduction (sparse -> dense)
    print(f"LSA: n_components={LSA_N_COMPONENTS}")
    svd = TruncatedSVD(n_components=LSA_N_COMPONENTS, random_state=42)
    normalizer = Normalizer()
    X_lsa = normalizer.fit_transform(svd.fit_transform(X_tfidf))
    print(f"  Explained variance: {svd.explained_variance_ratio_.sum():.2%}")

    # XGBoost with class balancing via sample weights
    sample_weights = compute_sample_weight("balanced", y)
    print(f"XGBoost: n_bits={FHE_N_BITS}, n_estimators={XGB_N_ESTIMATORS}, max_depth={XGB_MAX_DEPTH}")
    clf = FHEXGBClassifier(
        n_bits=FHE_N_BITS,
        n_estimators=XGB_N_ESTIMATORS,
        max_depth=XGB_MAX_DEPTH,
    )
    clf.fit(X_lsa, y, sample_weight=sample_weights)

    return tfidf, svd, normalizer, clf, le


def save_artifacts(tfidf, svd, normalizer, clf, le):
    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    joblib.dump(tfidf, ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    joblib.dump(svd, ARTIFACTS_DIR / "svd.pkl")
    joblib.dump(normalizer, ARTIFACTS_DIR / "normalizer.pkl")
    joblib.dump(le, ARTIFACTS_DIR / "label_encoder.pkl")
    # Note: clf (FHE model) is saved via FHEModelDev in compile_fhe.py

    print(f"Saved artifacts to {ARTIFACTS_DIR}")
    print(f"  Labels: {list(le.classes_)}")


if __name__ == "__main__":
    train_df, val_df, test_df = load_splits()
    tfidf, svd, normalizer, clf, le = train_model(train_df)
    save_artifacts(tfidf, svd, normalizer, clf, le)
    print("Training complete.")
