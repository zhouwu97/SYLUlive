from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from langchain_core.runnables import RunnableConfig, RunnableSerializable

from app.schemas import PolicyQueryPlan


POLICY_QUERY_PLANNER_VERSION = "policy-domain-rules-v3"


def _load_policy_contract() -> dict[str, object]:
    """加载与 Go 端同步的校园政策查询契约。"""

    candidates = (
        Path(__file__).with_name("policy_query_contract_v0.8.json"),
        Path(__file__).resolve().parents[3]
        / "knowledge-base"
        / "sylu-academic-policy"
        / "v0.8"
        / "policy_query_contract_v0.8.json",
    )
    for path in candidates:
        try:
            contract = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if contract.get("version") == "v0.8" and contract.get("intents"):
            return contract
    raise RuntimeError("policy query contract v0.8 is unavailable")


_POLICY_CONTRACT = _load_policy_contract()
_CONTRACT_ALIASES = tuple(_POLICY_CONTRACT.get("aliases", ()))
_CONTRACT_INTENTS = {
    item["intent"]: item
    for item in _POLICY_CONTRACT.get("intents", ())
    if isinstance(item, dict) and item.get("intent")
}
_CONTRACT_PRIORITY = tuple(_POLICY_CONTRACT.get("intent_priority", ()))
_CONTRACT_DOMAIN_TRIGGERS: Mapping[str, Sequence[str]] = {
    "scholarship_selection": ("奖学金", "奖学金评选", "奖学金评审"),
    "work_study": ("勤工助学", "勤工俭学"),
    "student_loan": ("助学贷款", "生源地贷款", "校园地贷款"),
    "orphan_aid": ("孤儿", "孤儿资助", "孤儿减免"),
    "hardship_aid": (
        "困难认定",
        "家庭经济困难学生",
        "校助学金",
        "临时困难补助",
        "国家助学金",
    ),
}

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

# 将高频校园口语收敛成政策正文用语，确保词法召回和向量召回使用同一语义。
_COLLOQUIAL_REPLACEMENTS: Mapping[str, str] = {
    "转到别的专业": "转专业",
    "换到别的专业": "转专业",
    "换个专业": "转专业",
    "换专业": "转专业",
    "小抄": "考试作弊材料",
    "国奖": "国家奖学金",
    "励志奖": "国家励志奖学金",
    "国助": "国家助学金",
    "贫困生": "家庭经济困难学生",
    "临时补助": "临时困难补助",
    "校内兼职": "勤工助学",
    "计算机专业": "计算机科学与技术专业",
    "计算机系": "计算机科学与技术专业",
    "计科": "计算机科学与技术专业",
}

# 该表由原 Go BuildPolicyQueryPlan 迁移，是领域同义词的唯一生产来源。
_SECOND_EXAM_EXPANSIONS: Sequence[tuple[str, Sequence[str]]] = (
    ("挂科", ("首次考核不合格", "未取得学分")),
    ("没拿到学分", ("首次考核不合格", "未取得相应学分")),
    ("未拿到学分", ("首次考核不合格", "未取得相应学分")),
    ("没取得学分", ("首次考核不合格", "未取得相应学分")),
    ("未取得学分", ("首次考核不合格", "未取得相应学分")),
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
        ("竞赛", "比赛", "奖励成绩", "创新创业学分", "A类一等奖", "奖励后"),
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
        ("学业警告", "退学", "结业", "毕业", "毕业所需学分", "休学"),
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
    (
        ("学位证", "学士学位", "授予学位"),
        "bachelor_degree",
        "school_bachelor_degree_requirement",
        ("学士学位", "学位授予", "学位课程平均学分绩点", "课程不及格"),
    ),
    (
        ("计算机科学与技术", "计算机专业", "通信工程", "电子信息工程", "智能科学与技术"),
        "major_profile",
        "official_major_profile",
        ("专业介绍", "培养目标", "主要课程", "就业方向"),
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
    for colloquial, canonical in _COLLOQUIAL_REPLACEMENTS.items():
        normalized = normalized.replace(colloquial, canonical)
    if not normalized:
        raise ValueError("empty policy question")
    if len(normalized) > 300:
        raise ValueError("policy question exceeds planner limit")
    return normalized


def _append_unique(target: list[str], value: str) -> None:
    value = value.strip()
    if value and value not in target:
        target.append(value)


def _prefer_document_type(target: list[str], document_type: str) -> None:
    """把用户明确点名的政策置顶，同时保留宽问题需要的辅助文档。"""

    if document_type in target:
        target.remove(document_type)
    target.insert(0, document_type)


def _apply_specific_document_focus(
    question: str,
    exact_terms: list[str],
    expanded_terms: list[str],
    preferred_types: list[str],
) -> None:
    """依据用户明确点名的事项缩小首选文档，降低相邻政策串答。"""

    if "国家励志奖学金" in question:
        _prefer_document_type(
            preferred_types, "school_national_inspirational_scholarship_policy"
        )
        _append_unique(exact_terms, "国家励志奖学金")
    elif "国家奖学金" in question or "省政府奖学金" in question:
        _prefer_document_type(preferred_types, "school_national_scholarship_policy")
        _append_unique(exact_terms, "国家（省政府）奖学金")

    if "国家助学金" in question:
        _prefer_document_type(preferred_types, "school_national_grant_policy")
        _append_unique(exact_terms, "国家助学金")
    if "家庭经济困难学生" in question or "困难认定" in question:
        _prefer_document_type(
            preferred_types, "school_financial_hardship_recognition_policy"
        )
    if "临时困难补助" in question or "校助学金" in question:
        _prefer_document_type(
            preferred_types, "school_grant_and_temporary_aid_policy"
        )

    form_context = any(
        term in question for term in ("申请表", "表格", "材料", "汇总表")
    )
    reward_context = any(
        term in question for term in ("竞赛", "比赛", "论文", "专利", "奖励成绩")
    )
    if form_context and reward_context:
        _prefer_document_type(
            preferred_types, "school_competition_grade_reward_forms"
        )
        _append_unique(expanded_terms, "奖励成绩申请表")
        _append_unique(expanded_terms, "证明材料")


def _match_contract_intent(question: str) -> str:
    matched = {
        str(alias.get("intent", ""))
        for alias in _CONTRACT_ALIASES
        if isinstance(alias, dict)
        and str(alias.get("trigger", "")) in question
    }
    for intent in _CONTRACT_PRIORITY:
        if intent in matched:
            return intent
        if any(
            trigger in question
            for trigger in _CONTRACT_DOMAIN_TRIGGERS.get(intent, ())
        ):
            return intent
    return ""


def _apply_contract_intent(
    question: str,
    intent: str,
    exact_terms: list[str],
    expanded_terms: list[str],
    preferred_types: list[str],
) -> bool:
    profile = _CONTRACT_INTENTS.get(intent, {})
    if not profile:
        return False

    exact_terms.clear()
    expanded_terms.clear()
    preferred_types.clear()
    for alias in _CONTRACT_ALIASES:
        if not isinstance(alias, dict) or alias.get("intent") != intent:
            continue
        trigger = str(alias.get("trigger", ""))
        if trigger not in question:
            continue
        _append_unique(exact_terms, trigger)
        for term in alias.get("terms", ()):
            _append_unique(expanded_terms, str(term))
    for term in profile.get("canonical_terms", ()):
        _append_unique(expanded_terms, str(term))
    for document_type in profile.get("preferred_document_types", ()):
        _append_unique(preferred_types, str(document_type))
    return str(profile.get("historical_mode", "none")) in {"fallback", "required"}


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

        contract_intent = _match_contract_intent(question)
        if contract_intent:
            intent = contract_intent
            second_exam = _apply_contract_intent(
                question, intent, exact_terms, expanded_terms, preferred_types
            )

        _apply_specific_document_focus(
            question, exact_terms, expanded_terms, preferred_types
        )

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
