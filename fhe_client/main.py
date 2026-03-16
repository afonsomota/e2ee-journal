# fhe_client/main.py
#
# FHE client sidecar — all FHE endpoints (/setup, /vectorize, /decrypt) have
# been removed.  Those operations are now handled in-process by the native Dart
# FHE client (journal_app/lib/fhe/fhe_client.dart via FFI → libfhe_wrapper.so).
#
# This file is intentionally minimal.  It may be deleted entirely once the
# native Dart client is confirmed working.

from fastapi import FastAPI

app = FastAPI(title="FHE Emotion Client Sidecar (deprecated)")


@app.get("/health")
async def health():
    return {"status": "ok", "note": "FHE endpoints moved to native Dart client"}
