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
from langchain_core.runnables import RunnableLambda
from pydantic import PrivateAttr

from app.chains import (
    astream_policy_events,
    bound_policy_history,
    build_policy_query_rewriter,
    build_policy_rag_chain,
)
from app.providers import FakePolicyChatModel
from app.retrievers import FakePolicyRetriever
from app.schemas import PolicyHistoryMessage, PolicyRAGInput, PolicyRAGResult


def _answer_json(
    *,
    answer: str = "请按学生手册履行审批手续。",
    current_rules: list[dict[str, object]] | None = None,
    historical_rules: list[dict[str, object]] | None = None,
    warnings: list[str] | None = None,
    citations: list[dict[str, str]] | None = None,
) -> str:
    return json.dumps(
        {
            "answer": answer,
            "current_rules": current_rules
            if current_rules is not None
            else [{"statement": "学生请假应履行审批手续。", "citation_ids": ["R1"]}],
            "historical_rules": historical_rules or [],
            "warnings": warnings or [],
            "citations": citations
            if citations is not None
            else [{"reference_id": "R1", "quote": "学生请假应履行审批手续。"}],
            "confidence": "high",
        },
        ensure_ascii=False,
    )


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
        response_text=_answer_json(),
        input_tokens=20,
        output_tokens=8,
    )
    return build_policy_rag_chain(
        retriever,
        model,
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    )


class RecordingPolicyChatModel(FakePolicyChatModel):
    _messages: list[BaseMessage] = PrivateAttr(default_factory=list)

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        self._messages = list(messages)
        return super()._generate(messages, stop, run_manager, **kwargs)


def test_policy_chain_invoke_uses_lcel_runnable():
    result = fake_chain().invoke(
        PolicyRAGInput(request_id="invoke-1", question="怎么请假")
    )

    assert isinstance(result, PolicyRAGResult)
    assert result.status == "completed"
    assert result.chain_name == "shenliyuan_policy_rag"
    assert result.chain_version == "conversation-context-v4"
    assert result.sources[0].chunk_id == 18
    assert result.sources[0].citation_number == 1
    assert result.usage.input_tokens == 20


def test_prompt_uses_query_plan_temporary_references_and_pydantic_schema():
    model = RecordingPolicyChatModel(
        response_text=_answer_json(), input_tokens=20, output_tokens=8
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="学生请假应履行审批手续。",
                    metadata={"document_id": 9, "chunk_id": 18, "title": "学生手册"},
                )
            ]
        ),
        model,
        provider_name="fake",
        model_name="fake-v1",
    )

    chain.invoke(PolicyRAGInput(request_id="prompt", question="怎么请假"))

    prompt_text = "\n".join(str(message.content) for message in model._messages)
    assert '"normalized_question":"怎么请假"' in prompt_text
    assert '"reference_id": "R1"' in prompt_text
    assert "chunk_id" not in prompt_text
    assert "current_rules" in prompt_text
    assert "historical_rules" in prompt_text


def test_query_rewrite_runnable_completes_short_follow_up_for_retrieval():
    request = PolicyRAGInput(
        request_id="follow-up",
        question="那实验课呢",
        history=[
            PolicyHistoryMessage(role="user", content="补考成绩怎么算"),
            PolicyHistoryMessage(role="assistant", content="补考规则需要区分现行与历史口径。"),
        ],
    )

    rewritten = build_policy_query_rewriter().invoke(request)

    assert rewritten == "补考成绩怎么算；追问：那实验课呢"


def test_follow_up_chain_uses_rewritten_query_and_bounded_history_messages():
    queries: list[str] = []
    documents = [
        Document(
            page_content="实验、实习等实践教学环节不安排补考，应按培养方案重新修读。",
            metadata={
                "document_id": 12,
                "chunk_id": 31,
                "title": "本科课程考核管理办法",
                "source_locator": "第二十二条",
            },
        )
    ]

    def retrieve(query: str) -> list[Document]:
        queries.append(query)
        return documents

    model = RecordingPolicyChatModel(
        response_text=_answer_json(
            answer="实验等实践教学环节不安排补考，应重新修读。",
            current_rules=[
                {
                    "statement": "实验等实践教学环节不安排补考，应重新修读。",
                    "citation_ids": ["R1"],
                }
            ],
            citations=[
                {
                    "reference_id": "R1",
                    "quote": "实验、实习等实践教学环节不安排补考，应按培养方案重新修读。",
                }
            ],
        ),
        input_tokens=24,
        output_tokens=10,
    )
    chain = build_policy_rag_chain(
        RunnableLambda(retrieve),
        model,
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(
            request_id="follow-up-chain",
            question="那实验课呢",
            history=[
                PolicyHistoryMessage(role="user", content="补考成绩怎么算"),
                PolicyHistoryMessage(
                    role="assistant", content="补考规则需要区分现行与历史口径。"
                ),
            ],
        )
    )

    assert result.status == "completed"
    assert queries == ["补考成绩怎么算；追问：那实验课呢"]
    prompt_messages = [str(message.content) for message in model._messages]
    assert "补考成绩怎么算" in prompt_messages
    assert "补考规则需要区分现行与历史口径。" in prompt_messages


def test_python_history_copy_is_deterministically_bounded_by_complete_rounds():
    history: list[PolicyHistoryMessage] = []
    for index in range(4):
        history.extend(
            [
                PolicyHistoryMessage(role="user", content=f"问题{index}" * 200),
                PolicyHistoryMessage(role="assistant", content=f"回答{index}" * 500),
            ]
        )

    bounded = bound_policy_history(history)

    assert bounded
    assert len(bounded) <= 8
    assert len(bounded) % 2 == 0
    assert [item.role for item in bounded] == ["user", "assistant"] * (len(bounded) // 2)
    assert sum(len(item.content) for item in bounded) <= 2_400
    assert all(len(item.content) <= (300 if item.role == "user" else 600) for item in bounded)


@pytest.mark.asyncio
async def test_policy_chain_ainvoke_uses_fake_components_without_network():
    result = await fake_chain().ainvoke(
        PolicyRAGInput(request_id="ainvoke-1", question="怎么请假")
    )

    assert result.request_id == "ainvoke-1"
    assert result.usage.output_tokens == 8
    assert "[1]" in result.answer
    assert "chunk" not in result.answer


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
        assert response.json()["chain_version"] == "conversation-context-v4"

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
                "chain_version": "conversation-context-v4",
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


def test_forged_temporary_citation_is_rejected_without_exposing_model_answer():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="学生请假应履行审批手续。",
                    metadata={"document_id": 1, "chunk_id": 7, "title": "学生手册"},
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                current_rules=[{"statement": "伪造规定", "citation_ids": ["R9"]}],
                citations=[{"reference_id": "R9", "quote": "学生请假应履行审批手续。"}],
            ),
            input_tokens=12,
            output_tokens=8,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(PolicyRAGInput(request_id="forged", question="怎么请假"))

    assert result.status == "citation_rejected"
    assert result.answer == "当前已发布资料不足，暂时无法给出可核验回答。"
    assert result.sources == []
    assert result.usage.metered is True


def test_current_and_historical_rules_keep_explicit_version_boundary():
    documents = [
        Document(
            page_content="现行规定：考核不合格课程应按当前重修办法处理。",
            metadata={
                "document_id": 1,
                "chunk_id": 11,
                "title": "现行重修办法",
                "historical": False,
            },
        ),
        Document(
            page_content="历史二次考试成绩及格等级为D、绩点为1；不及格等级为F、绩点为0。",
            metadata={
                "document_id": 2,
                "chunk_id": 22,
                "title": "历史二考规则",
                "historical": True,
            },
        ),
    ]
    model_output = _answer_json(
        answer="历史材料记载二考的等级与绩点，但当前执行口径仍需核验。",
        current_rules=[
            {"statement": "考核不合格课程应按当前重修办法处理。", "citation_ids": ["R1"]}
        ],
        historical_rules=[
            {
                "statement": "二考及格等级为D、绩点为1；不及格等级为F、绩点为0。",
                "citation_ids": ["R2"],
            }
        ],
        warnings=["历史规则不代表当前执行口径，请以教务系统或当期通知核验。"],
        citations=[
            {"reference_id": "R1", "quote": "考核不合格课程应按当前重修办法处理。"},
            {
                "reference_id": "R2",
                "quote": "二次考试成绩及格等级为D、绩点为1；不及格等级为F、绩点为0。",
            },
        ],
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=documents),
        FakePolicyChatModel(response_text=model_output, input_tokens=30, output_tokens=20),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="history", question="补考成绩怎么算")
    )

    assert result.status == "completed"
    assert "等级为D、绩点为1" in result.answer
    assert "等级为F、绩点为0" in result.answer
    assert "历史规则（不代表当前执行口径）" in result.answer
    assert "教务系统或当期通知核验" in result.answer
    assert "chunk" not in result.answer


def test_general_query_cannot_cite_historical_candidate():
    documents = [
        Document(
            page_content="学生请假应履行审批手续。",
            metadata={"document_id": 1, "chunk_id": 1, "title": "现行手册"},
        ),
        Document(
            page_content="旧请假规则仅供历史研究。",
            metadata={
                "document_id": 2,
                "chunk_id": 2,
                "title": "旧手册",
                "historical": True,
            },
        ),
    ]
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=documents),
        FakePolicyChatModel(
            response_text=_answer_json(
                current_rules=[],
                historical_rules=[{"statement": "旧请假规则", "citation_ids": ["R2"]}],
                warnings=["历史规则仅供参考，请以教务系统或当期通知核验。"],
                citations=[{"reference_id": "R2", "quote": "旧请假规则仅供历史研究。"}],
            ),
            input_tokens=10,
            output_tokens=8,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(PolicyRAGInput(request_id="current-only", question="怎么请假"))

    assert result.status == "citation_rejected"


def test_unsupported_score_composition_is_rejected_deterministically():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="补考安排由教务处另行通知。",
                    metadata={"document_id": 1, "chunk_id": 1, "title": "考试通知"},
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                answer="平时成绩与补考卷面按比例合成。",
                current_rules=[
                    {"statement": "平时成绩与补考卷面按比例合成。", "citation_ids": ["R1"]}
                ],
                citations=[{"reference_id": "R1", "quote": "补考安排由教务处另行通知。"}],
            ),
            input_tokens=10,
            output_tokens=8,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(PolicyRAGInput(request_id="unsupported-calc", question="补考怎么算"))

    assert result.status == "citation_rejected"
    assert "平时成绩" not in result.answer


def test_invalid_structured_output_is_metered_and_fails_closed():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="学生请假应履行审批手续。",
                    metadata={"document_id": 1, "chunk_id": 1, "title": "学生手册"},
                )
            ]
        ),
        FakePolicyChatModel(response_text="不是 JSON", input_tokens=9, output_tokens=3),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(PolicyRAGInput(request_id="invalid-json", question="怎么请假"))

    assert result.status == "citation_rejected"
    assert result.warnings == ["rag_structured_output_invalid"]
    assert result.usage.input_tokens == 9
    assert result.usage.output_tokens == 3
