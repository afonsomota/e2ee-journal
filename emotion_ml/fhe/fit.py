from concrete.ml.sklearn import LogisticRegression as FHELogisticRegression

import sys
from pathlib import Path
import joblib

sys.path.insert(0, str(Path(__file__).parent.parent))

from config import FHE_N_BITS

def fit_fhe_model(X_train_tfidf, y_train):
    fhe_model = FHELogisticRegression(n_bits=FHE_N_BITS, max_iter=1000, class_weight="balanced")
    fhe_model.fit(X_train_tfidf, y_train)
    return fhe_model

def main():
    X_train_tfidf_path = sys.argv[1]
    y_train_path = sys.argv[2]
    X_train_tfidf = joblib.load(X_train_tfidf_path)
    y_train = joblib.load(y_train_path)
    fhe_model = fit_fhe_model(X_train_tfidf, y_train)
    joblib.dump(fhe_model, "fhe_model.pkl")