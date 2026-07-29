from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


POLICY_RAG_SCHEMA_VERSION = "1.2"


class StrictSchema(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PolicyHistoryMessage(StrictSchema):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=2_000)


class PolicyRAGInput(StrictSchema):
    request_id: str = Field(min_length=1, max_length=100)
    question: str = Field(min_length=1, max_length=300)
    history: list[PolicyHistoryMessage] = Field(default_factory=list, max_length=8)
    max_sources: int = Field(default=6, ge=1, le=10)


class PolicyRule(StrictSchema):
    statement: str = Field(min_length=1, max_length=500)
    citation_ids: list[str] = Field(min_length=1, max_length=5)


class PolicyCitation(StrictSchema):
    reference_id: str = Field(pattern=r"^R[1-9][0-9]?$", max_length=3)
    quote: str = Field(min_length=4, max_length=240)


class PolicyAnswer(StrictSchema):
    """模型的结构化输出；引用仍是单次请求内的临时编号。"""

    answer: str = Field(min_length=1, max_length=800)
    current_rules: list[PolicyRule] = Field(default_factory=list, max_length=3)
    historical_rules: list[PolicyRule] = Field(default_factory=list, max_length=2)
    warnings: list[str] = Field(default_factory=list, max_length=5)
    citations: list[PolicyCitation] = Field(min_length=1, max_length=3)
    confidence: Literal["low", "medium", "high"]

    @model_validator(mode="after")
    def validate_reference_graph(self) -> "PolicyAnswer":
        citation_ids = [item.reference_id for item in self.citations]
        declared = set(citation_ids)
        used = {
            citation_id
            for rule in (*self.current_rules, *self.historical_rules)
            for citation_id in rule.citation_ids
        }
        if not used.issubset(declared):
            raise ValueError("rule contains undeclared temporary citation")
        return self


class PolicySource(StrictSchema):
    source_id: str = Field(min_length=1, max_length=100)
    document_id: int = Field(gt=0)
    chunk_id: int = Field(gt=0)
    citation_number: int = Field(gt=0, le=99)
    title: str = Field(min_length=1, max_length=300)
    content: str = Field(default="", max_length=8_000)
    document_type: str = Field(default="", max_length=100)
    department: str = Field(default="", max_length=200)
    source_url: str = Field(default="", max_length=2_000)
    section_title: str = Field(default="", max_length=300)
    source_locator: str = Field(default="", max_length=500)
    historical: bool = False


class PolicyUsage(StrictSchema):
    provider: str = Field(min_length=1, max_length=64)
    model: str = Field(min_length=1, max_length=200)
    input_tokens: int = Field(ge=0)
    output_tokens: int = Field(ge=0)
    cache_hit_tokens: int = Field(default=0, ge=0)
    metered: bool


class PolicyRAGResult(StrictSchema):
    request_id: str = Field(min_length=1, max_length=100)
    schema_version: Literal[POLICY_RAG_SCHEMA_VERSION] = POLICY_RAG_SCHEMA_VERSION
    chain_name: str = Field(min_length=1, max_length=100)
    chain_version: str = Field(min_length=1, max_length=100)
    status: Literal[
        "completed",
        "general_completed",
        "insufficient_sources",
        "citation_rejected",
    ]
    answer_mode: Literal["verified_campus", "general_answer", "guided_gap"] = (
        "verified_campus"
    )
    answer: str = Field(min_length=1, max_length=32_000)
    warnings: list[str] = Field(default_factory=list, max_length=20)
    sources: list[PolicySource] = Field(default_factory=list, max_length=10)
    usage: PolicyUsage
    degraded_modes: list[str] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def validate_metering(self) -> "PolicyRAGResult":
        if self.status in {"completed", "general_completed", "citation_rejected"}:
            if not self.usage.metered:
                raise ValueError("generated result must contain metered usage")
            if self.usage.input_tokens + self.usage.output_tokens <= 0:
                raise ValueError("generated result must contain non-zero usage")
            if self.status == "citation_rejected" and self.sources:
                raise ValueError("citation rejected result must not contain sources")
            if self.status == "general_completed" and self.sources:
                raise ValueError("general result must not contain sources")
        elif self.sources:
            raise ValueError("insufficient result must not contain sources")
        return self


class PolicyRAGEvent(StrictSchema):
    request_id: str = Field(min_length=1, max_length=100)
    schema_version: Literal[POLICY_RAG_SCHEMA_VERSION] = POLICY_RAG_SCHEMA_VERSION
    chain_name: str = Field(min_length=1, max_length=100)
    chain_version: str = Field(min_length=1, max_length=100)
    sequence: int = Field(gt=0)
    type: Literal[
        "planning",
        "retrieving",
        "reranking",
        "generating",
        "token",
        "completed",
        "failed",
    ]
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    delta: str = Field(default="", max_length=8_000)
    result: PolicyRAGResult | None = None
    error_code: str = Field(default="", max_length=100)

    @model_validator(mode="after")
    def validate_payload(self) -> "PolicyRAGEvent":
        if self.type == "completed" and self.result is None:
            raise ValueError("completed event requires result")
        if self.type == "failed" and not self.error_code:
            raise ValueError("failed event requires error_code")
        if self.type != "token" and self.delta:
            raise ValueError("only token events may contain delta")
        return self
