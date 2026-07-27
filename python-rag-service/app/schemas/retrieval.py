from __future__ import annotations

from typing import Literal

from pydantic import Field, model_validator

from app.schemas.policy import StrictSchema


POLICY_QUERY_PLAN_SCHEMA_VERSION = "1.0"


class PolicyQueryPlan(StrictSchema):
    """政策查询的确定性规划结果，同时作为 Go 旧链路的内部兼容契约。"""

    schema_version: Literal[POLICY_QUERY_PLAN_SCHEMA_VERSION] = (
        POLICY_QUERY_PLAN_SCHEMA_VERSION
    )
    planner_name: Literal["policy_query_planner"] = "policy_query_planner"
    planner_version: str = Field(min_length=1, max_length=100)
    intent: str = Field(min_length=1, max_length=100)
    normalized_question: str = Field(min_length=1, max_length=300)
    exact_terms: list[str] = Field(default_factory=list, max_length=32)
    expanded_terms: list[str] = Field(default_factory=list, max_length=32)
    preferred_document_types: list[str] = Field(default_factory=list, max_length=16)
    history_policy: Literal["exclude", "include_when_required"] = "exclude"
    version_boundary: Literal["current_only", "current_preferred_with_history"] = (
        "current_only"
    )
    allow_historical: bool = False

    @model_validator(mode="after")
    def validate_history_boundary(self) -> "PolicyQueryPlan":
        expected = self.history_policy == "include_when_required"
        if self.allow_historical != expected:
            raise ValueError("history policy and allow_historical are inconsistent")
        if expected != (self.version_boundary == "current_preferred_with_history"):
            raise ValueError("history policy and version boundary are inconsistent")
        return self

    @property
    def retrieval_query(self) -> str:
        values = [self.normalized_question, *self.exact_terms, *self.expanded_terms]
        return " ".join(
            dict.fromkeys(value.strip() for value in values if value.strip())
        )

    def audit_summary(self) -> dict[str, object]:
        """审计摘要不包含原始或规范化问题，避免把用户输入写入事件。"""

        return {
            "planner_name": self.planner_name,
            "planner_version": self.planner_version,
            "intent": self.intent,
            "exact_term_count": len(self.exact_terms),
            "expanded_term_count": len(self.expanded_terms),
            "preferred_document_types": list(self.preferred_document_types),
            "history_policy": self.history_policy,
            "version_boundary": self.version_boundary,
        }
