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

from routers import auth, entries, users
from models.database import init_db

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


@app.on_event("startup")
async def startup():
    await init_db()


@app.get("/health")
async def health():
    return {"status": "ok"}
