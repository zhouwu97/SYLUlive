import asyncio
import json
from collections.abc import AsyncIterator

import pytest
from fastapi.testclient import TestClient
from langchain_core.callbacks import AsyncCallbackManagerForLLMRun, CallbackManagerForLLMRun
from langchain_core.documents import Document
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessageChunk, BaseMessage
from langchain_core.outputs import ChatGenerationChunk, ChatResult
from pydantic import PrivateAttr

from app.chains import astream_policy_events, build_policy_rag_chain
from app.providers import FakePolicyChatModel
from app.retrievers import FakePolicyRetriever
from app.schemas import PolicyRAGInput, PolicyRAGResult


def fake_chain():
    retriever = FakePolicyRetriever(
        documents=[
            Document(
                page_content="学生请假应履行审批手续。",
                metadata={
                    "source_id": "source-1",
                    "document_id": 9,
                    "chunk_id": 18,
                    "title": "学生手册",
                    "department": "学生处",
                    "source_locator": "第十条",
                },
            )
        ]
    )
    model = FakePolicyChatModel(
        response_text="请按学生手册履行审批手续。[chunk:18]",
        input_tokens=20,
        output_tokens=8,
    )
    return build_policy_rag_chain(
        retriever,
        model,
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    )


def test_policy_chain_invoke_uses_lcel_runnable():
    result = fake_chain().invoke(
        PolicyRAGInput(request_id="invoke-1", question="怎么请假")
    )

    assert isinstance(result, PolicyRAGResult)
    assert result.status == "completed"
    assert result.chain_name == "shenliyuan_policy_rag"
    assert result.chain_version == "hybrid-retrieval-v1"
    assert result.sources[0].chunk_id == 18
    assert result.usage.input_tokens == 20


@pytest.mark.asyncio
async def test_policy_chain_ainvoke_uses_fake_components_without_network():
    result = await fake_chain().ainvoke(
        PolicyRAGInput(request_id="ainvoke-1", question="怎么请假")
    )

    assert result.request_id == "ainvoke-1"
    assert result.usage.output_tokens == 8
    assert "[chunk:18]" in result.answer


@pytest.mark.asyncio
async def test_policy_chain_astream_events_contains_stages_tokens_and_result():
    events = [
        event
        async for event in astream_policy_events(
            fake_chain(),
            PolicyRAGInput(request_id="stream-1", question="怎么请假"),
        )
    ]

    event_types = [event.type for event in events]
    assert event_types[:2] == ["planning", "retrieving"]
    assert "generating" in event_types
    assert "token" in event_types
    assert event_types[-1] == "completed"
    assert events[-1].result is not None
    assert events[-1].result.usage.input_tokens == 20
    assert [event.sequence for event in events] == list(range(1, len(events) + 1))


def test_policy_query_endpoints_use_injected_lcel_chain(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    main.app.state.policy_chain = fake_chain()

    class ReadyTextEmbedding:
        def embed(self, texts):
            for _ in texts:
                yield [0.0] * 384

    monkeypatch.setattr(main, "TextEmbedding", lambda **_: ReadyTextEmbedding())
    with TestClient(main.app) as client:
        headers = {"X-Internal-Service-Token": "test-token"}
        response = client.post(
            "/internal/rag/policy/query",
            headers=headers,
            json={"request_id": "http-1", "question": "怎么请假"},
        )
        assert response.status_code == 200, response.text
        assert response.json()["chain_version"] == "hybrid-retrieval-v1"

        with client.stream(
            "POST",
            "/internal/rag/policy/query/stream",
            headers=headers,
            json={"request_id": "http-stream-1", "question": "怎么请假"},
        ) as stream:
            assert stream.status_code == 200
            frames = [line for line in stream.iter_lines() if line.startswith("data: ")]
        payloads = [json.loads(frame.removeprefix("data: ")) for frame in frames]
        assert payloads[-1]["type"] == "completed"
        assert payloads[-1]["result"]["request_id"] == "http-stream-1"

    del main.app.state.policy_chain


def test_foundation_chain_fails_closed_without_sources():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[]),
        FakePolicyChatModel(response_text="不应被调用", input_tokens=1, output_tokens=1),
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    )
    result = chain.invoke(PolicyRAGInput(request_id="empty-1", question="未知规定"))

    assert result.status == "insufficient_sources"
    assert result.sources == []
    assert result.usage.metered is False
    assert result.warnings == ["rag_insufficient_sources"]


def test_completed_result_rejects_missing_usage():
    with pytest.raises(ValueError, match="metered usage"):
        PolicyRAGResult.model_validate(
            {
                "request_id": "bad-usage",
                "chain_name": "shenliyuan_policy_rag",
                "chain_version": "hybrid-retrieval-v1",
                "status": "completed",
                "answer": "回答",
                "sources": [],
                "usage": {
                    "provider": "fake",
                    "model": "fake",
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_hit_tokens": 0,
                    "metered": False,
                },
            }
        )


class BlockingPolicyChatModel(BaseChatModel):
    _started: asyncio.Event = PrivateAttr(default_factory=asyncio.Event)
    _cancelled: asyncio.Event = PrivateAttr(default_factory=asyncio.Event)

    @property
    def _llm_type(self) -> str:
        return "blocking-policy-chat"

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        raise RuntimeError("sync generation is not supported")

    async def _agenerate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: AsyncCallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        self._started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            self._cancelled.set()
            raise

    async def _astream(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: AsyncCallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> AsyncIterator[ChatGenerationChunk]:
        self._started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            self._cancelled.set()
            raise
        yield ChatGenerationChunk(message=AIMessageChunk(content=""))


@pytest.mark.asyncio
async def test_astream_events_cancellation_reaches_chat_model():
    model = BlockingPolicyChatModel()
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="固定证据",
                    metadata={"document_id": 1, "chunk_id": 1, "title": "测试政策"},
                )
            ]
        ),
        model,
        provider_name="fake",
        model_name="blocking-v1",
    )
    iterator = astream_policy_events(
        chain,
        PolicyRAGInput(request_id="cancel-stream", question="请假"),
    )
    while True:
        event = await anext(iterator)
        if event.type == "generating":
            break

    pending = asyncio.create_task(anext(iterator))
    await asyncio.wait_for(model._started.wait(), timeout=1)
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    await asyncio.wait_for(model._cancelled.wait(), timeout=1)
    await iterator.aclose()
