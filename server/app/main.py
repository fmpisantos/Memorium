import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.db import SessionLocal, init_db
from app.deps import ensure_profile
from app.enrichment import get_service
from app.routers import auth, enrich, health, study, words

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    # Exists before anything can need it -- background enrichment reads the
    # language pair and must not race a first request to create it.
    with SessionLocal() as db:
        ensure_profile(db)
    service = get_service()
    await service.start()
    try:
        yield
    finally:
        await service.stop()


app = FastAPI(
    title="Memorium",
    version="0.1.0",
    summary="Owns the deck, schedules reviews with FSRS, generates content with Claude.",
    lifespan=lifespan,
)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(words.router)
app.include_router(study.router)
app.include_router(enrich.router)
