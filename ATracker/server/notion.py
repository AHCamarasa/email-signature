"""Cliente mínimo de la API de Notion para las bases de datos Atracker, Asignaturas y PECS."""

from __future__ import annotations

import os
from dataclasses import dataclass

import httpx

API_VERSION = "2025-09-03"
BASE_URL = "https://api.notion.com/v1/"

ATRACKER_DS = os.environ.get("ATRACKER_DATA_SOURCE_ID", "30df5863-58f8-8005-a282-000b793fcbfb")
SUBJECTS_DS = os.environ.get("SUBJECTS_DATA_SOURCE_ID", "1e2f5863-58f8-800d-b496-000bac1449f2")
PECS_DS = os.environ.get("PECS_DATA_SOURCE_ID", "27af5863-58f8-80ea-af7c-000b233a4df3")

ENTRY_TITLE = "Registro Atracker"

# Opciones de la propiedad multi-select "Tareas" de Atracker.
TAG_OPTIONS = {"Examen", *(f"PEC {n}" for n in range(1, 6)), *(f"Módulo {n}" for n in range(1, 6))}


class NotionError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"Notion respondió {status}: {message}")
        self.status = status


@dataclass
class Entry:
    subject_id: str
    tag: str
    pec_id: str | None
    minutes: int
    day: str  # yyyy-MM-dd


class NotionClient:
    def __init__(self, token: str, transport: httpx.AsyncBaseTransport | None = None):
        self._http = httpx.AsyncClient(
            base_url=BASE_URL,
            timeout=20,
            transport=transport,
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": API_VERSION,
                "Content-Type": "application/json",
            },
        )

    async def aclose(self) -> None:
        await self._http.aclose()

    # Lectura

    async def subjects(self, course: str | None) -> list[dict]:
        course = (course or "").strip()
        flt = {"property": "Curso académico", "select": {"equals": course}} if course else None
        pages = await self._query_all(SUBJECTS_DS, flt)
        result = [{"id": p["id"], "name": _plain_text(p, "Asignatura") or "Sin nombre"} for p in pages]
        return sorted(result, key=lambda s: s["name"].casefold())

    async def pecs(self, subject_id: str) -> list[dict]:
        flt = {"property": "Asignatura", "relation": {"contains": subject_id}}
        pages = await self._query_all(PECS_DS, flt)
        result = [
            {
                "id": p["id"],
                "title": _plain_text(p, " "),
                "tipo": _option_name(p, "Tipo"),
                "estado": _option_name(p, "Estado"),
            }
            for p in pages
        ]
        return sorted(result, key=lambda i: i["title"].casefold())

    # Escritura

    async def log(self, entry: Entry, accumulate: bool) -> int:
        """Escribe los minutos en Atracker y devuelve el total del registro.

        Con `accumulate`, si ya hay un registro del mismo día, asignatura, tarea y PEC,
        suma los minutos a ese registro en lugar de crear otro.
        """
        if accumulate:
            existing = await self._find_entry(entry)
            if existing:
                page_id, minutes = existing
                total = minutes + entry.minutes
                await self._request("PATCH", f"pages/{page_id}", {"properties": {"Minutos": {"number": total}}})
                return total

        properties = {
            "Nombre": {"title": [{"text": {"content": ENTRY_TITLE}}]},
            "Minutos": {"number": entry.minutes},
            "Fecha": {"date": {"start": entry.day}},
            "Tareas": {"multi_select": [{"name": entry.tag}]},
            "Asignatura": {"relation": [{"id": entry.subject_id}]},
        }
        if entry.pec_id:
            properties["PEC"] = {"relation": [{"id": entry.pec_id}]}
        await self._request(
            "POST",
            "pages",
            {
                "parent": {"type": "data_source_id", "data_source_id": ATRACKER_DS},
                "icon": {"type": "emoji", "emoji": "⏱️"},
                "properties": properties,
            },
        )
        return entry.minutes

    async def _find_entry(self, entry: Entry) -> tuple[str, int] | None:
        conditions = [
            {"property": "Fecha", "date": {"equals": entry.day}},
            {"property": "Asignatura", "relation": {"contains": entry.subject_id}},
            {"property": "Tareas", "multi_select": {"contains": entry.tag}},
            {"property": "PEC", "relation": {"contains": entry.pec_id}}
            if entry.pec_id
            else {"property": "PEC", "relation": {"is_empty": True}},
        ]
        data = await self._request(
            "POST", f"data_sources/{ATRACKER_DS}/query", {"filter": {"and": conditions}, "page_size": 1}
        )
        results = data.get("results") or []
        if not results:
            return None
        page = results[0]
        minutes = page.get("properties", {}).get("Minutos", {}).get("number") or 0
        return page["id"], round(minutes)

    # HTTP

    async def _query_all(self, data_source_id: str, flt: dict | None) -> list[dict]:
        results: list[dict] = []
        cursor = None
        while True:
            body: dict = {"page_size": 100}
            if flt:
                body["filter"] = flt
            if cursor:
                body["start_cursor"] = cursor
            data = await self._request("POST", f"data_sources/{data_source_id}/query", body)
            results += data.get("results") or []
            if not data.get("has_more"):
                return results
            cursor = data.get("next_cursor")

    async def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        response = await self._http.request(method, path, json=body)
        try:
            data = response.json()
        except ValueError:
            data = {}
        if response.status_code >= 300:
            raise NotionError(response.status_code, data.get("message", "error desconocido"))
        return data


def _prop(page: dict, name: str) -> dict:
    return (page.get("properties") or {}).get(name) or {}


def _plain_text(page: dict, name: str) -> str:
    prop = _prop(page, name)
    parts = prop.get(prop.get("type", ""), [])
    if not isinstance(parts, list):
        return ""
    return "".join(p.get("plain_text", "") for p in parts).strip()


def _option_name(page: dict, name: str) -> str | None:
    prop = _prop(page, name)
    value = prop.get(prop.get("type", ""))
    return value.get("name") if isinstance(value, dict) else None
