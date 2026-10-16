"""Pruebas de la API con un Notion simulado (no hace llamadas reales)."""

import json
import os
import sys
import tempfile
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("ATRACKER_ACCESS_CODE", "import-only")
os.environ.setdefault("NOTION_TOKEN", "import-only")
os.environ.setdefault("ATRACKER_DB", os.path.join(tempfile.mkdtemp(), "import-only.sqlite"))

from main import create_app  # noqa: E402
from notion import NotionClient  # noqa: E402

CODE = "codigo-de-prueba"
AUTH = {"Authorization": f"Bearer {CODE}"}


class FakeNotion:
    """Simula los endpoints de Notion que usa el servidor, guardando los registros en memoria."""

    def __init__(self):
        self.entries: dict[str, dict] = {}
        self.calls: list[tuple[str, str, dict]] = []
        self.fail_with: httpx.Response | None = None

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self.fail_with is not None:
            return self.fail_with
        body = json.loads(request.content or b"{}")
        path = request.url.path.removeprefix("/v1/")
        self.calls.append((request.method, path, body))
        assert request.headers["Notion-Version"] == "2025-09-03"

        if path.startswith("data_sources/1e2f"):  # Asignaturas
            assert body["filter"] == {"property": "Curso académico", "select": {"equals": "2026/27"}}
            return httpx.Response(200, json={"results": [
                _page("s2", {"Asignatura": _title("Derecho financiero y tributario I")}),
                _page("s1", {"Asignatura": _title("Contabilidad")}),
            ], "has_more": False})

        if path.startswith("data_sources/27af"):  # PECS
            return httpx.Response(200, json={"results": [
                _page("p1", {" ": _title("PEC 1 Contabilidad"), "Tipo": _select("PEC"), "Estado": _status("En progreso")}),
            ], "has_more": False})

        if path.startswith("data_sources/30df"):  # Atracker: buscar registro del día
            conditions = body["filter"]["and"]
            day = conditions[0]["date"]["equals"]
            subject = conditions[1]["relation"]["contains"]
            tag = conditions[2]["multi_select"]["contains"]
            pec = conditions[3]["relation"].get("contains")
            matches = [
                _page(pid, {"Minutos": {"type": "number", "number": e["minutes"]}})
                for pid, e in self.entries.items()
                if (e["day"], e["subject"], e["tag"], e["pec"]) == (day, subject, tag, pec)
            ]
            return httpx.Response(200, json={"results": matches[:1], "has_more": False})

        if request.method == "POST" and path == "pages":
            props = body["properties"]
            assert body["parent"] == {"type": "data_source_id", "data_source_id": "30df5863-58f8-8005-a282-000b793fcbfb"}
            pid = f"e{len(self.entries) + 1}"
            self.entries[pid] = {
                "minutes": props["Minutos"]["number"],
                "day": props["Fecha"]["date"]["start"],
                "subject": props["Asignatura"]["relation"][0]["id"],
                "tag": props["Tareas"]["multi_select"][0]["name"],
                "pec": props.get("PEC", {}).get("relation", [{}])[0].get("id"),
            }
            return httpx.Response(200, json={"id": pid})

        if request.method == "PATCH" and path.startswith("pages/"):
            pid = path.removeprefix("pages/")
            self.entries[pid]["minutes"] = body["properties"]["Minutos"]["number"]
            return httpx.Response(200, json={"id": pid})

        return httpx.Response(404, json={"message": f"ruta no simulada {path}"})


def _page(pid, properties):
    return {"id": pid, "properties": properties}


def _title(text):
    return {"type": "title", "title": [{"plain_text": text}]}


def _select(name):
    return {"type": "select", "select": {"name": name}}


def _status(name):
    return {"type": "status", "status": {"name": name}}


@pytest.fixture
def setup(tmp_path):
    fake = FakeNotion()
    notion = NotionClient("token-falso", transport=httpx.MockTransport(fake.handler))
    app = create_app(notion=notion, access_code=CODE, db_path=str(tmp_path / "t.sqlite"))
    with TestClient(app) as client:
        yield client, fake


def entry(**overrides):
    body = {"id": "11111111-1111-1111-1111-111111111111", "subject_id": "s1", "tag": "PEC 1",
            "pec_id": "p1", "minutes": 25, "day": "2026-10-16"}
    body.update(overrides)
    return body


def test_health_needs_no_code(setup):
    client, _ = setup
    assert client.get("/health").json() == {"ok": True}


def test_wrong_or_missing_code_is_rejected(setup):
    client, fake = setup
    assert client.get("/subjects").status_code == 401
    assert client.post("/entries", json=entry(), headers={"Authorization": "Bearer otro"}).status_code == 401
    assert fake.calls == []


def test_subjects_sorted_and_filtered_by_course(setup):
    client, _ = setup
    response = client.get("/subjects", params={"course": "2026/27"}, headers=AUTH)
    assert response.json() == [
        {"id": "s1", "name": "Contabilidad"},
        {"id": "s2", "name": "Derecho financiero y tributario I"},
    ]


def test_pecs_of_subject(setup):
    client, fake = setup
    response = client.get("/subjects/s1/pecs", headers=AUTH)
    assert response.json() == [{"id": "p1", "title": "PEC 1 Contabilidad", "tipo": "PEC", "estado": "En progreso"}]
    assert fake.calls[0][2]["filter"] == {"property": "Asignatura", "relation": {"contains": "s1"}}


def test_creates_then_accumulates_same_day(setup):
    client, fake = setup
    first = client.post("/entries", json=entry(), headers=AUTH).json()
    second = client.post("/entries", json=entry(id="22222222-2222-2222-2222-222222222222", minutes=40), headers=AUTH).json()
    assert first == {"total": 25, "duplicate": False}
    assert second == {"total": 65, "duplicate": False}
    assert list(fake.entries.values()) == [
        {"minutes": 65, "day": "2026-10-16", "subject": "s1", "tag": "PEC 1", "pec": "p1"}
    ]


def test_without_accumulate_creates_new_entry(setup):
    client, fake = setup
    client.post("/entries", json=entry(), headers=AUTH)
    client.post("/entries", json=entry(id="3", accumulate=False), headers=AUTH)
    assert [e["minutes"] for e in fake.entries.values()] == [25, 25]


def test_retry_with_same_id_is_not_counted_twice(setup):
    client, fake = setup
    client.post("/entries", json=entry(), headers=AUTH)
    retry = client.post("/entries", json=entry(), headers=AUTH).json()
    assert retry == {"total": 25, "duplicate": True}
    assert [e["minutes"] for e in fake.entries.values()] == [25]


def test_different_day_or_task_creates_separate_entries(setup):
    client, fake = setup
    client.post("/entries", json=entry(), headers=AUTH)
    client.post("/entries", json=entry(id="4", day="2026-10-17"), headers=AUTH)
    client.post("/entries", json=entry(id="5", tag="Módulo 1", pec_id=None), headers=AUTH)
    assert len(fake.entries) == 3
    assert fake.entries["e3"]["pec"] is None


def test_unknown_tag_rejected_before_touching_notion(setup):
    client, fake = setup
    response = client.post("/entries", json=entry(tag="PEC 9"), headers=AUTH)
    assert response.status_code == 422
    assert fake.calls == []


def test_notion_error_becomes_502_and_retry_still_works(setup):
    client, fake = setup
    fake.fail_with = httpx.Response(401, json={"message": "API token is invalid."})
    failed = client.post("/entries", json=entry(), headers=AUTH)
    assert failed.status_code == 502
    assert "API token is invalid" in failed.json()["detail"]
    fake.fail_with = None
    assert client.post("/entries", json=entry(), headers=AUTH).json() == {"total": 25, "duplicate": False}
