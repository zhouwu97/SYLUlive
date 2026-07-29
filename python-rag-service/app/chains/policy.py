from __future__ import annotations

import asyncio
import json
import logging
import re
import unicodedata
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Any

from langchain.retrievers.contextual_compression import ContextualCompressionRetriever
from langchain_core.documents import Document
from langchain_core.documents.compressor import BaseDocumentCompressor
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessageChunk, BaseMessage, HumanMessage
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.runnables import (
    Runnable,
    RunnableBranch,
    RunnableConfig,
    RunnableLambda,
    RunnableParallel,
    RunnablePassthrough,
)
from pydantic import ValidationError

from app.chains.query_planner import PolicyQueryPlanner
from app.chains.query_rewriter import (
    bound_policy_history,
    build_policy_query_rewriter,
    history_messages,
)
from app.prompts import build_campus_fallback_prompt, build_policy_answer_prompt
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
POLICY_RAG_CHAIN_VERSION = "campus-assistant-release-v8"
VERIFIED_GENERATION_ATTEMPTS = 2
GUIDED_GAP_ANSWER = (
    "我暂时无法从已发布的校园资料中核验这项具体信息。"
    "你可以补充涉及的校区、课程或办理事项，我会继续帮你缩小查询范围；"
    "也可以查看对应事项的当期通知，或向负责该事项的学院老师确认。"
)
INSUFFICIENT_ANSWER = GUIDED_GAP_ANSWER
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
_WARNING_BOUNDARY_MARKERS = (
    "为准",
    "核验",
    "未说明",
    "未给出",
    "无法确认",
    "当期通知",
    "教务系统",
)
_UNTRUSTED_KNOWLEDGE_INSTRUCTION_PATTERN = re.compile(
    r"(?:ignore\s+(?:all\s+)?(?:previous|prior)\s+instructions?"
    r"|system\s*prompt|developer\s*message|assistant\s*:"
    r"|忽略(?:以上|此前|之前|所有)?(?:系统|开发者|提示词|指令)"
    r"|覆盖(?:系统|开发者)(?:提示词|指令)"
    r"|输出(?:系统提示词|内部令牌|密钥|api\s*key|jwt))",
    re.IGNORECASE,
)
logger = logging.getLogger(__name__)
_SAFE_SCHEMA_VALIDATION_REASONS = {
    "rule contains undeclared temporary citation",
}


class PolicyCitationValidationError(ValueError):
    """结构化答案未通过确定性引用边界校验。"""


def _parser_failure_reason(error: Exception) -> str:
    """只提取字段和错误类型，不把模型原文或证据写回重试提示与日志。"""

    current: BaseException | None = error
    while current is not None:
        if isinstance(current, ValidationError):
            failures: list[str] = []
            for item in current.errors(include_input=False, include_url=False)[:6]:
                location = ".".join(str(part) for part in item.get("loc", ()))
                error_type = str(item.get("type") or "invalid")
                detail = str((item.get("ctx") or {}).get("error") or "")
                if detail in _SAFE_SCHEMA_VALIDATION_REASONS:
                    error_type = detail
                failures.append(f"{location or 'root'}({error_type})")
            if failures:
                return "字段校验失败：" + "、".join(failures)
        current = current.__cause__ or current.__context__
    return "JSON 对象语法不完整或字段不符合 Schema"


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
    preferred_order = {
        document_type: index
        for index, document_type in enumerate(plan.preferred_document_types)
    }
    ranked_documents = sorted(
        enumerate(state["documents"]),
        key=lambda item: (
            0
            if str(item[1].metadata.get("document_type") or "") in preferred_order
            else 1,
            preferred_order.get(
                str(item[1].metadata.get("document_type") or ""),
                len(preferred_order),
            ),
            item[0],
        ),
    )
    for _, document in ranked_documents:
        # 知识正文是非可信输入；明显伪装成系统或开发者指令的块不能进入 Prompt。
        if _UNTRUSTED_KNOWLEDGE_INSTRUCTION_PATTERN.search(document.page_content):
            continue
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


def _citation_quote_is_supported(quote: str, evidence: str) -> bool:
    """接受连续原文，或同一来源内由多个原文片段拼接成的摘录。"""

    normalized_evidence = _normalize_evidence_text(evidence)
    normalized_quote = _normalize_evidence_text(quote)
    if normalized_quote in normalized_evidence:
        return True

    fragments = [
        _normalize_evidence_text(fragment)
        for fragment in re.split(r"[\n。！？!?；;：:]+", quote)
        if fragment.strip()
    ]
    # 片段式摘录至少需要两段，每段都必须逐字存在于同一来源。
    return len(fragments) >= 2 and all(
        len(fragment) >= 4 and fragment in normalized_evidence
        for fragment in fragments
    )


def _usage_from_messages(
    messages: list[BaseMessage],
    provider_name: str,
    model_name: str,
) -> PolicyUsage:
    usages = [
        _usage_from_message(message, provider_name, model_name)
        for message in messages
    ]
    return PolicyUsage(
        provider=provider_name,
        model=model_name,
        input_tokens=sum(item.input_tokens for item in usages),
        output_tokens=sum(item.output_tokens for item in usages),
        cache_hit_tokens=sum(item.cache_hit_tokens for item in usages),
        metered=any(item.metered for item in usages),
    )


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
        missing_summary = "、".join(dict.fromkeys(missing[:6]))
        raise PolicyCitationValidationError(
            f"calculation claim lacks cited evidence for: {missing_summary}"
        )


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
    citation_fragments: dict[str, list[str]] = {}
    for item in answer.citations:
        reference_id = item.reference_id
        quote = item.quote
        if reference_id not in references:
            raise PolicyCitationValidationError("model forged a temporary citation")
        if not _citation_quote_is_supported(
            quote,
            references[reference_id].page_content,
        ):
            raise PolicyCitationValidationError("citation quote is not in source evidence")
        citation_fragments.setdefault(reference_id, []).append(quote)
    # 同一来源可为不同规则给出多个逐字摘录；校验后合并供计算类断言复用。
    citations = {
        reference_id: "；".join(dict.fromkeys(quotes))
        for reference_id, quotes in citation_fragments.items()
    }

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
    if not used and any(
        bool(references[reference_id].metadata.get("historical", False))
        for reference_id in citations
    ):
        raise PolicyCitationValidationError(
            "historical evidence requires an explicitly cited historical rule"
        )
    if used and used != set(citations):
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


def _bounded_warnings(warnings: list[str]) -> list[str]:
    """警告区只保留核验或版本边界，不允许借此夹带旁支政策事实。"""

    return [
        warning
        for warning in warnings
        if any(marker in warning for marker in _WARNING_BOUNDARY_MARKERS)
    ]


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


def _failed_course_extractive_result(
    *,
    request: PolicyRAGInput,
    plan: PolicyQueryPlan,
    documents: list[Document],
    usage: PolicyUsage,
) -> PolicyRAGResult | None:
    """宽泛挂科问法使用两份现行原文兜底，避免模型擅自扩展成绩计算。"""

    if plan.intent not in {"failed_course_flow", "second_exam_and_retake"}:
        return None
    if any(
        term in plan.normalized_question
        for term in ("成绩怎么算", "比例", "绩点", "等级", "公式", "多少分")
    ):
        return None

    references = _reference_map(documents)
    status_item = next(
        (
            (reference_id, document)
            for reference_id, document in references.items()
            if _normalize_evidence_text(
                "课程考核成绩不合格者，需参加由学校组织的二次考试或重新学习"
            )
            in _normalize_evidence_text(document.page_content)
        ),
        None,
    )
    retake_item = next(
        (
            (reference_id, document)
            for reference_id, document in references.items()
            if _normalize_evidence_text("课程成绩不合格未取得相应学分者")
            in _normalize_evidence_text(document.page_content)
        ),
        None,
    )
    if status_item is None or retake_item is None:
        return None

    status_reference, status_document = status_item
    retake_reference, retake_document = retake_item
    cited = sorted(
        {status_reference, retake_reference},
        key=lambda value: int(value[1:]),
    )
    citations = _citation_suffix(cited)
    answer = (
        "挂科后先关注学校组织的二次考试或重新学习安排；"
        "课程成绩不合格且未取得相应学分时，可以参加相应课程重修。"
        f"具体考试、报名和缴费时间以教务系统或当期通知为准。 {citations}"
    )
    return PolicyRAGResult(
        request_id=request.request_id,
        chain_name=POLICY_RAG_CHAIN_NAME,
        chain_version=POLICY_RAG_CHAIN_VERSION,
        status="completed",
        answer=answer,
        answer_mode="verified_campus",
        warnings=["具体二次考试、重修报名和缴费时间以教务系统或当期通知为准。"],
        sources=[
            _source_from_document(
                references[reference_id],
                reference_id=reference_id,
            )
            for reference_id in cited
        ],
        usage=usage,
        degraded_modes=_degraded_modes(documents),
    )


def _parse_generated(state: dict[str, Any], provider_name: str, model_name: str) -> PolicyRAGResult:
    original: dict[str, Any] = state["state"]
    request: PolicyRAGInput = original["request"]
    plan: PolicyQueryPlan = original["query_plan"]
    documents = _bounded_documents(original)
    message: BaseMessage = state["message"]
    messages: list[BaseMessage] = state.get("messages") or [message]
    structured: PolicyAnswer | None = state["structured"]
    usage = _usage_from_messages(messages, provider_name, model_name)
    extractive_documents = _bounded_documents(
        {
            **original,
            "request": request.model_copy(update={"max_sources": 10}),
        }
    )
    if structured is None:
        extractive = _failed_course_extractive_result(
            request=request,
            plan=plan,
            documents=extractive_documents,
            usage=usage,
        )
        if extractive is not None:
            return extractive
        return PolicyRAGResult(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            status="citation_rejected",
            answer=INSUFFICIENT_ANSWER,
            answer_mode="guided_gap",
            warnings=["rag_structured_output_invalid"],
            usage=usage,
            degraded_modes=_degraded_modes(documents),
        )
    try:
        _validate_structured_answer(structured, documents=documents, plan=plan)
    except PolicyCitationValidationError:
        extractive = _failed_course_extractive_result(
            request=request,
            plan=plan,
            documents=extractive_documents,
            usage=usage,
        )
        if extractive is not None:
            return extractive
        return PolicyRAGResult(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            status="citation_rejected",
            answer=INSUFFICIENT_ANSWER,
            answer_mode="guided_gap",
            warnings=["rag_citation_validation_failed"],
            usage=usage,
            degraded_modes=_degraded_modes(documents),
        )

    structured = structured.model_copy(
        update={"warnings": _bounded_warnings(structured.warnings)}
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
        answer_mode="verified_campus",
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
        answer=GUIDED_GAP_ANSWER,
        answer_mode="guided_gap",
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


_CAMPUS_SPECIFIC_TERMS = (
    "沈理",
    "学校",
    "校内",
    "校园",
    "教务",
    "学院",
    "辅导员",
    "学生处",
    "宿舍",
    "食堂",
    "补考",
    "二考",
    "重修",
    "奖学金",
    "助学金",
    "转专业",
    "请假",
    "门禁",
)


def _fallback_answer_mode(state: dict[str, Any]) -> str:
    request: PolicyRAGInput = state["request"]
    plan: PolicyQueryPlan = state["query_plan"]
    if plan.intent != "general_policy" or any(
        term in request.question for term in _CAMPUS_SPECIFIC_TERMS
    ):
        return "guided_gap"
    return "general_answer"


def _fallback_prompt_input(state: dict[str, Any]) -> dict[str, Any]:
    request: PolicyRAGInput = state["request"]
    answer_mode = _fallback_answer_mode(state)
    hint = (
        "这是缺少校内依据的校园事项。不要猜测校内结论，要给出具体核验或下一步引导。"
        if answer_mode == "guided_gap"
        else "这是不依赖校内专属资料的通用问题。请直接自然回答。"
    )
    return {
        "question": request.question,
        "history": history_messages(request.history),
        "answer_mode_hint": hint,
    }


def _parse_fallback_generated(
    state: dict[str, Any], provider_name: str, model_name: str
) -> PolicyRAGResult:
    original: dict[str, Any] = state["state"]
    request: PolicyRAGInput = original["request"]
    message: BaseMessage = state["message"]
    usage = _usage_from_message(message, provider_name, model_name)
    answer = _message_text(message)
    if not answer or _RAW_REFERENCE_PATTERN.search(answer):
        return PolicyRAGResult(
            request_id=request.request_id,
            chain_name=POLICY_RAG_CHAIN_NAME,
            chain_version=POLICY_RAG_CHAIN_VERSION,
            status="citation_rejected",
            answer=GUIDED_GAP_ANSWER,
            answer_mode="guided_gap",
            warnings=["general_answer_validation_failed"],
            usage=usage,
            degraded_modes=_degraded_modes(original.get("documents", [])),
        )
    return PolicyRAGResult(
        request_id=request.request_id,
        chain_name=POLICY_RAG_CHAIN_NAME,
        chain_version=POLICY_RAG_CHAIN_VERSION,
        status="general_completed",
        answer=answer,
        answer_mode=_fallback_answer_mode(original),
        warnings=["campus_sources_unavailable"],
        usage=usage,
        degraded_modes=_degraded_modes(original.get("documents", [])),
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


def _should_generate_verified_answer(
    state: dict[str, Any], relevance_threshold: float, reranker_enabled: bool
) -> bool:
    # 通用问题不能因为向量检索偶然召回弱相关材料而退化为政策回答。
    if _fallback_answer_mode(state) != "guided_gap":
        return False
    if reranker_enabled:
        return _has_sufficient_reranked_evidence(state, relevance_threshold)
    return _has_documents(state)


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
    fallback_prompt = build_campus_fallback_prompt()

    def generation_failure(
        structured: PolicyAnswer | None,
        state: dict[str, Any],
    ) -> str:
        if structured is None:
            return "上一次输出不是符合 Schema 的单个 JSON 对象"
        try:
            _validate_structured_answer(
                structured,
                documents=_bounded_documents(state),
                plan=state["query_plan"],
            )
        except PolicyCitationValidationError as error:
            reason = str(error)
            logger.warning("policy citation validation failed: %s", reason)
            return f"上一次输出的引用校验失败：{reason}"
        return ""

    def retry_messages(prompt_value: Any, failure: str) -> list[BaseMessage]:
        return [
            *prompt_value.to_messages(),
            HumanMessage(
                content=(
                    f"{failure}。请重新生成一次完整答案。"
                    "必须只输出符合既定 Schema 的 JSON；"
                    "简要回答不超过 300 个中文字符，只保留最多 3 条现行规则和 3 个引用；"
                    "每个 quote 不超过 160 个中文字符，"
                    "每个 citation quote 必须直接复制同一 evidence 中的一段连续原文，"
                    "不得改写、概括、跨句拼接或跨来源拼接；"
                    "答案或规则中的数字、比例、绩点、等级必须在其引用 quote 中原样出现，"
                    "否则删去该断言；用户没有询问成绩计算时，"
                    "不得主动回答比例合成、绩点、等级或计算公式。"
                )
            ),
        ]

    def generate_sync(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = prompt.invoke(_generation_context(state, parser), config=config)
        generated_messages: list[BaseMessage] = []
        message: BaseMessage | None = None
        structured: PolicyAnswer | None = None
        failure = ""
        for attempt in range(VERIFIED_GENERATION_ATTEMPTS):
            model_input = (
                prompt_value
                if attempt == 0
                else retry_messages(prompt_value, failure)
            )
            message = chat_model.invoke(model_input, config=config)
            generated_messages.append(message)
            try:
                structured = parser.invoke(message, config=config)
                parse_failure = ""
            except Exception as error:
                structured = None
                parse_failure = _parser_failure_reason(error)
                logger.warning(
                    "policy structured output parse failed on attempt %d: %s",
                    attempt + 1,
                    parse_failure,
                )
            failure = (
                parse_failure
                if structured is None
                else generation_failure(structured, state)
            )
            if not failure:
                break
        if message is None:
            raise ValueError("empty model response")
        return {
            "state": state,
            "message": message,
            "messages": generated_messages,
            "structured": structured,
        }

    async def generate_async(state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt_value = await prompt.ainvoke(_generation_context(state, parser), config=config)
        generated_messages: list[BaseMessage] = []
        message: BaseMessage | None = None
        structured: PolicyAnswer | None = None
        failure = ""
        for attempt in range(VERIFIED_GENERATION_ATTEMPTS):
            model_input = (
                prompt_value
                if attempt == 0
                else retry_messages(prompt_value, failure)
            )
            message = None
            async for chunk in chat_model.astream(model_input, config=config):
                message = chunk if message is None else message + chunk
            if message is None:
                raise ValueError("empty model stream")
            generated_messages.append(message)
            try:
                structured = await parser.ainvoke(message, config=config)
                parse_failure = ""
            except Exception as error:
                structured = None
                parse_failure = _parser_failure_reason(error)
                logger.warning(
                    "policy structured output parse failed on attempt %d: %s",
                    attempt + 1,
                    parse_failure,
                )
            failure = (
                parse_failure
                if structured is None
                else generation_failure(structured, state)
            )
            if not failure:
                break
        if message is None:
            raise ValueError("empty model stream")
        return {
            "state": state,
            "message": message,
            "messages": generated_messages,
            "structured": structured,
        }

    generation = (
        RunnableLambda(generate_sync, afunc=generate_async).with_config(
            run_name="policy_generation"
        )
        | RunnableLambda(
            lambda state: _parse_generated(state, provider_name, model_name)
        ).with_config(run_name="citation_validation")
    )

    def generate_fallback_sync(
        state: dict[str, Any], config: RunnableConfig
    ) -> dict[str, Any]:
        prompt_value = fallback_prompt.invoke(_fallback_prompt_input(state), config=config)
        message = chat_model.invoke(prompt_value, config=config)
        return {"state": state, "message": message}

    async def generate_fallback_async(
        state: dict[str, Any], config: RunnableConfig
    ) -> dict[str, Any]:
        prompt_value = await fallback_prompt.ainvoke(
            _fallback_prompt_input(state), config=config
        )
        message: BaseMessage | None = None
        async for chunk in chat_model.astream(prompt_value, config=config):
            message = chunk if message is None else message + chunk
        if message is None:
            raise ValueError("empty fallback model stream")
        return {"state": state, "message": message}

    fallback_generation = (
        RunnableLambda(generate_fallback_sync, afunc=generate_fallback_async).with_config(
            run_name="campus_fallback_generation"
        )
        | RunnableLambda(
            lambda state: _parse_fallback_generated(
                state, provider_name, model_name
            )
        ).with_config(run_name="general_answer_validation")
    )
    gate = lambda state: _should_generate_verified_answer(
        state, relevance_threshold, reranker is not None
    )
    branch = RunnableBranch((gate, generation), fallback_generation).with_config(
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
    config: RunnableConfig | None = None,
) -> AsyncIterator[PolicyRAGEvent]:
    sequence = 0
    emitted_stages: set[str] = set()
    reranker_wrapper_started = False

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
            async for raw in chain.astream_events(
                request, config=config, version="v2"
            ):
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
            if name == "policy_reranking" and event_name == "on_retriever_start":
                reranker_wrapper_started = True
            if name in {"input_validation", "policy_query_planning"} and event_name == "on_chain_start":
                stage = "planning"
            elif (name == "policy_retrieval" and event_name == "on_chain_start") or event_name == "on_retriever_start":
                stage = "retrieving"
            elif (
                reranker_wrapper_started
                and name != "policy_reranking"
                and event_name == "on_retriever_end"
            ):
                # ContextualCompressionRetriever 在基础召回结束后立即执行压缩器；
                # 此处是 retrieval 与 rerank 可观测且不重叠的边界。
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
