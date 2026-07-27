from fastapi.testclient import TestClient


class _ReadyTextEmbedding:
    def embed(self, texts):
        for _ in texts:
            yield [0.0] * 384


def test_internal_auth_is_required(monkeypatch):
    monkeypatch.setenv("RAG_SERVICE_TOKEN", "test-token")
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: _ReadyTextEmbedding())
    with TestClient(main.app) as client:
        response = client.post("/internal/rag/analyze", json={"text": "学生请假规定"})
        assert response.status_code == 401


def test_chinese_analyze_contract(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: _ReadyTextEmbedding())
    with TestClient(main.app) as client:
        response = client.post(
            "/internal/rag/analyze",
            headers={"X-Internal-Service-Token": "test-token"},
            json={"text": "学生请假规定"},
        )
        assert response.status_code == 200
        assert response.json()["search_string"]


def test_health_exposes_chain_identity_and_dependency_readiness(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: _ReadyTextEmbedding())
    with TestClient(main.app) as client:
        response = client.get(
            "/health",
            headers={"X-Internal-Service-Token": "test-token"},
        )
        assert response.status_code == 200
        payload = response.json()
        assert payload["chain_name"] == "shenliyuan_policy_rag"
        assert payload["chain_version"] == "foundation-v1"
        assert payload["dimensions"] == 384
        assert payload["dependencies_ready"]["embedding"] is True
        assert payload["dependencies_ready"]["lcel"] is True
        assert "chat_provider" in payload["dependencies_ready"]
