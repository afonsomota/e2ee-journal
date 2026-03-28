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
import time
from pathlib import Path


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from log import get_logger
from routers.auth import current_user

logger = get_logger(__name__)

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
        logger.info(f"Loading FHE server from {FHE_MODEL_DIR}...")
        from concrete.ml.deployment import FHEModelServer

        _server = FHEModelServer(path_dir=FHE_MODEL_DIR)
        _server.load()
        logger.info("FHE server loaded successfully.")
    return _server


# ── In-memory evaluation key store ───────────────────────────────────────────
# Keys are deserialized on upload and stored as EvaluationKeys objects so that
# the expensive Cap'n Proto parse (~120 MB) happens once, not on every predict.

import concrete.fhe as fhe

_eval_keys: dict[str, fhe.EvaluationKeys] = {}


# ── Request/Response models ──────────────────────────────────────────────────


class KeyUpload(BaseModel):
    evaluation_key_b64: str


class PredictRequest(BaseModel):
    encrypted_input_b64: str


class PredictResponse(BaseModel):
    encrypted_result_b64: str


# ── Endpoints ────────────────────────────────────────────────────────────────


@router.post("/key")
async def upload_evaluation_key(payload: KeyUpload, user: dict = Depends(current_user)):
    """Receive and store the client's FHE evaluation key.

    The Dart native client generates a Concrete-compatible Cap'n Proto
    ServerKeyset on-device (via the Rust FFI bridge) and uploads it here.
    The private ClientKey never leaves the device.

    Deserialization happens once on upload so the expensive Cap'n Proto parse
    (~120 MB) does not repeat on every predict call.
    """
    user_id = user["id"]
    raw = base64.b64decode(payload.evaluation_key_b64)
    logger.info(
        f"Deserializing evaluation key for user {user_id} "
        f"({len(raw):,} bytes)..."
    )
    _eval_keys[user_id] = fhe.EvaluationKeys.deserialize(raw)
    logger.info(f"Evaluation key stored for user {user_id}")
    return {"status": "ok"}


@router.post("/predict", response_model=PredictResponse)
async def predict(payload: PredictRequest, user: dict = Depends(current_user)):
    """Run FHE inference on an encrypted feature vector."""
    user_id = user["id"]
    logger.info(f"Predict request from user {user_id}")

    eval_keys = _eval_keys.get(user_id)
    if eval_keys is None:
        logger.error(f"Evaluation keys not found for user {user_id}")
        raise HTTPException(
            status_code=400,
            detail="Evaluation keys not found. Call POST /fhe/key first.",
        )

    server = _get_server()
    encrypted_input = base64.b64decode(payload.encrypted_input_b64)
    logger.debug(f"Encrypted input size: {len(encrypted_input)} bytes")

    logger.info("Starting FHE inference...")
    t0 = time.perf_counter()
    encrypted_result = server.run(encrypted_input, eval_keys)
    elapsed = time.perf_counter() - t0

    # server.run() returns a tuple when the circuit has a tfhers_bridge (TFHE-rs
    # bridge for Dart/Rust client compatibility).  Unwrap to the first element.
    if isinstance(encrypted_result, tuple):
        logger.debug(f"server.run() returned {len(encrypted_result)}-element tuple; unwrapping")
        encrypted_result = encrypted_result[0]

    logger.info(f"FHE inference complete in {elapsed:.2f}s. Result size: {len(encrypted_result)} bytes")

    return PredictResponse(
        encrypted_result_b64=base64.b64encode(encrypted_result).decode()
    )
