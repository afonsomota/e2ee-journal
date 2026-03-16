#!/usr/bin/env python3
"""
Export TF-IDF, SVD, and FHE quantization parameters to portable binary formats
for use by the native Dart FHE client.

Run once after training:
    python emotion_ml/export_dart_assets.py

Outputs to journal_app/assets/fhe/:
    vocab.json              — word → index map (str → int)
    idf_weights.bin         — 5000 × float32, little-endian
    svd_components.bin      — 200 × 5000 × float32, little-endian, row-major
    quantization_params.json — per-feature input scale/zero_point + output params
    client.zip              — FHE client model (for C wrapper / Python helper)
"""

import json
import shutil
import zipfile
from pathlib import Path

import joblib
import numpy as np

ROOT = Path(__file__).parent.parent
ASSETS_SRC = ROOT / "fhe_client" / "assets"
ASSETS_OUT = ROOT / "journal_app" / "assets" / "fhe"
CLIENT_ZIP = ASSETS_SRC / "fhe_model" / "client.zip"


def main() -> None:
    ASSETS_OUT.mkdir(parents=True, exist_ok=True)

    # ── Load sklearn artifacts ─────────────────────────────────────────────────
    tfidf = joblib.load(ASSETS_SRC / "tfidf_vectorizer.pkl")
    svd = joblib.load(ASSETS_SRC / "svd.pkl")

    # ── 1. vocab.json — word → column-index ───────────────────────────────────
    vocab: dict[str, int] = {word: int(idx) for word, idx in tfidf.vocabulary_.items()}
    (ASSETS_OUT / "vocab.json").write_text(
        json.dumps(vocab, ensure_ascii=False, separators=(",", ":"))
    )
    print(f"vocab.json        : {len(vocab)} terms")

    # ── 2. idf_weights.bin — float32 array, length = n_features ──────────────
    idf = tfidf.idf_.astype(np.float32)
    (ASSETS_OUT / "idf_weights.bin").write_bytes(idf.tobytes())
    print(f"idf_weights.bin   : {idf.shape} float32  ({idf.nbytes} bytes)")

    # ── 3. svd_components.bin — (n_components × n_features) float32, row-major
    components = svd.components_.astype(np.float32)  # (200, 5000)
    (ASSETS_OUT / "svd_components.bin").write_bytes(components.tobytes())
    print(
        f"svd_components.bin: {components.shape} float32  ({components.nbytes} bytes)"
    )

    # ── 4. quantization_params.json — from client.zip serialized_processing ──
    with zipfile.ZipFile(CLIENT_ZIP) as z:
        proc = json.loads(z.read("serialized_processing.json"))

    input_params = []
    for q in proc["input_quantizers"]:
        sv = q["serialized_value"]
        zp = sv["zero_point"]
        input_params.append(
            {
                "scale": float(sv["scale"]["serialized_value"]),
                "zero_point": int(zp["serialized_value"])
                if isinstance(zp, dict)
                else int(zp),
                "offset": int(sv.get("offset", 0)),
                "n_bits": int(sv["n_bits"]),
                "is_signed": bool(sv["is_signed"]),
            }
        )

    out_sv = proc["output_quantizers"][0]["serialized_value"]
    out_zp = out_sv["zero_point"]
    output_params = {
        "scale": float(out_sv["scale"]["serialized_value"]),
        "zero_point": int(out_zp["serialized_value"])
        if isinstance(out_zp, dict)
        else int(out_zp),
        "offset": int(out_sv.get("offset", 0)),
        "n_bits": int(out_sv["n_bits"]),
        "is_signed": bool(out_sv["is_signed"]),
        "n_classes": 5,
    }

    params = {"input": input_params, "output": output_params}
    (ASSETS_OUT / "quantization_params.json").write_text(json.dumps(params, indent=2))
    print(
        f"quantization_params.json: {len(input_params)} input quantizers, 1 output"
    )

    # ── 5. client.zip — needed by fhe_helper.py at runtime ───────────────────
    shutil.copy2(CLIENT_ZIP, ASSETS_OUT / "client.zip")
    print(f"client.zip        : {(ASSETS_OUT / 'client.zip').stat().st_size} bytes")

    print(f"\nAll assets written to: {ASSETS_OUT}")


if __name__ == "__main__":
    main()
