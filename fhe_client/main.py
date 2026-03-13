# fhe_client/main.py
#
# Local FHE client sidecar — runs on the user's device (localhost only).
#
# Acts as a local "library" for the Flutter app, handling:
#   • TF-IDF vectorization + LSA dimensionality reduction
#   • FHE encryption (quantize + encrypt)
#   • FHE decryption (decrypt + dequantize + argmax → label)
#
# The Flutter app orchestrates the full flow:
#   1. Dart → sidecar POST /setup         → get eval key for backend
#   2. Dart → sidecar POST /vectorize     → get encrypted feature vector
#   3. Dart → backend POST /fhe/predict   → get encrypted result
#   4. Dart → sidecar POST /decrypt       → get emotion label
#
# In production, this sidecar would be replaced by native Dart/C code.

import base64
import uuid
from pathlib import Path

import joblib
import numpy as np
from concrete.ml.deployment import FHEModelClient
from fastapi import FastAPI
from pydantic import BaseModel

# ── Asset paths ──────────────────────────────────────────────────────────────

ASSETS_DIR = Path(__file__).parent / "assets"
FHE_MODEL_DIR = str(ASSETS_DIR / "fhe_model")
KEY_DIR = str(Path(__file__).parent / "keys")

# ── Labels (must match training config) ──────────────────────────────────────

LABELS = ["anger", "joy", "neutral", "sadness", "surprise"]

# ── App ──────────────────────────────────────────────────────────────────────

app = FastAPI(title="FHE Emotion Client Sidecar")

# Load feature pipeline at startup
_tfidf = joblib.load(ASSETS_DIR / "tfidf_vectorizer.pkl")
_svd = joblib.load(ASSETS_DIR / "svd.pkl")
_normalizer = joblib.load(ASSETS_DIR / "normalizer.pkl")

# FHE client (lazy init — key generation is expensive)
_client: FHEModelClient | None = None
_client_id: str | None = None
_eval_keys_b64: str | None = None


def _get_client() -> FHEModelClient:
    global _client, _client_id, _eval_keys_b64
    if _client is None:
        _client = FHEModelClient(path_dir=FHE_MODEL_DIR, key_dir=KEY_DIR)
        _client_id = str(uuid.uuid4())
        # Generate and cache serialized evaluation keys
        eval_keys = _client.get_serialized_evaluation_keys()
        _eval_keys_b64 = base64.b64encode(eval_keys).decode()
    return _client


# ── Request/Response models ──────────────────────────────────────────────────


class SetupResponse(BaseModel):
    client_id: str
    evaluation_key_b64: str


class VectorizeRequest(BaseModel):
    text: str


class VectorizeResponse(BaseModel):
    encrypted_vector_b64: str


class DecryptRequest(BaseModel):
    encrypted_result_b64: str


class DecryptResponse(BaseModel):
    emotion: str
    confidence: float


# ── Endpoints ────────────────────────────────────────────────────────────────


@app.post("/setup", response_model=SetupResponse)
async def setup():
    """Generate FHE keys and return evaluation key for the backend."""
    client = _get_client()
    return SetupResponse(
        client_id=_client_id,
        evaluation_key_b64=_eval_keys_b64,
    )


@app.post("/vectorize", response_model=VectorizeResponse)
async def vectorize(payload: VectorizeRequest):
    """Convert text to TF-IDF + LSA features, then FHE-encrypt."""
    client = _get_client()

    # Feature pipeline: text -> TF-IDF -> LSA -> normalize
    X_tfidf = _tfidf.transform([payload.text])
    X_lsa = _normalizer.transform(_svd.transform(X_tfidf))

    # Quantize + encrypt
    encrypted = client.quantize_encrypt_serialize(X_lsa)

    return VectorizeResponse(
        encrypted_vector_b64=base64.b64encode(encrypted).decode()
    )


@app.post("/decrypt", response_model=DecryptResponse)
async def decrypt(payload: DecryptRequest):
    """Decrypt FHE result and return emotion label."""
    client = _get_client()

    encrypted_result = base64.b64decode(payload.encrypted_result_b64)
    result = client.deserialize_decrypt_dequantize(encrypted_result)

    predicted_class = int(np.argmax(result))
    confidence = float(np.max(result))

    return DecryptResponse(
        emotion=LABELS[predicted_class],
        confidence=confidence,
    )
