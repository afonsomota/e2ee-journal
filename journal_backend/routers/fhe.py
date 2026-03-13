# routers/fhe.py
#
# FHE emotion inference endpoints.
#
# The server receives encrypted feature vectors and evaluation keys from the
# client, runs FHE inference, and returns encrypted results.
#
# What the server NEVER sees:
#   • Plaintext text or TF-IDF features.
#   • Decrypted predictions.
# This matches the existing E2EE trust model.

import base64
import os
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()

# ── FHE model loading ────────────────────────────────────────────────────────

FHE_MODEL_DIR = os.environ.get(
    "FHE_MODEL_DIR",
    str(Path(__file__).parent.parent / "fhe_model"),
)

_server = None


def _get_server():
    """Lazy-load the FHE server to avoid import cost at startup."""
    global _server
    if _server is None:
        from concrete.ml.deployment import FHEModelServer

        _server = FHEModelServer(path_dir=FHE_MODEL_DIR)
        _server.load()
    return _server


# ── In-memory evaluation key store ───────────────────────────────────────────

_eval_keys: dict[str, bytes] = {}


# ── Request/Response models ──────────────────────────────────────────────────


class KeyUpload(BaseModel):
    client_id: str
    evaluation_key_b64: str


class PredictRequest(BaseModel):
    client_id: str
    encrypted_input_b64: str


class PredictResponse(BaseModel):
    encrypted_result_b64: str


# ── Endpoints ────────────────────────────────────────────────────────────────


@router.post("/key")
async def upload_evaluation_key(payload: KeyUpload):
    """Client uploads serialized FHE evaluation keys."""
    _eval_keys[payload.client_id] = base64.b64decode(payload.evaluation_key_b64)
    return {"status": "ok"}


@router.post("/predict", response_model=PredictResponse)
async def predict(payload: PredictRequest):
    """Run FHE inference on an encrypted feature vector."""
    eval_keys = _eval_keys.get(payload.client_id)
    if eval_keys is None:
        raise HTTPException(
            status_code=400,
            detail="Evaluation keys not found. Call POST /fhe/key first.",
        )

    server = _get_server()
    encrypted_input = base64.b64decode(payload.encrypted_input_b64)
    encrypted_result = server.run(encrypted_input, eval_keys)

    return PredictResponse(
        encrypted_result_b64=base64.b64encode(encrypted_result).decode()
    )
