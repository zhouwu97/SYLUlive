from app.providers import chat


def test_openai_compatible_provider_enforces_allowlist_and_output_limit(monkeypatch):
    captured: dict[str, object] = {}

    def fake_chat_openai(**kwargs):
        captured.update(kwargs)
        return object()

    monkeypatch.setenv("RAG_CHAT_PROVIDER", "openai-compatible")
    monkeypatch.setenv("RAG_CHAT_MODEL", "approved-model")
    monkeypatch.setenv("RAG_PROVIDER_API_KEY", "test-secret")
    monkeypatch.setenv("RAG_PROVIDER_BASE_URL", "https://api.example.test/v1/")
    monkeypatch.setenv("RAG_PROVIDER_ALLOWED_BASE_URLS", "https://api.example.test/v1")
    monkeypatch.setenv("RAG_PROVIDER_TIMEOUT_SECONDS", "999")
    monkeypatch.setenv("RAG_PROVIDER_MAX_OUTPUT_TOKENS", "99999")
    monkeypatch.setattr(chat, "ChatOpenAI", fake_chat_openai)

    provider = chat.build_policy_chat_provider()

    assert provider.ready is True
    assert captured["model"] == "approved-model"
    assert captured["base_url"] == "https://api.example.test/v1"
    assert captured["timeout"] == 120
    assert captured["max_retries"] == 1
    assert captured["max_tokens"] == 4096
    assert captured["streaming"] is True


def test_provider_rejects_request_target_outside_allowlist(monkeypatch):
    monkeypatch.setenv("RAG_CHAT_PROVIDER", "openai-compatible")
    monkeypatch.setenv("RAG_CHAT_MODEL", "approved-model")
    monkeypatch.setenv("RAG_PROVIDER_API_KEY", "test-secret")
    monkeypatch.setenv("RAG_PROVIDER_BASE_URL", "https://untrusted.example.test/v1")
    monkeypatch.setenv("RAG_PROVIDER_ALLOWED_BASE_URLS", "https://api.example.test/v1")

    provider = chat.build_policy_chat_provider()

    assert provider.ready is False
