from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers import auth, entries
from models.database import init_db

app = FastAPI(
    title="Journal API",
    description="Backend for the Journal app",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/auth", tags=["auth"])
app.include_router(entries.router, prefix="/entries", tags=["entries"])


@app.on_event("startup")
async def startup():
    await init_db()


@app.get("/health")
async def health():
    return {"status": "ok"}
