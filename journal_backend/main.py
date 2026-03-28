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


from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from log import configure_root, get_logger
from models.database import init_db
from routers import auth, entries, fhe, users

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

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Restrict in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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
