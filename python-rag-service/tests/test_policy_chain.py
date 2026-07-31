import asyncio
import json
from collections.abc import AsyncIterator

import pytest
from fastapi.testclient import TestClient
from langchain_core.callbacks import AsyncCallbackManagerForLLMRun, CallbackManagerForLLMRun
from langchain_core.documents import Document
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, BaseMessage
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.outputs import ChatGeneration, ChatGenerationChunk, ChatResult
from langchain_core.runnables import RunnableLambda
from pydantic import PrivateAttr

from app.chains import (
    astream_policy_events,
    bound_policy_history,
    build_policy_query_rewriter,
    build_policy_rag_chain,
)
from app.chains.policy import _bounded_documents, _parser_failure_reason
from app.chains.query_planner import PolicyQueryPlanner
from app.providers import FakePolicyChatModel
from app.retrievers import FakePolicyRetriever
from app.schemas import PolicyAnswer, PolicyHistoryMessage, PolicyRAGInput, PolicyRAGResult


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


class SequencedPolicyChatModel(FakePolicyChatModel):
    _responses: list[str] = PrivateAttr()
    _call_count: int = PrivateAttr(default=0)

    def __init__(self, responses: list[str], **kwargs: object) -> None:
        if not responses:
            raise ValueError("responses must not be empty")
        super().__init__(response_text=responses[-1], **kwargs)
        self._responses = list(responses)

    @property
    def call_count(self) -> int:
        return self._call_count

    def _next_response(self) -> str:
        index = min(self._call_count, len(self._responses) - 1)
        self._call_count += 1
        return self._responses[index]

    def _message(self, response: str) -> AIMessage:
        return AIMessage(
            content=response,
            usage_metadata=self._usage(),
            response_metadata={"cache_hit_tokens": self.cache_hit_tokens},
        )

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        del messages, stop, run_manager, kwargs
        return ChatResult(
            generations=[ChatGeneration(message=self._message(self._next_response()))]
        )

    def _stream(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ):
        del messages, stop, run_manager, kwargs
        response = self._next_response()
        yield ChatGenerationChunk(message=AIMessageChunk(content=response))
        yield ChatGenerationChunk(
            message=AIMessageChunk(
                content="",
                usage_metadata=self._usage(),
                response_metadata={"cache_hit_tokens": self.cache_hit_tokens},
            )
        )


def test_policy_chain_invoke_uses_lcel_runnable():
    result = fake_chain().invoke(
        PolicyRAGInput(request_id="invoke-1", question="怎么请假")
    )

    assert isinstance(result, PolicyRAGResult)
    assert result.status == "completed"
    assert result.chain_name == "shenliyuan_policy_rag"
    assert result.chain_version == "campus-assistant-release-v8"
    assert result.sources[0].chunk_id == 18
    assert result.sources[0].citation_number == 1
    assert result.usage.input_tokens == 20


def test_policy_chain_drops_unrelated_policy_facts_from_warning_section():
    retriever = FakePolicyRetriever(
        documents=[
            Document(
                page_content="奖学金实行申报制，由学院组织评审。",
                metadata={
                    "document_id": 17,
                    "chunk_id": 41,
                    "title": "本科生奖学金评审办法",
                    "document_type": "school_undergraduate_scholarship_policy",
                },
            )
        ]
    )
    model = FakePolicyChatModel(
        response_text=_answer_json(
            answer="奖学金实行申报制。",
            current_rules=[
                {"statement": "奖学金由学院组织评审。", "citation_ids": ["R1"]}
            ],
            warnings=[
                "孤儿学生还可以申请学费住宿费减免。",
                "具体申报时间以学生处或学院当期通知为准。",
            ],
            citations=[
                {
                    "reference_id": "R1",
                    "quote": "奖学金实行申报制，由学院组织评审。",
                }
            ],
        ),
        input_tokens=20,
        output_tokens=8,
    )

    result = build_policy_rag_chain(
        retriever,
        model,
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    ).invoke(PolicyRAGInput(request_id="bounded-warnings", question="奖学金怎么评"))

    assert result.status == "completed"
    assert result.warnings == ["具体申报时间以学生处或学院当期通知为准。"]
    assert "孤儿学生" not in result.answer


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
    assert "answer 不超过 300 个中文字符" in prompt_text
    assert "每个 quote 不超过 160 个中文字符" in prompt_text
    assert "用户未明确询问“成绩怎么算" in prompt_text


def test_evidence_budget_reapplies_planner_document_preference_after_reranking():
    plan = PolicyQueryPlanner().invoke("挂科后该咋办")
    documents = [
        Document(
            page_content="补考成绩按课程比例合成。",
            metadata={
                "document_id": 1,
                "chunk_id": 1,
                "document_type": "school_makeup_exam_current_practice",
            },
        ),
        Document(
            page_content="课程成绩不合格未取得相应学分者可以参加重修。",
            metadata={
                "document_id": 2,
                "chunk_id": 2,
                "document_type": "school_undergraduate_retake_policy",
            },
        ),
        Document(
            page_content="课程考核成绩不合格者需参加二次考试或重新学习。",
            metadata={
                "document_id": 3,
                "chunk_id": 3,
                "document_type": "school_undergraduate_status_policy",
            },
        ),
    ]

    selected = _bounded_documents(
        {
            "request": PolicyRAGInput(
                request_id="preferred-evidence",
                question="挂科后该咋办",
                max_sources=2,
            ),
            "query_plan": plan,
            "documents": documents,
        }
    )

    assert [item.metadata["document_type"] for item in selected] == [
        "school_undergraduate_retake_policy",
        "school_undergraduate_status_policy",
    ]


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
        assert response.json()["chain_version"] == "campus-assistant-release-v8"

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


def test_foundation_chain_answers_general_question_without_sources():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[]),
        FakePolicyChatModel(
            response_text="你好，我是沈理校园 AI。你可以问我课程、考试或校园办事问题。",
            input_tokens=12,
            output_tokens=10,
        ),
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    )
    result = chain.invoke(PolicyRAGInput(request_id="empty-1", question="hello"))

    assert result.status == "general_completed"
    assert result.answer_mode == "general_answer"
    assert "你好" in result.answer
    assert result.sources == []
    assert result.usage.metered is True
    assert result.warnings == ["campus_sources_unavailable"]


def test_foundation_chain_guides_campus_question_without_sources():
    model = RecordingPolicyChatModel(
        response_text=(
            "我暂时无法核验你所在宿舍的当前门禁时间。"
            "请先查看所在公寓的最新通知，或补充校区和公寓名称。"
        ),
        input_tokens=18,
        output_tokens=16,
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[]),
        model,
        provider_name="fake",
        model_name="fake-policy-chat-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="guided-gap", question="宿舍几点关门")
    )

    assert result.status == "general_completed"
    assert result.answer_mode == "guided_gap"
    assert "公寓" in result.answer
    assert "门禁时间" in result.answer
    assert result.sources == []
    prompt_text = "\n".join(str(message.content) for message in model._messages)
    assert "不要猜测校内结论" in prompt_text


def test_general_question_ignores_incidental_campus_source():
    model = RecordingPolicyChatModel(
        response_text="你好，我可以帮你处理校园学习和办事问题。",
        input_tokens=10,
        output_tokens=8,
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
        model_name="fake-policy-chat-v1",
    )

    result = chain.invoke(PolicyRAGInput(request_id="incidental", question="hello"))

    assert result.status == "general_completed"
    assert result.answer_mode == "general_answer"
    assert result.sources == []
    prompt_text = "\n".join(str(message.content) for message in model._messages)
    assert "学生请假应履行审批手续" not in prompt_text


def test_completed_result_rejects_missing_usage():
    with pytest.raises(ValueError, match="metered usage"):
        PolicyRAGResult.model_validate(
            {
                "request_id": "bad-usage",
                "chain_name": "shenliyuan_policy_rag",
                "chain_version": "campus-assistant-release-v6",
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
    assert "无法从已发布的校园资料中核验" in result.answer
    assert result.sources == []
    assert result.usage.metered is True


def test_same_source_composite_quote_is_accepted_when_every_fragment_is_verbatim():
    evidence = (
        "各类奖学金实行申报制，未在规定时间申报视为自动放弃。"
        "学院审核与评审后，学院公示不少于 2 个工作日；"
        "学校审定后再公示 5 个工作日。\n\n"
        "## 校长奖学金\n"
        "- 学业门槛：综合测评 3.5 以上；本年级本专业前 10%。"
    )
    composite_quote = (
        "各类奖学金实行申报制，未在规定时间申报视为自动放弃。"
        "校长奖学金：综合测评 3.5 以上；本年级本专业前 10%。"
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content=evidence,
                    metadata={
                        "document_id": 17,
                        "chunk_id": 41,
                        "title": "本科生奖学金评审办法",
                    },
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                answer="奖学金实行申报制，校长奖学金还设有综合测评和专业排名门槛。",
                current_rules=[
                    {
                        "statement": "校长奖学金要求综合测评 3.5 以上、专业排名前 10%。",
                        "citation_ids": ["R1"],
                    }
                ],
                citations=[
                    {
                        "reference_id": "R1",
                        "quote": composite_quote,
                    }
                ],
            ),
            input_tokens=24,
            output_tokens=12,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="composite-quote", question="奖学金怎么评")
    )

    assert result.status == "completed"
    assert result.sources[0].document_type == ""


def test_repeated_reference_id_is_accepted_when_each_quote_is_verbatim():
    evidence = "学生申请转专业，应当由学校审核。学校根据社会需求和办学条件调整专业。"
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content=evidence,
                    metadata={
                        "document_id": 19,
                        "chunk_id": 51,
                        "title": "本科生转专业管理办法",
                    },
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                answer="转专业需要学校审核。",
                current_rules=[
                    {"statement": "转专业申请由学校审核。", "citation_ids": ["R1"]},
                    {
                        "statement": "学校会结合办学条件调整专业。",
                        "citation_ids": ["R1"],
                    },
                ],
                citations=[
                    {"reference_id": "R1", "quote": "学生申请转专业，应当由学校审核。"},
                    {
                        "reference_id": "R1",
                        "quote": "学校根据社会需求和办学条件调整专业。",
                    },
                ],
            ),
            input_tokens=24,
            output_tokens=12,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="repeated-reference", question="能转专业吗")
    )

    assert result.status == "completed"
    assert [source.source_id for source in result.sources] == ["R1"]


def test_same_source_composite_quote_rejects_any_fabricated_fragment():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="奖学金实行申报制。学院审核后公示。",
                    metadata={
                        "document_id": 17,
                        "chunk_id": 41,
                        "title": "本科生奖学金评审办法",
                    },
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                current_rules=[
                    {
                        "statement": "奖学金实行申报制。",
                        "citation_ids": ["R1"],
                    }
                ],
                citations=[
                    {
                        "reference_id": "R1",
                        "quote": "奖学金实行申报制。无需申报即可自动获得。",
                    }
                ],
            ),
            input_tokens=20,
            output_tokens=10,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="fabricated-fragment", question="奖学金怎么评")
    )

    assert result.status == "citation_rejected"


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
    assert result.usage.input_tokens == 18
    assert result.usage.output_tokens == 6


def test_failed_course_question_falls_back_to_current_extractive_evidence():
    documents = [
        Document(
            page_content=(
                "课程考核成绩不合格者，需参加由学校组织的二次考试或重新学习，"
                "成绩合格者获得学分。"
            ),
            metadata={
                "document_id": 8,
                "chunk_id": 20,
                "title": "本科生学籍管理规定",
                "document_type": "school_undergraduate_status_policy",
            },
        ),
        Document(
            page_content=(
                "课程重修是指学生对按教学计划已修读过的课程进行重新修读并考核。"
                "课程成绩不合格未取得相应学分者可以参加相应课程重修。"
            ),
            metadata={
                "document_id": 9,
                "chunk_id": 30,
                "title": "本科生课程重修管理办法",
                "document_type": "school_undergraduate_retake_policy",
            },
        ),
    ]
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=documents),
        FakePolicyChatModel(response_text="不是 JSON", input_tokens=9, output_tokens=3),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="failed-course-extractive", question="挂科后该咋办")
    )

    assert result.status == "completed"
    assert "二次考试" in result.answer
    assert "课程重修" in result.answer
    assert "比例" not in result.answer
    assert {source.document_type for source in result.sources} == {
        "school_undergraduate_status_policy",
        "school_undergraduate_retake_policy",
    }


def test_parser_failure_reason_exposes_only_schema_locations_and_error_types():
    parser = PydanticOutputParser(pydantic_object=PolicyAnswer)

    with pytest.raises(Exception) as captured:
        parser.invoke(AIMessage(content='{"answer":"有答案","citations":[]}'))

    reason = _parser_failure_reason(captured.value)
    assert "citations(too_short)" in reason
    assert "confidence(missing)" in reason
    assert "有答案" not in reason


def test_descriptive_answer_can_cite_evidence_without_policy_rule_list():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="计算机专业主要学习程序设计、数据结构和计算机系统。",
                    metadata={
                        "document_id": 3,
                        "chunk_id": 8,
                        "title": "计算机科学与技术专业介绍",
                        "document_type": "official_major_profile",
                    },
                )
            ]
        ),
        FakePolicyChatModel(
            response_text=_answer_json(
                answer="计算机专业主要学习程序设计、数据结构和计算机系统。",
                current_rules=[],
                citations=[
                    {
                        "reference_id": "R1",
                        "quote": "计算机专业主要学习程序设计、数据结构和计算机系统。",
                    }
                ],
            ),
            input_tokens=20,
            output_tokens=8,
        ),
        provider_name="fake",
        model_name="fake-v1",
    )

    result = chain.invoke(
        PolicyRAGInput(request_id="descriptive-profile", question="计算机专业学什么")
    )

    assert result.status == "completed"
    assert result.sources[0].document_type == "official_major_profile"


@pytest.mark.asyncio
async def test_invalid_first_generation_retries_once_and_aggregates_usage():
    model = SequencedPolicyChatModel(
        responses=["不是 JSON", _answer_json()],
        input_tokens=9,
        output_tokens=3,
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(
            documents=[
                Document(
                    page_content="学生请假应履行审批手续。",
                    metadata={
                        "document_id": 1,
                        "chunk_id": 1,
                        "title": "学生手册",
                    },
                )
            ]
        ),
        model,
        provider_name="fake",
        model_name="fake-v1",
    )

    result = await chain.ainvoke(
        PolicyRAGInput(request_id="retry-invalid-json", question="怎么请假")
    )

    assert result.status == "completed"
    assert model.call_count == 2
    assert result.usage.input_tokens == 18
    assert result.usage.output_tokens == 6
