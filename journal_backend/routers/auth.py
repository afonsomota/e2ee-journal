# routers/auth.py

from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel, Field
from typing import Optional
import uuid
import bcrypt
import jwt
import os
from datetime import datetime, timedelta

from models.database import get_db

router = APIRouter()

JWT_SECRET = os.getenv("JWT_SECRET", "change-me-in-production")
JWT_ALGORITHM = "HS256"
JWT_EXPIRY_HOURS = 24 * 7  # 1 week


# ── Schemas ────────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=32)
    password: str = Field(..., min_length=8)
    public_key: Optional[str] = None
    encrypted_private_key: Optional[str] = None


class LoginRequest(BaseModel):
    username: str
    password: str


class AuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: dict


# ── Helpers ────────────────────────────────────────────────────────────────────

def _create_token(user_id: str, username: str) -> str:
    payload = {
        "sub": user_id,
        "username": username,
        "exp": datetime.utcnow() + timedelta(hours=JWT_EXPIRY_HOURS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def _verify_token(token: str) -> dict:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")


# ── Auth dependency ────────────────────────────────────────────────────────────

from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

_bearer = HTTPBearer()


async def current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
    db=Depends(get_db),
):
    payload = _verify_token(credentials.credentials)
    async with db.execute(
        "SELECT * FROM users WHERE id = ?", (payload["sub"],)
    ) as cur:
        row = await cur.fetchone()
    if row is None:
        raise HTTPException(status_code=401, detail="User not found")
    return dict(row)


# ── Routes ─────────────────────────────────────────────────────────────────────

@router.post("/register", response_model=AuthResponse)
async def register(req: RegisterRequest, db=Depends(get_db)):
    # Check username uniqueness.
    async with db.execute(
        "SELECT id FROM users WHERE username = ?", (req.username,)
    ) as cur:
        if await cur.fetchone():
            raise HTTPException(status_code=409, detail="Username already taken")

    user_id = str(uuid.uuid4())
    # bcrypt the password for server-side authentication.
    # This is completely separate from the client-side Argon2 derivation.
    # The server bcrypts for auth; the client Argon2s for crypto.
    password_hash = bcrypt.hashpw(
        req.password.encode(), bcrypt.gensalt(rounds=12)
    ).decode()

    await db.execute(
        """INSERT INTO users
           (id, username, password_hash, public_key, encrypted_private_key)
           VALUES (?, ?, ?, ?, ?)""",
        (
            user_id,
            req.username,
            password_hash,
            req.public_key,
            req.encrypted_private_key,
        ),
    )
    await db.commit()

    token = _create_token(user_id, req.username)
    return {
        "access_token": token,
        "user": {
            "id": user_id,
            "username": req.username,
            "public_key": req.public_key,
            "encrypted_private_key": req.encrypted_private_key,
        },
    }


@router.post("/login", response_model=AuthResponse)
async def login(req: LoginRequest, db=Depends(get_db)):
    async with db.execute(
        "SELECT * FROM users WHERE username = ?", (req.username,)
    ) as cur:
        row = await cur.fetchone()

    if row is None or not bcrypt.checkpw(
        req.password.encode(), row["password_hash"].encode()
    ):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = _create_token(row["id"], row["username"])
    return {
        "access_token": token,
        # Return the encrypted private key blob so the client can
        # decrypt it locally.  The server never decrypts this itself.
        "user": {
            "id": row["id"],
            "username": row["username"],
            "public_key": row["public_key"],
            "encrypted_private_key": row["encrypted_private_key"],
        },
    }
