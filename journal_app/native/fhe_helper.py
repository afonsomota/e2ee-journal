"""
fhe_helper.py — thin Python wrapper over FHEModelClient.

Called from C (Python embedding in fhe_wrapper.cpp) to handle the
FHE operations that require concrete-ml:
  setup(client_zip_path, key_dir)  → bytes  (serialised evaluation key)
  get_eval_key()                   → bytes
  encrypt(features_bytes)          → bytes  (quantise + encrypt + serialise)
  decrypt(encrypted_bytes)         → bytes  (5 × float32, class scores)

This module is extracted from Flutter assets to the filesystem at runtime
and imported by the C wrapper via Python embedding.
"""

from __future__ import annotations

import numpy as np
from concrete.ml.deployment import FHEModelClient

_client: FHEModelClient | None = None
_eval_key_bytes: bytes | None = None


def setup(client_zip_path: str, key_dir: str) -> bytes:
    """Initialise FHE client and return serialised evaluation key."""
    global _client, _eval_key_bytes
    _client = FHEModelClient(path_dir=client_zip_path, key_dir=key_dir)
    _eval_key_bytes = _client.get_serialized_evaluation_keys()
    assert _eval_key_bytes is not None
    return _eval_key_bytes


def get_eval_key() -> bytes:
    """Return the cached evaluation key (call setup() first)."""
    assert _eval_key_bytes is not None, "setup() has not been called"
    return _eval_key_bytes


def encrypt(features_bytes: bytes) -> bytes:
    """
    Quantise + encrypt + serialise float32 features.

    Parameters
    ----------
    features_bytes:
        Raw little-endian float32 bytes.  Length must be n_features * 4.

    Returns
    -------
    bytes — serialised encrypted input ciphertext.
    """
    assert _client is not None, "setup() has not been called"
    n = len(features_bytes) // 4
    features = np.frombuffer(features_bytes, dtype=np.float32).reshape(1, n)
    return _client.quantize_encrypt_serialize(features)


def decrypt(encrypted_bytes: bytes) -> bytes:
    """
    Deserialise + decrypt + dequantise an FHE result.

    Returns
    -------
    bytes — 5 little-endian float32 values (one per class).
    """
    assert _client is not None, "setup() has not been called"
    result = _client.deserialize_decrypt_dequantize(encrypted_bytes)
    return result.flatten().astype(np.float32).tobytes()
