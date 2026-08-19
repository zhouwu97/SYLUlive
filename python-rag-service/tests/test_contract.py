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
        assert payload["chain_version"] == "campus-assistant-release-v8"
        assert payload["dimensions"] == 384
        assert payload["dependencies_ready"]["embedding"] is True
        assert payload["dependencies_ready"]["lcel"] is True
        assert "chat_provider" in payload["dependencies_ready"]
        assert "policy_database" in payload["dependencies_ready"]
        assert payload["reranker"]["query_strategy"] == "policy-planned-query-v1"
        assert (
            payload["reranker"]["document_type_label_version"]
            == "policy-document-type-zh-v1"
        )
        assert payload["rollback_switches"] == {
            "retriever_enabled": True,
            "reranker_enabled": False,
            "generation_enabled": True,
            "shadow_index_enabled": True,
        }
        assert payload["observability"] == {
            "mode": "local_only",
            "langsmith_enabled": False,
            "stores_sensitive_content": False,
        }


def test_policy_plan_endpoint_uses_the_single_python_domain_planner(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: _ReadyTextEmbedding())
    with TestClient(main.app) as client:
        response = client.post(
            "/internal/rag/policy/plan",
            headers={"X-Internal-Service-Token": "test-token"},
            json={"text": "补烤成绩怎摸算"},
        )

    assert response.status_code == 200
    payload = response.json()
    assert payload["planner_name"] == "policy_query_planner"
    assert payload["normalized_question"] == "补考成绩怎么算"
    assert payload["allow_historical"] is True
