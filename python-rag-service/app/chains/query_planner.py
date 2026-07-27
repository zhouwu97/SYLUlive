from __future__ import annotations

import re
import unicodedata
from collections.abc import Mapping, Sequence
from typing import Any

from langchain_core.runnables import RunnableConfig, RunnableSerializable

from app.schemas import PolicyQueryPlan


POLICY_QUERY_PLANNER_VERSION = "policy-domain-rules-v1"

_TYPO_REPLACEMENTS: Mapping[str, str] = {
    "补烤": "补考",
    "怎摸": "怎么",
    "重休": "重修",
    "几们": "几门",
    "转专页": "转专业",
    "手几": "手机",
    "闭倦": "闭卷",
    "结液": "结业",
}

# 该表由原 Go BuildPolicyQueryPlan 迁移，是领域同义词的唯一生产来源。
_SECOND_EXAM_EXPANSIONS: Sequence[tuple[str, Sequence[str]]] = (
    ("挂科", ("首次考核不合格", "未取得学分")),
    ("补考", ("二次考试", "二考")),
    ("开学补考", ("开学初", "二次考试")),
    ("补考绩点", ("二考成绩", "等级为D或F", "绩点为1或0")),
    ("补考没过", ("二考未取得学分", "重修")),
    ("补考未过", ("二考未取得学分", "重修")),
    ("刷分", ("成绩合格", "继续修读", "提升成绩", "重修")),
    ("二次考试", ("补考", "二考")),
    ("二考", ("二次考试", "补考")),
    ("重修", ("重新学习", "课程重修")),
)

_DOMAIN_DOCUMENT_RULES: Sequence[tuple[Sequence[str], str, str, Sequence[str]]] = (
    (
        ("竞赛", "奖励成绩", "创新创业学分", "A类一等奖", "奖励后"),
        "competition_grade_reward",
        "school_competition_course_grade_reward_policy",
        ("课外活动奖励", "成绩奖励"),
    ),
    (
        ("转专业", "递补", "前20%"),
        "major_transfer",
        "school_undergraduate_major_transfer_policy",
        ("学业优秀类", "转专业"),
    ),
    (
        ("手机", "闭卷", "作弊", "考场", "通信设备"),
        "exam_misconduct",
        "school_exam_misconduct_policy",
        ("考试违纪", "考试作弊"),
    ),
    (
        ("学业警告", "退学", "结业", "毕业所需学分", "休学"),
        "student_status",
        "school_undergraduate_status_policy",
        ("学籍管理",),
    ),
    (
        ("重修", "刷分", "提高成绩", "提升成绩", "最多几门"),
        "retake",
        "school_undergraduate_retake_policy",
        ("课程重修",),
    ),
)

_SECOND_EXAM_DOCUMENT_TYPES = (
    "school_policy_reasoning_card",
    "school_undergraduate_retake_policy",
    "school_undergraduate_status_policy",
    "historical_school_second_exam_policy",
)


def _normalize_question(question: str) -> str:
    normalized = unicodedata.normalize("NFKC", question).strip()
    normalized = re.sub(r"\s+", " ", normalized)
    for typo, corrected in _TYPO_REPLACEMENTS.items():
        normalized = normalized.replace(typo, corrected)
    if not normalized:
        raise ValueError("empty policy question")
    if len(normalized) > 300:
        raise ValueError("policy question exceeds planner limit")
    return normalized


def _append_unique(target: list[str], value: str) -> None:
    value = value.strip()
    if value and value not in target:
        target.append(value)


class PolicyQueryPlanner(RunnableSerializable[str, PolicyQueryPlan]):
    """把学生口语映射为可复现、可审计的政策查询计划。"""

    name: str = "policy_query_planner"

    def invoke(
        self,
        input: str,
        config: RunnableConfig | None = None,
        **kwargs: Any,
    ) -> PolicyQueryPlan:
        return self._call_with_config(
            self._plan,
            input,
            config,
            run_type="chain",
            **kwargs,
        )

    def _plan(self, input: str) -> PolicyQueryPlan:
        question = _normalize_question(input)
        exact_terms: list[str] = []
        expanded_terms: list[str] = []
        preferred_types: list[str] = []
        intent = "general_policy"
        second_exam = False

        for trigger, terms in _SECOND_EXAM_EXPANSIONS:
            if trigger not in question:
                continue
            second_exam = True
            intent = "second_exam_and_retake"
            _append_unique(exact_terms, trigger)
            for term in terms:
                _append_unique(expanded_terms, term)

        if "补考" in question and any(
            term in question for term in ("成绩", "绩点", "怎么算", "多少绩点")
        ):
            second_exam = True
            intent = "second_exam_grade"
            for term in ("二考成绩", "及格 不及格", "等级为D或F", "绩点为1或0"):
                _append_unique(exact_terms, term)

        for triggers, rule_intent, document_type, terms in _DOMAIN_DOCUMENT_RULES:
            matched = [trigger for trigger in triggers if trigger in question]
            if not matched:
                continue
            if not second_exam:
                intent = rule_intent
            _append_unique(preferred_types, document_type)
            for trigger in matched:
                _append_unique(exact_terms, trigger)
            for term in terms:
                _append_unique(expanded_terms, term)

        if second_exam:
            for document_type in reversed(_SECOND_EXAM_DOCUMENT_TYPES):
                if document_type in preferred_types:
                    preferred_types.remove(document_type)
                preferred_types.insert(0, document_type)
            for term in ("首次考核不合格", "二次考试", "二考", "重修"):
                _append_unique(expanded_terms, term)

        return PolicyQueryPlan(
            planner_version=POLICY_QUERY_PLANNER_VERSION,
            intent=intent,
            normalized_question=question,
            exact_terms=exact_terms,
            expanded_terms=expanded_terms,
            preferred_document_types=preferred_types,
            history_policy="include_when_required" if second_exam else "exclude",
            version_boundary=(
                "current_preferred_with_history" if second_exam else "current_only"
            ),
            allow_historical=second_exam,
        )

    async def ainvoke(
        self,
        input: str,
        config: RunnableConfig | None = None,
        **kwargs: Any,
    ) -> PolicyQueryPlan:
        return await self._acall_with_config(
            self._aplan,
            input,
            config,
            run_type="chain",
            **kwargs,
        )

    async def _aplan(self, input: str) -> PolicyQueryPlan:
        return self._plan(input)
