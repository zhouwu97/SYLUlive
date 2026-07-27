from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


POLICY_RAG_SCHEMA_VERSION = "1.0"


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


class PolicySource(StrictSchema):
    source_id: str = Field(min_length=1, max_length=100)
    document_id: int = Field(gt=0)
    chunk_id: int = Field(gt=0)
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
    status: Literal["completed", "insufficient_sources"]
    answer: str = Field(min_length=1, max_length=32_000)
    warnings: list[str] = Field(default_factory=list, max_length=20)
    sources: list[PolicySource] = Field(default_factory=list, max_length=10)
    usage: PolicyUsage
    degraded_modes: list[str] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def validate_metering(self) -> "PolicyRAGResult":
        if self.status == "completed":
            if not self.usage.metered:
                raise ValueError("completed result must contain metered usage")
            if self.usage.input_tokens + self.usage.output_tokens <= 0:
                raise ValueError("completed result must contain non-zero usage")
        elif self.sources:
            raise ValueError("insufficient result must not contain sources")
        return self


class PolicyRAGEvent(StrictSchema):
    request_id: str = Field(min_length=1, max_length=100)
    schema_version: Literal[POLICY_RAG_SCHEMA_VERSION] = POLICY_RAG_SCHEMA_VERSION
    chain_name: str = Field(min_length=1, max_length=100)
    chain_version: str = Field(min_length=1, max_length=100)
    sequence: int = Field(gt=0)
    type: Literal["planning", "retrieving", "generating", "token", "completed", "failed"]
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
