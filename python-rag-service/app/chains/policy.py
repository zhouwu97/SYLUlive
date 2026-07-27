from __future__ import annotations

import asyncio
import json
import re
import unicodedata
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Any

from langchain.retrievers.contextual_compression import ContextualCompressionRetriever
from langchain_core.documents import Document
from langchain_core.documents.compressor import BaseDocumentCompressor
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessageChunk, BaseMessage
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.runnables import (
    Runnable,
    RunnableBranch,
    RunnableConfig,
    RunnableLambda,
    RunnableParallel,
    RunnablePassthrough,
)

from app.chains.query_planner import PolicyQueryPlanner
from app.chains.query_rewriter import (
    bound_policy_history,
    build_policy_query_rewriter,
    history_messages,
)
from app.prompts import build_policy_answer_prompt
from app.schemas import (
    PolicyAnswer,
    PolicyQueryPlan,
    PolicyRAGEvent,
    PolicyRAGInput,
    PolicyRAGResult,
    PolicyRule,
    PolicySource,
    PolicyUsage,
)


POLICY_RAG_CHAIN_NAME = "shenliyuan_policy_rag"
POLICY_RAG_CHAIN_VERSION = "conversation-context-v4"
INSUFFICIENT_ANSWER = "当前已发布资料不足，暂时无法给出可核验回答。"
HISTORY_BOUNDARY_WARNING = "历史规则不代表当前执行口径，请以教务系统或当期通知核验。"
_CALCULATION_TERMS = (
    "平时成绩",
    "补考卷面",
    "比例",
    "合成",
    "折算",
    "绩点",
    "等级为",
    "百分之",
    "%",
)
_RAW_REFERENCE_PATTERN = re.compile(r"\[(?:chunk:|R\d+)", re.IGNORECASE)


class PolicyCitationValidationError(ValueError):
    """结构化答案未通过确定性引用边界校验。"""


def _normalize_input(value: PolicyRAGInput | dict[str, Any]) -> PolicyRAGInput:
    request = value if isinstance(value, PolicyRAGInput) else PolicyRAGInput.model_validate(value)
    normalized = request.question.strip()
    if not normalized:
        raise ValueError("empty policy question")
    return request.model_copy(
        update={"question": normalized, "history": bound_policy_history(request.history)}
    )


def _bounded_documents(state: dict[str, Any]) -> list[Document]:
    request: PolicyRAGInput = state["request"]
    plan: PolicyQueryPlan = state["query_plan"]
    selected: list[Document] = []
    seen_chunks: set[int] = set()
    for document in state["documents"]:
        metadata = document.metadata
        try:
            chunk_id = int(metadata.get("chunk_id", 0))
            document_id = int(metadata.get("document_id", 0))
        except (TypeError, ValueError):
            continue
        if chunk_id <= 0 or document_id <= 0 or chunk_id in seen_chunks:
            continue
        if not plan.allow_historical and bool(metadata.get("historical", False)):
            continue
        seen_chunks.add(chunk_id)
        selected.append(document)
        if len(selected) == request.max_sources:
            break
    return selected


def _reference_map(documents: list[Document]) -> dict[str, Document]:
    return {f"R{index}": document for index, document in enumerate(documents, start=1)}


def _generation_context(state: dict[str, Any], parser: PydanticOutputParser) -> dict[str, Any]:
    request: PolicyRAGInput = state["request"]
    plan: PolicyQueryPlan = state["query_plan"]
    documents = _bounded_documents(state)
    context_parts: list[str] = []
    for reference_id, document in _reference_map(documents).items():
        metadata = document.metadata
        attributes = {
            "reference_id": reference_id,
            "version": "historical" if metadata.get("historical", False) else "current",
            "title": str(metadata.get("title") or "未命名政策资料"),
            "document_type": str(metadata.get("document_type") or ""),
            "effective_from": str(metadata.get("effective_from") or ""),
            "effective_to": str(metadata.get("effective_to") or ""),
            "locator": str(metadata.get("source_locator") or ""),
        }
        context_parts.append(
            f"<evidence metadata='{json.dumps(attributes, ensure_ascii=False)}'>\n"
            f"{document.page_content}\n</evidence>"
        )
    return {
        "history": history_messages(request.history),
        "query_plan": plan.model_dump_json(),
        "context": "\n\n".join(context_parts),
        "format_instructions": parser.get_format_instructions(),
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


def _normalize_evidence_text(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value)).casefold()


def _validate_calculation_claim(statement: str, quotes: list[str]) -> None:
    normalized_statement = _normalize_evidence_text(statement)
    terms = [term for term in _CALCULATION_TERMS if _normalize_evidence_text(term) in normalized_statement]
    if not terms:
        return
    normalized_quotes = _normalize_evidence_text(" ".join(quotes))
    missing = [term for term in terms if _normalize_evidence_text(term) not in normalized_quotes]
    numbers = re.findall(r"(?<![\w.])\d+(?:\.\d+)?%?", normalized_statement)
    missing.extend(number for number in numbers if number not in normalized_quotes)
    if missing:
        raise PolicyCitationValidationError("calculation claim is not present in cited quotes")


def _validate_rule(
    rule: PolicyRule,
    *,
    expected_historical: bool,
    citations: dict[str, str],
    references: dict[str, Document],
) -> None:
    quotes: list[str] = []
    for reference_id in rule.citation_ids:
        document = references.get(reference_id)
        if document is None or reference_id not in citations:
            raise PolicyCitationValidationError("rule uses unavailable citation")
        if bool(document.metadata.get("historical", False)) != expected_historical:
            raise PolicyCitationValidationError("rule crosses current and historical boundary")
        quotes.append(citations[reference_id])
    _validate_calculation_claim(rule.statement, quotes)


def _validate_structured_answer(
    answer: PolicyAnswer,
    *,
    documents: list[Document],
    plan: PolicyQueryPlan,
) -> None:
    references = _reference_map(documents)
    citations = {item.reference_id: item.quote for item in answer.citations}
    if set(citations) - set(references):
        raise PolicyCitationValidationError("model forged a temporary citation")

    for reference_id, quote in citations.items():
        content = _normalize_evidence_text(references[reference_id].page_content)
        if _normalize_evidence_text(quote) not in content:
            raise PolicyCitationValidationError("citation quote is not in source evidence")

    used: set[str] = set()
    for rule in answer.current_rules:
        _validate_rule(
            rule,
            expected_historical=False,
            citations=citations,
            references=references,
        )
        used.update(rule.citation_ids)
    for rule in answer.historical_rules:
        _validate_rule(
            rule,
            expected_historical=True,
            citations=citations,
            references=references,
        )
        used.update(rule.citation_ids)
    if used != set(citations):
        raise PolicyCitationValidationError("declared citations and cited rules differ")

    if not plan.allow_historical and answer.historical_rules:
        raise PolicyCitationValidationError("query plan excludes historical rules")
    if answer.historical_rules:
        warning_text = " ".join(answer.warnings)
        has_boundary = "历史" in warning_text and (
            "不代表当前" in warning_text or "仅供" in warning_text
        )
        has_verification = "教务系统" in warning_text or "当期通知" in warning_text
        if not has_boundary or not has_verification:
            raise PolicyCitationValidationError("historical answer lacks version boundary warning")

    all_text = " ".join(
        [
            answer.answer,
            *(rule.statement for rule in answer.current_rules),
            *(rule.statement for rule in answer.historical_rules),
        ]
    )
    if _RAW_REFERENCE_PATTERN.search(all_text):
        raise PolicyCitationValidationError("answer exposes an internal reference")
    _validate_calculation_claim(answer.answer, list(citations.values()))


def _citation_suffix(reference_ids: list[str]) -> str:
    numbers = sorted({int(reference_id[1:]) for reference_id in reference_ids})
    return "".join(f"[{number}]" for number in numbers)


def _render_structured_answer(answer: PolicyAnswer) -> str:
    sections = [f"{answer.answer} {_citation_suffix([item.reference_id for item in answer.citations])}".strip()]
    if answer.current_rules:
        rules = "\n".join(
            f"- {rule.statement} {_citation_suffix(rule.citation_ids)}" for rule in answer.current_rules
        )
        sections.append(f"### 现行规则\n{rules}")
    if answer.historical_rules:
        rules = "\n".join(
            f"- {rule.statement} {_citation_suffix(rule.citation_ids)}" for rule in answer.historical_rules
        )
        sections.append(f"### 历史规则（不代表当前执行口径）\n{rules}")
    if answer.warnings:
        sections.append("### 核验提示\n" + "\n".join(f"- {warning}" for warning in answer.warnings))
    return "\n\n".join(sections)


def _source_from_document(
    document: Document, *, reference_id: str
) -> PolicySource:
    metadata = document.metadata
    chunk_id = int(metadata.get("chunk_id", 0))
    return PolicySource(
        source_id=reference_id,
        document_id=int(metadata.get("document_id", 0)),
        chunk_id=chunk_id,
        citation_number=int(reference_id[1:]),
        title=str(metadata.get("title") or "未命名政策资料"),
        content=document.page_content,
        document_type=str(metadata.get("document_type") or ""),
        department=str(metadata.get("department") or ""),
        source_url=str(metadata.get("source_url") or ""),
        section_title=str(metadata.get("section_title") or ""),
        source_locator=str(metadata.get("source_locator") or ""),
        historical=bool(metadata.get("historical", False)),
    )


def _parse_generated(state: dict[str, Any], provider_name: str, model_name: str) -> PolicyRAGResult:
    original: dict[str, Any] = state["state"]
    request: PolicyRAGInput = original["request"]
    plan: PolicyQueryPlan = original["query_plan"]
    documents = _bounded_documents(original)
    message: BaseMessage = state["message"]
    structured: PolicyAnswer | None = state["structured"]
    usage = _usage_from_message(message, provider_name, model_name)
    if structured is None:
        return PolicyRAGResult(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            status="citation_rejected",
            answer=INSUFFICIENT_ANSWER,
            warnings=["rag_structured_output_invalid"],
            usage=usage,
            degraded_modes=_degraded_modes(documents),
        )
    try:
        _validate_structured_answer(structured, documents=documents, plan=plan)
    except PolicyCitationValidationError:
        return PolicyRAGResult(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            status="citation_rejected",
            answer=INSUFFICIENT_ANSWER,
            warnings=["rag_citation_validation_failed"],
            usage=usage,
            degraded_modes=_degraded_modes(documents),
        )

    references = _reference_map(documents)
    cited_ids = sorted(
        {item.reference_id for item in structured.citations},
        key=lambda value: int(value[1:]),
    )
    return PolicyRAGResult(
        request_id=request.request_id,
        chain_name=POLICY_RAG_CHAIN_NAME,
        chain_version=POLICY_RAG_CHAIN_VERSION,
        status="completed",
        answer=_render_structured_answer(structured),
        warnings=list(structured.warnings),
        sources=[
            _source_from_document(references[reference_id], reference_id=reference_id)
            for reference_id in cited_ids
        ],
        usage=usage,
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
    return bool(_bounded_documents(state))


def _has_sufficient_reranked_evidence(
    state: dict[str, Any], relevance_threshold: float
) -> bool:
    documents = _bounded_documents(state)
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
    planner: Runnable[str, PolicyQueryPlan] | None = None,
    query_rewriter: Runnable[PolicyRAGInput, str] | None = None,
) -> Runnable[PolicyRAGInput, PolicyRAGResult]:
    if not 0 <= relevance_threshold <= 1:
        raise ValueError("relevance threshold must be between 0 and 1")
    query_planner = planner or PolicyQueryPlanner()
    rewrite_query = query_rewriter or build_policy_query_rewriter()
    validation = RunnableLambda(_normalize_input).with_config(run_name="input_validation")
    rewriting = RunnableParallel(
        request=RunnablePassthrough(),
        rewritten_query=rewrite_query,
    ).with_config(run_name="policy_context_rewrite")
    planning = RunnableParallel(
        request=RunnableLambda(lambda state: state["request"]),
        rewritten_query=RunnableLambda(lambda state: state["rewritten_query"]),
        query_plan=RunnableLambda(lambda state: state["rewritten_query"])
        | query_planner,
    ).with_config(run_name="policy_query_planning")

    document_retriever: Runnable[str, list[Document]] = retriever
    if reranker is not None:
        document_retriever = ContextualCompressionRetriever(
            base_retriever=retriever,
            base_compressor=reranker,
        ).with_config(run_name="policy_reranking")
    retrieval = RunnableParallel(
        request=RunnableLambda(lambda state: state["request"]),
        rewritten_query=RunnableLambda(lambda state: state["rewritten_query"]),
        query_plan=RunnableLambda(lambda state: state["query_plan"]),
        documents=RunnableLambda(lambda state: state["rewritten_query"])
        | document_retriever,
    ).with_config(run_name="policy_retrieval")

    parser = PydanticOutputParser(pydantic_object=PolicyAnswer)
    prompt = build_policy_answer_prompt()

    def generate_sync(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = prompt.invoke(_generation_context(state, parser), config=config)
        message = chat_model.invoke(prompt_value, config=config)
        try:
            structured = parser.invoke(message, config=config)
        except Exception:
            structured = None
        return {"state": state, "message": message, "structured": structured}

    async def generate_async(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = await prompt.ainvoke(_generation_context(state, parser), config=config)
        message: BaseMessage | None = None
        async for chunk in chat_model.astream(prompt_value, config=config):
            message = chunk if message is None else message + chunk
        if message is None:
            raise ValueError("empty model stream")
        try:
            structured = await parser.ainvoke(message, config=config)
        except Exception:
            structured = None
        return {"state": state, "message": message, "structured": structured}

    generation = (
        RunnableLambda(generate_sync, afunc=generate_async).with_config(
            run_name="policy_generation"
        )
        | RunnableLambda(
            lambda state: _parse_generated(state, provider_name, model_name)
        ).with_config(run_name="citation_validation")
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
        | rewriting
        | planning
        | retrieval
        | branch
        | RunnableLambda(_validate_result).with_config(run_name="result_validation")
    ).with_config(
        run_name=POLICY_RAG_CHAIN_NAME,
        tags=[f"chain_version:{POLICY_RAG_CHAIN_VERSION}"],
    )


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
            if name in {"input_validation", "policy_query_planning"} and event_name == "on_chain_start":
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

            if name == POLICY_RAG_CHAIN_NAME and event_name == "on_chain_end":
                output = raw.get("data", {}).get("output")
                result = _validate_result(output)
                # 模型原始 JSON 不对外流式发送；只有完成结构化及引用校验后才发布答案。
                yield await event("token", delta=result.answer)
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
