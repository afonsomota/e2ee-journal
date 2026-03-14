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

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from log import get_logger

logger = get_logger(__name__)

router = APIRouter()

# ── FHE model loading ────────────────────────────────────────────────────────

FHE_MODEL_DIR = os.environ.get(
    "FHE_MODEL_DIR",
    str(Path(__file__).parent.parent / "fhe_model"),
)

# client.zip lives one level above fhe_model/ at the backend root.
CLIENT_ZIP_PATH = os.environ.get(
    "FHE_CLIENT_ZIP",
    str(Path(__file__).parent.parent / "client.zip"),
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

_eval_keys: dict[str, bytes] = {}


# ── Request/Response models ──────────────────────────────────────────────────


class SetupRequest(BaseModel):
    client_id: str
    lwe_key_b64: str


class KeyUpload(BaseModel):
    client_id: str
    evaluation_key_b64: str


class PredictRequest(BaseModel):
    client_id: str
    encrypted_input_b64: str


class PredictResponse(BaseModel):
    encrypted_result_b64: str


# ── Endpoints ────────────────────────────────────────────────────────────────


@router.post("/setup")
async def setup_client(payload: SetupRequest):
    """Receive the client's LWE key and derive circuit evaluation keys.

    The Dart client generates TFHE-rs keys natively (no Python on-device).
    It extracts the LWE secret key and sends it here so the server can call
    FHEModelClient.keygen_with_initial_keys() to produce evaluation keys that
    are compatible with the client's ciphertexts.
    """
    from concrete.ml.deployment import FHEModelClient

    lwe_key_bytes = base64.b64decode(payload.lwe_key_b64)
    logger.info(
        f"Setup request from client {payload.client_id} "
        f"(lwe_key size: {len(lwe_key_bytes)} bytes)"
    )

    if not Path(CLIENT_ZIP_PATH).exists():
        logger.error(f"client.zip not found at {CLIENT_ZIP_PATH}")
        raise HTTPException(status_code=500, detail="FHE client.zip not found on server")

    fhe_client = FHEModelClient(path_dir=str(Path(CLIENT_ZIP_PATH).parent),
                                key_dir=None)

    # Bind the TFHE-rs LWE key so the circuit generates evaluation keys that
    # are compatible with ciphertexts produced by the Dart native client.
    # The lwe_key_bytes are serialised with tfhe-rs safe_serialize; concrete-ml
    # passes them through to the tfhers bridge for keygen.
    fhe_client.keygen_with_initial_keys(input_idx_to_key_buffer={0: lwe_key_bytes})

    eval_keys = fhe_client.get_serialized_evaluation_keys()
    _eval_keys[payload.client_id] = eval_keys
    logger.info(
        f"Circuit eval keys generated for client {payload.client_id} "
        f"(size: {len(eval_keys)} bytes)"
    )
    return {"status": "ok"}


@router.post("/key")
async def upload_evaluation_key(payload: KeyUpload):
    """Legacy endpoint: client uploads pre-serialized FHE evaluation keys.

    Kept for backward compatibility.  New clients should use POST /fhe/setup
    instead, which derives eval keys server-side from the TFHE-rs LWE key.
    """
    key_size = len(base64.b64decode(payload.evaluation_key_b64))
    _eval_keys[payload.client_id] = base64.b64decode(payload.evaluation_key_b64)
    logger.info(f"Evaluation key uploaded for client {payload.client_id} (size: {key_size} bytes)")
    return {"status": "ok"}


@router.post("/predict", response_model=PredictResponse)
async def predict(payload: PredictRequest):
    """Run FHE inference on an encrypted feature vector."""
    logger.info(f"Predict request from client {payload.client_id}")

    eval_keys = _eval_keys.get(payload.client_id)
    if eval_keys is None:
        logger.error(f"Evaluation keys not found for client {payload.client_id}")
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
    logger.info(f"FHE inference complete in {elapsed:.2f}s. Result size: {len(encrypted_result)} bytes")

    return PredictResponse(
        encrypted_result_b64=base64.b64encode(encrypted_result).decode()
    )
