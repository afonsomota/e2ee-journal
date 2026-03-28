# journal_backend/main.py
#
# FastAPI backend for the E2EE Journal.
#
# The server stores and retrieves opaque blobs.  It does not need to know
# anything about the encryption scheme — and that's the point.
#
# The server's job:
#   • Authenticate users (JWT tokens, bcrypt passwords).
#   • Store and serve ciphertext blobs it cannot read.
#   • Distribute public keys.
#   • Manage the share table: (entry_id, recipient_id, encrypted_content_key).
#
# What the server NEVER sees:
#   • Plaintext entry content.
#   • The encryption key derived from the user's password.
#   • Any private key (it stores encryptedPrivateKey but cannot decrypt it).

import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from log import configure_root, get_logger
from routers import auth, entries, fhe, users
from models.database import init_db

# ── Logging ──────────────────────────────────────────────────────────────────
# configure_root() lowers the level on the root logger AND any handlers that
# uvicorn may have already attached (uvicorn sets handler level to INFO by
# default, which silently drops DEBUG messages even if the logger level is lower).

configure_root()
logger = get_logger(__name__)

app = FastAPI(
    title="E2EE Journal API",
    description="Backend for the End-to-End Encrypted Journal",
    version="1.0.0",
)

_cors_origins_env = os.getenv("CORS_ORIGINS", "")
_cors_origins = (
    [o.strip() for o in _cors_origins_env.split(",") if o.strip()]
    if _cors_origins_env
    else ["http://localhost:3000", "http://localhost:8080"]
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# TODO(security): In production, deploy behind a reverse proxy (nginx/Caddy)
# configured with request body size limits:
#   - /fhe/key: ~150 MB (evaluation keys are ~120 MB serialized)
#   - /fhe/predict: ~10 MB (encrypted feature vectors)
#   - /entries, /auth: ~1 MB (journal blobs and auth payloads)
# Also configure rate limiting at the proxy level (see H4 below).
#
# TODO(security/H4): Add application-level rate limiting (e.g. slowapi)
# for /auth/login and /auth/register to mitigate brute-force attacks.

app.include_router(auth.router, prefix="/auth", tags=["auth"])
app.include_router(entries.router, prefix="/entries", tags=["entries"])
app.include_router(users.router, prefix="/users", tags=["users"])
app.include_router(fhe.router, prefix="/fhe", tags=["fhe"])


@app.on_event("startup")
async def startup():
    logger.info("Backend starting up...")
    await init_db()
    logger.info("Database initialized. Backend ready.")


@app.get("/health")
async def health():
    return {"status": "ok"}
