#!/usr/bin/env python3
"""
Export TF-IDF, SVD, and FHE client assets to portable formats
for use by the Flutter app.

Run once after training:
    python emotion_ml/export_dart_assets.py

Outputs to journal_app/assets/fhe/:
    vocab.json              — word → index map (str → int)
    idf_weights.bin         — 5000 × float32, little-endian
    svd_components.bin      — 200 × 5000 × float32, little-endian, row-major
    client.zip              — Concrete ML client model (parsed by flutter_concrete plugin)
"""

import json
import shutil
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

    # ── 4. client.zip — Concrete ML standard artifact ─────────────────────────
    # Parsed at runtime by flutter_concrete plugin (extracts quantization
    # params from serialized_processing.json inside the zip).
    shutil.copy2(CLIENT_ZIP, ASSETS_OUT / "client.zip")
    print(f"client.zip        : {(ASSETS_OUT / 'client.zip').stat().st_size} bytes")

    print(f"\nAll assets written to: {ASSETS_OUT}")


if __name__ == "__main__":
    main()
