"""API de Atracker: recibe los minutos del iPhone / Apple Watch y los escribe en Notion.

Variables de entorno (archivo .env, ver .env.example):
  NOTION_TOKEN          token de la integración de Notion
  ATRACKER_ACCESS_CODE  código de acceso personal que usan las apps
  ATRACKER_DB           ruta del SQLite de registros ya procesados (opcional)
"""

from __future__ import annotations

import asyncio
import os
import secrets
import sqlite3
from contextlib import asynccontextmanager
from datetime import date
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from notion import TAG_OPTIONS, Entry, NotionClient, NotionError


class EntryIn(BaseModel):
    id: str = Field(min_length=1, max_length=64, description="UUID generado por la app; evita duplicados al reintentar")
    subject_id: str
    tag: str
    pec_id: str | None = None
    minutes: int = Field(gt=0, le=24 * 60)
    day: date
    accumulate: bool = True


class EntryOut(BaseModel):
    total: int
    duplicate: bool = False


class ProcessedStore:
    """Recuerda qué registros ya se escribieron, para que un reintento no sume dos veces."""

    def __init__(self, path: str):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS processed ("
            " id TEXT PRIMARY KEY, total INTEGER NOT NULL,"
            " created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
        )
        self._db.commit()

    def get(self, entry_id: str) -> int | None:
        row = self._db.execute("SELECT total FROM processed WHERE id = ?", (entry_id,)).fetchone()
        return row[0] if row else None

    def add(self, entry_id: str, total: int) -> None:
        self._db.execute("INSERT OR REPLACE INTO processed (id, total) VALUES (?, ?)", (entry_id, total))
        self._db.commit()


def create_app(notion: NotionClient | None = None, access_code: str | None = None, db_path: str | None = None) -> FastAPI:
    access_code = access_code or _required_env("ATRACKER_ACCESS_CODE")
    notion = notion or NotionClient(_required_env("NOTION_TOKEN"))
    store = ProcessedStore(db_path or os.environ.get("ATRACKER_DB", str(Path(__file__).with_name("data") / "atracker.sqlite")))
    # Un solo registro a la vez: evita que dos sumas simultáneas al mismo día se pisen.
    write_lock = asyncio.Lock()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        await notion.aclose()

    app = FastAPI(title="Atracker", lifespan=lifespan)

    def require_code(authorization: str = Header(default="")) -> None:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not secrets.compare_digest(token.encode(), access_code.encode()):
            raise HTTPException(status_code=401, detail="Código de acceso incorrecto")

    def notion_error(error: NotionError) -> HTTPException:
        return HTTPException(status_code=502, detail=str(error))

    @app.get("/health")
    async def health() -> dict:
        return {"ok": True}

    @app.get("/subjects", dependencies=[Depends(require_code)])
    async def subjects(course: str | None = None) -> list[dict]:
        try:
            return await notion.subjects(course)
        except NotionError as error:
            raise notion_error(error)

    @app.get("/subjects/{subject_id}/pecs", dependencies=[Depends(require_code)])
    async def pecs(subject_id: str) -> list[dict]:
        try:
            return await notion.pecs(subject_id)
        except NotionError as error:
            raise notion_error(error)

    @app.post("/entries", dependencies=[Depends(require_code)])
    async def create_entry(body: EntryIn) -> EntryOut:
        if body.tag not in TAG_OPTIONS:
            raise HTTPException(status_code=422, detail=f"Tarea desconocida: {body.tag}")
        async with write_lock:
            previous = store.get(body.id)
            if previous is not None:
                return EntryOut(total=previous, duplicate=True)
            entry = Entry(body.subject_id, body.tag, body.pec_id, body.minutes, body.day.isoformat())
            try:
                total = await notion.log(entry, accumulate=body.accumulate)
            except NotionError as error:
                raise notion_error(error)
            store.add(body.id, total)
            return EntryOut(total=total)

    return app


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Falta la variable {name} (revisa el archivo .env)")
    return value


app = create_app()
