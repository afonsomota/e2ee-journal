"""Dump reference FHE encryption/decryption data for cross-language testing.

Outputs to emotion_ml/artifacts/fhe_reference/:
  - quantized_input.bin     : int64 quantized values
  - serialized_value.bin    : Cap'n Proto Value bytes (what server.run() accepts)
  - server_result.bin       : Cap'n Proto Value bytes (server.run() output)
  - dequantized_output.bin  : float64 dequantized scores
  - meta.json               : shapes, encoding params, etc.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
import pandas as pd
from concrete.ml.deployment import FHEModelClient, FHEModelServer

from config import ARTIFACTS_DIR, LABELS, SPLITS_DIR


def dump_reference():
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    test_df = pd.read_csv(SPLITS_DIR / "test.csv")
    texts = test_df["text"].values[:1]  # single sample

    X_tfidf = tfidf.transform(texts)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    fhe_dir = str(ARTIFACTS_DIR / "fhe_model")
    key_dir = str(ARTIFACTS_DIR / "fhe_keys")

    client = FHEModelClient(path_dir=fhe_dir, key_dir=key_dir)
    server = FHEModelServer(path_dir=fhe_dir)
    server.load()

    eval_keys = client.get_serialized_evaluation_keys()

    # Quantize
    x_quant = client.model.quantize_input(X_lsa)

    # Encrypt (returns serialized Value bytes)
    encrypted = client.quantize_encrypt_serialize(X_lsa)

    # Server inference
    server_result = server.run(encrypted, eval_keys)
    if isinstance(server_result, tuple):
        server_result = server_result[0]

    # Decrypt
    result = client.deserialize_decrypt_dequantize(server_result)
    pred = int(np.argmax(result))

    # Save reference data
    out_dir = ARTIFACTS_DIR / "fhe_reference"
    out_dir.mkdir(exist_ok=True)

    np.array(x_quant, dtype=np.int64).tofile(out_dir / "quantized_input.bin")
    Path(out_dir / "serialized_value.bin").write_bytes(encrypted)
    Path(out_dir / "server_result.bin").write_bytes(server_result)
    np.array(result, dtype=np.float64).tofile(out_dir / "dequantized_output.bin")

    meta = {
        "n_features": int(X_lsa.shape[1]),
        "quantized_shape": list(x_quant.shape),
        "encrypted_size": len(encrypted),
        "server_result_size": len(server_result),
        "pred_label": LABELS[pred],
        "pred_index": pred,
        "scores": result.tolist()
            if hasattr(result, "tolist")
            else [list(r) for r in result],
    }
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2))

    print(f"Reference data saved to {out_dir}")
    print(f"  Quantized input shape: {x_quant.shape}")
    print(f"  Encrypted size: {len(encrypted)} bytes")
    print(f"  Server result size: {len(server_result)} bytes")
    print(f"  Prediction: {LABELS[pred]} (scores: {result})")


if __name__ == "__main__":
    dump_reference()
