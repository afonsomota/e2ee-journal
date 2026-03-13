"""Evaluate the trained emotion classifier."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import classification_report, confusion_matrix

from config import ARTIFACTS_DIR, LABELS, SPLITS_DIR


def evaluate():
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")
    le = joblib.load(ARTIFACTS_DIR / "label_encoder.pkl")

    # Load the FHE model from the training run (still in memory via train.py)
    # For standalone eval, we re-run the pipeline or load from a saved model
    # Here we use the sklearn predict path since FHE predict gives same results
    from training.train import load_splits, train_model

    train_df, _, test_df = load_splits()
    _, _, _, clf, _ = train_model(train_df)

    X_text = test_df["text"].values
    X_tfidf = tfidf.transform(X_text)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))
    y_true = le.transform(test_df["label"].values)

    y_pred = clf.predict(X_lsa)

    y_true_str = le.inverse_transform(y_true)
    y_pred_str = le.inverse_transform(y_pred)

    print("=" * 60)
    print("Classification Report (Test Set)")
    print("=" * 60)
    print(classification_report(y_true_str, y_pred_str, labels=LABELS, zero_division=0))

    print("Confusion Matrix:")
    cm = confusion_matrix(y_true_str, y_pred_str, labels=LABELS)
    header = "          " + " ".join(f"{l[:5]:>7}" for l in LABELS)
    print(header)
    for i, label in enumerate(LABELS):
        row = " ".join(f"{cm[i, j]:>7}" for j in range(len(LABELS)))
        print(f"{label[:10]:<10} {row}")

    report = classification_report(
        y_true_str, y_pred_str, labels=LABELS, output_dict=True, zero_division=0
    )
    print(f"\nMacro F1:    {report['macro avg']['f1-score']:.4f}")
    print(f"Weighted F1: {report['weighted avg']['f1-score']:.4f}")
    print(f"Accuracy:    {np.mean(y_true_str == y_pred_str):.4f}")

    return report


if __name__ == "__main__":
    evaluate()
