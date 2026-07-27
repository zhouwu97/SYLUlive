from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Any

from langchain_core.documents import Document
from langchain_core.documents.compressor import BaseDocumentCompressor
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, BaseMessage, HumanMessage
from langchain_core.runnables import (
    Runnable,
    RunnableBranch,
    RunnableLambda,
    RunnableParallel,
    RunnablePassthrough,
    RunnableConfig,
)
from langchain.retrievers.contextual_compression import ContextualCompressionRetriever

from app.prompts import build_foundation_policy_prompt
from app.schemas import (
    PolicyHistoryMessage,
    PolicyRAGEvent,
    PolicyRAGInput,
    PolicyRAGResult,
    PolicySource,
    PolicyUsage,
)


POLICY_RAG_CHAIN_NAME = "shenliyuan_policy_rag"
POLICY_RAG_CHAIN_VERSION = "reranker-gate-v2"
INSUFFICIENT_ANSWER = "当前已发布资料不足，暂时无法给出可核验回答。"


def _normalize_input(value: PolicyRAGInput | dict[str, Any]) -> PolicyRAGInput:
    request = value if isinstance(value, PolicyRAGInput) else PolicyRAGInput.model_validate(value)
    normalized = request.question.strip()
    if not normalized:
        raise ValueError("empty policy question")
    return request.model_copy(update={"question": normalized})


def _query_text(request: PolicyRAGInput) -> str:
    return request.question


def _history_messages(history: list[PolicyHistoryMessage]) -> list[BaseMessage]:
    messages: list[BaseMessage] = []
    for item in history:
        if item.role == "user":
            messages.append(HumanMessage(content=item.content))
        else:
            messages.append(AIMessage(content=item.content))
    return messages


def _source_from_document(document: Document) -> PolicySource:
    metadata = document.metadata
    chunk_id = int(metadata.get("chunk_id", 0))
    document_id = int(metadata.get("document_id", 0))
    return PolicySource(
        source_id=str(metadata.get("source_id") or f"chunk:{chunk_id}"),
        document_id=document_id,
        chunk_id=chunk_id,
        title=str(metadata.get("title") or "未命名政策资料"),
        content=document.page_content,
        document_type=str(metadata.get("document_type") or ""),
        department=str(metadata.get("department") or ""),
        source_url=str(metadata.get("source_url") or ""),
        section_title=str(metadata.get("section_title") or ""),
        source_locator=str(metadata.get("source_locator") or ""),
        historical=bool(metadata.get("historical", False)),
    )


def _generation_context(state: dict[str, Any]) -> dict[str, Any]:
    request: PolicyRAGInput = state["request"]
    documents: list[Document] = state["documents"]
    context = "\n\n".join(
        f'<evidence chunk_id="{document.metadata.get("chunk_id", 0)}" '
        f'version="{"historical" if document.metadata.get("historical", False) else "current"}">\n'
        f"{document.page_content}\n</evidence>"
        for document in documents[: request.max_sources]
    )
    return {
        "question": request.question,
        "history": _history_messages(request.history),
        "context": context,
    }


def _message_text(message: BaseMessage) -> str:
    content = message.content
    if isinstance(content, str):
        return content.strip()
    return "".join(
        str(part.get("text", "")) if isinstance(part, dict) else str(part)
        for part in content
    ).strip()


def _usage_from_message(message: BaseMessage, provider_name: str, model_name: str) -> PolicyUsage:
    usage = getattr(message, "usage_metadata", None) or {}
    response_metadata = getattr(message, "response_metadata", None) or {}
    input_tokens = int(usage.get("input_tokens", 0))
    output_tokens = int(usage.get("output_tokens", 0))
    input_token_details = usage.get("input_token_details") or {}
    cache_hit_tokens = int(
        input_token_details.get("cache_read", response_metadata.get("cache_hit_tokens", 0))
    )
    return PolicyUsage(
        provider=provider_name,
        model=model_name,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_hit_tokens=cache_hit_tokens,
        metered=input_tokens + output_tokens > 0,
    )


def _parse_generated(state: dict[str, Any], provider_name: str, model_name: str) -> PolicyRAGResult:
    original: dict[str, Any] = state["state"]
    request: PolicyRAGInput = original["request"]
    documents: list[Document] = original["documents"][: request.max_sources]
    message: BaseMessage = state["message"]
    answer = _message_text(message)
    if not answer:
        raise ValueError("empty model answer")
    return PolicyRAGResult(
        request_id=request.request_id,
        chain_name=POLICY_RAG_CHAIN_NAME,
        chain_version=POLICY_RAG_CHAIN_VERSION,
        status="completed",
        answer=answer,
        sources=[_source_from_document(document) for document in documents],
        usage=_usage_from_message(message, provider_name, model_name),
        degraded_modes=_degraded_modes(documents),
    )


def _degraded_modes(documents: list[Document]) -> list[str]:
    modes: set[str] = set()
    for document in documents:
        value = document.metadata.get("degraded_modes", [])
        if isinstance(value, list):
            modes.update(str(item) for item in value if str(item))
    return sorted(modes)


def _insufficient(state: dict[str, Any], provider_name: str, model_name: str) -> PolicyRAGResult:
    request: PolicyRAGInput = state["request"]
    documents: list[Document] = state.get("documents", [])
    return PolicyRAGResult(
        request_id=request.request_id,
        chain_name=POLICY_RAG_CHAIN_NAME,
        chain_version=POLICY_RAG_CHAIN_VERSION,
        status="insufficient_sources",
        answer=INSUFFICIENT_ANSWER,
        warnings=["rag_insufficient_sources"],
        degraded_modes=_degraded_modes(documents),
        usage=PolicyUsage(
            provider=provider_name,
            model=model_name,
            input_tokens=0,
            output_tokens=0,
            metered=False,
        ),
    )


def _has_documents(state: dict[str, Any]) -> bool:
    return bool(state["documents"])


def _has_sufficient_reranked_evidence(
    state: dict[str, Any], relevance_threshold: float
) -> bool:
    documents: list[Document] = state["documents"]
    if not documents:
        return False
    scores: list[float] = []
    for document in documents:
        if document.metadata.get("rerank_applied") is not True:
            continue
        try:
            score = float(document.metadata["rerank_score"])
        except (KeyError, TypeError, ValueError):
            continue
        if 0 <= score <= 1:
            scores.append(score)
    return bool(scores) and max(scores) >= relevance_threshold


def _validate_result(result: PolicyRAGResult | dict[str, Any]) -> PolicyRAGResult:
    return result if isinstance(result, PolicyRAGResult) else PolicyRAGResult.model_validate(result)


def build_policy_rag_chain(
    retriever: Runnable[str, list[Document]],
    chat_model: BaseChatModel,
    *,
    provider_name: str,
    model_name: str,
    reranker: BaseDocumentCompressor | None = None,
    relevance_threshold: float = 0.5,
) -> Runnable[PolicyRAGInput, PolicyRAGResult]:
    if not 0 <= relevance_threshold <= 1:
        raise ValueError("relevance threshold must be between 0 and 1")
    validation = RunnableLambda(_normalize_input).with_config(run_name="input_validation")
    document_retriever: Runnable[str, list[Document]] = retriever
    if reranker is not None:
        document_retriever = ContextualCompressionRetriever(
            base_retriever=retriever,
            base_compressor=reranker,
        ).with_config(run_name="policy_reranking")
    retrieval = RunnableParallel(
        request=RunnablePassthrough(),
        documents=RunnableLambda(_query_text) | document_retriever,
    ).with_config(run_name="policy_retrieval")
    prompt = build_foundation_policy_prompt()

    def generate_sync(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = prompt.invoke(_generation_context(state), config=config)
        message = chat_model.invoke(prompt_value, config=config)
        return {"state": state, "message": message}

    async def generate_async(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = await prompt.ainvoke(_generation_context(state), config=config)
        message: BaseMessage | None = None
        async for chunk in chat_model.astream(prompt_value, config=config):
            message = chunk if message is None else message + chunk
        if message is None:
            raise ValueError("empty model stream")
        return {"state": state, "message": message}

    generation = (
        RunnableLambda(generate_sync, afunc=generate_async).with_config(
            run_name="policy_generation"
        )
        | RunnableLambda(
            lambda state: _parse_generated(state, provider_name, model_name)
        ).with_config(run_name="fixed_output_parser")
    )
    insufficient = RunnableLambda(
        lambda state: _insufficient(state, provider_name, model_name)
    ).with_config(run_name="insufficient_sources")
    gate = (
        (lambda state: _has_sufficient_reranked_evidence(state, relevance_threshold))
        if reranker is not None
        else _has_documents
    )
    branch = RunnableBranch((gate, generation), insufficient).with_config(
        run_name="evidence_gate"
    )
    return (
        validation
        | retrieval
        | branch
        | RunnableLambda(_validate_result).with_config(run_name="result_validation")
    ).with_config(
        run_name=POLICY_RAG_CHAIN_NAME,
        tags=[f"chain_version:{POLICY_RAG_CHAIN_VERSION}"],
    )


def _chunk_text(chunk: AIMessageChunk | BaseMessage | object) -> str:
    content = getattr(chunk, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            str(part.get("text", "")) if isinstance(part, dict) else str(part)
            for part in content
        )
    return ""


async def astream_policy_events(
    chain: Runnable[PolicyRAGInput, PolicyRAGResult],
    request: PolicyRAGInput,
) -> AsyncIterator[PolicyRAGEvent]:
    sequence = 0
    emitted_stages: set[str] = set()

    async def event(event_type: str, **kwargs: Any) -> PolicyRAGEvent:
        nonlocal sequence
        sequence += 1
        return PolicyRAGEvent(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            sequence=sequence,
            type=event_type,
            **kwargs,
        )

    queue: asyncio.Queue[dict[str, Any] | BaseException | None] = asyncio.Queue()

    async def produce_raw_events() -> None:
        try:
            async for raw in chain.astream_events(request, version="v2"):
                await queue.put(raw)
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            await queue.put(exc)
        finally:
            await queue.put(None)

    producer = asyncio.create_task(produce_raw_events())
    try:
        while True:
            item = await queue.get()
            if item is None:
                break
            if isinstance(item, BaseException):
                raise item
            raw = item
            event_name = str(raw.get("event", ""))
            name = str(raw.get("name", ""))
            stage = ""
            if name == "input_validation" and event_name == "on_chain_start":
                stage = "planning"
            elif (name == "policy_retrieval" and event_name == "on_chain_start") or event_name == "on_retriever_start":
                stage = "retrieving"
            elif name == "policy_reranking" and event_name == "on_retriever_end":
                stage = "reranking"
            elif (name == "policy_generation" and event_name == "on_chain_start") or event_name == "on_chat_model_start":
                stage = "generating"
            if stage and stage not in emitted_stages:
                emitted_stages.add(stage)
                yield await event(stage)

            if event_name == "on_chat_model_stream":
                delta = _chunk_text(raw.get("data", {}).get("chunk"))
                if delta:
                    yield await event("token", delta=delta)

            if name == POLICY_RAG_CHAIN_NAME and event_name == "on_chain_end":
                output = raw.get("data", {}).get("output")
                result = _validate_result(output)
                yield await event("completed", result=result)
                return
        yield await event("failed", error_code="rag_stream_incomplete")
    except asyncio.CancelledError:
        raise
    except Exception:
        yield await event("failed", error_code="rag_chain_failed")
    finally:
        if not producer.done():
            producer.cancel()
        with suppress(asyncio.CancelledError):
            await producer
