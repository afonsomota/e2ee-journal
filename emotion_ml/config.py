"""Configuration for the emotion classification pipeline."""

from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────

ROOT_DIR = Path(__file__).parent
ARTIFACTS_DIR = ROOT_DIR / "artifacts"
SPLITS_DIR = ROOT_DIR / "data" / "splits"

# ── Label mapping (Ekman 7-class from GoEmotions) ────────────────────────────

EKMAN_MAPPING = {
    # joy
    "joy": "joy",
    "amusement": "joy",
    "approval": "joy",
    "excitement": "joy",
    "gratitude": "joy",
    "love": "joy",
    "optimism": "joy",
    "relief": "joy",
    "admiration": "joy",
    "desire": "joy",
    "caring": "joy",
    "pride": "joy",
    # sadness
    "sadness": "sadness",
    "disappointment": "sadness",
    "embarrassment": "sadness",
    "grief": "sadness",
    "remorse": "sadness",
    # anger
    "anger": "anger",
    "annoyance": "anger",
    "disapproval": "anger",
    # fear → sadness (too few samples to learn separately)
    "fear": "sadness",
    "nervousness": "sadness",
    # surprise
    "surprise": "surprise",
    "realization": "surprise",
    "confusion": "surprise",
    "curiosity": "surprise",
    # disgust → anger (too few samples to learn separately)
    "disgust": "anger",
    # neutral
    "neutral": "neutral",
}

LABELS = ["anger", "joy", "neutral", "sadness", "surprise"]

# ── Model hyperparameters ─────────────────────────────────────────────────────

TFIDF_MAX_FEATURES = 5000
TFIDF_NGRAM_RANGE = (1, 2)

# ── LSA (TruncatedSVD) ───────────────────────────────────────────────────────

LSA_N_COMPONENTS = 200

# ── XGBoost ───────────────────────────────────────────────────────────────────

XGB_N_ESTIMATORS = 200
XGB_MAX_DEPTH = 3

# ── FHE ───────────────────────────────────────────────────────────────────────

FHE_N_BITS = 8
FHE_COMPILE_SAMPLES = 500
