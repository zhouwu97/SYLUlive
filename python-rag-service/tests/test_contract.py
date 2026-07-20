from fastapi.testclient import TestClient


def test_internal_auth_is_required(monkeypatch):
    monkeypatch.setenv("RAG_SERVICE_TOKEN", "test-token")
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: object())
    with TestClient(main.app) as client:
        response = client.post("/internal/rag/analyze", json={"text": "学生请假规定"})
        assert response.status_code == 401


def test_chinese_analyze_contract(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: object())
    with TestClient(main.app) as client:
        response = client.post(
            "/internal/rag/analyze",
            headers={"X-Internal-Service-Token": "test-token"},
            json={"text": "学生请假规定"},
        )
        assert response.status_code == 200
        assert response.json()["search_string"]
