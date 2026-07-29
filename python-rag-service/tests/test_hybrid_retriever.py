from __future__ import annotations

import json
import time
from pathlib import Path

import pytest
from langchain_core.embeddings import Embeddings
from langchain_core.retrievers import BaseRetriever

from app.chains import PolicyQueryPlanner
from app.evaluation import evaluate_shared_fixture
from app.observability import LocalRAGMetrics
from app.retrievers import (
    HybridPolicyRetriever,
    PolicyRetrievalUnavailable,
    RetrievalCandidate,
    build_or_fts_query,
    fuse_policy_candidates,
)
from app.retrievers.hybrid import RankedCandidate


class _FixedEmbeddings(Embeddings):
    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [[0.1, 0.2, 0.3] for _ in texts]

    def embed_query(self, text: str) -> list[float]:
        return self.embed_documents([text])[0]


class _FakeSearchStore:
    def __init__(
        self,
        channels: dict[str, list[RetrievalCandidate]] | None = None,
        *,
        delay: float = 0,
        channel_delays: dict[str, float] | None = None,
        failures: set[str] | None = None,
    ) -> None:
        self.channels = channels or {}
        self.delay = delay
        self.channel_delays = channel_delays or {}
        self.failures = failures or set()
        self.calls: list[str] = []

    def check_read_only_permissions(self) -> None:
        return None

    def _result(self, channel: str) -> list[RetrievalCandidate]:
        self.calls.append(channel)
        delay = self.channel_delays.get(channel, self.delay)
        if delay:
            time.sleep(delay)
        if channel in self.failures:
            raise RuntimeError("fixture channel failure")
        return list(self.channels.get(channel, []))

    def exact_search(self, plan, limit):
        del plan, limit
        return self._result("exact")

    def fts_search(self, plan, fts_query, limit):
        del plan, limit
        assert " OR " in fts_query
        return self._result("fts")

    def vector_search(self, plan, embedding, model_version, dimensions, limit):
        del plan, limit
        assert embedding == [0.1, 0.2, 0.3]
        assert model_version == "fixture-3-v1"
        assert dimensions == 3
        return self._result("vector")

    def trigram_search(self, plan, limit):
        del plan, limit
        return self._result("trigram")


def _candidate(
    chunk_id: int,
    document_id: int,
    document_type: str,
    *,
    section: str = "第一条",
    historical: bool = False,
) -> RetrievalCandidate:
    return RetrievalCandidate(
        chunk_id=chunk_id,
        document_id=document_id,
        content=f"{document_type} 证据 {chunk_id}",
        title=document_type,
        document_type=document_type,
        source_type="official_historical_compilation" if historical else "official",
        section_title=section,
        source_locator=section,
        historical=historical,
    )


def _ranked(*candidates: RetrievalCandidate) -> list[RankedCandidate]:
    return [
        RankedCandidate(candidate=candidate, rank=index + 1)
        for index, candidate in enumerate(candidates)
    ]


def test_policy_query_planner_migrates_domain_rules_and_hides_question_from_audit():
    planner = PolicyQueryPlanner()
    plan = planner.invoke(" 补烤成绩怎摸算 ")

    assert plan.intent == "second_exam_grade"
    assert plan.normalized_question == "补考成绩怎么算"
    assert "等级为D或F" in plan.exact_terms
    assert "绩点为1或0" in plan.exact_terms
    assert plan.allow_historical is True
    assert plan.preferred_document_types[:3] == [
        "school_policy_reasoning_card",
        "school_undergraduate_retake_policy",
        "school_undergraduate_status_policy",
    ]
    encoded_audit = json.dumps(plan.audit_summary(), ensure_ascii=False)
    assert plan.normalized_question not in encoded_audit


def test_policy_query_planner_treats_missing_credit_as_failed_course_flow():
    plan = PolicyQueryPlanner().invoke("没拿到学分怎么办")

    assert plan.intent == "second_exam_and_retake"
    assert plan.allow_historical is True
    assert "首次考核不合格" in plan.expanded_terms
    assert "school_undergraduate_status_policy" in plan.preferred_document_types
    assert "school_undergraduate_retake_policy" in plan.preferred_document_types


@pytest.mark.parametrize(
    "question",
    ["奖学金怎么评", "挂科影响奖学金吗"],
)
def test_policy_query_planner_routes_scholarship_questions_to_v08_documents(
    question: str,
):
    plan = PolicyQueryPlanner().invoke(question)

    assert plan.intent == "scholarship_selection"
    assert plan.allow_historical is False
    assert plan.preferred_document_types[0] == (
        "school_undergraduate_scholarship_policy"
    )
    assert {"奖学金评审", "申报制", "综合测评", "专业年级排名"}.issubset(
        plan.expanded_terms
    )
    assert "school_undergraduate_retake_policy" not in plan.preferred_document_types


@pytest.mark.parametrize(
    ("question", "intent", "document_type"),
    [
        ("国家助学金怎么申请", "hardship_aid", "school_national_grant_policy"),
        ("生源地贷款怎么办", "student_loan", "school_student_loan_policy"),
        ("孤儿减免需要什么材料", "orphan_aid", "school_orphan_aid_policy"),
        ("勤工助学一小时多少钱", "work_study", "school_work_study_policy"),
    ],
)
def test_policy_query_planner_routes_direct_aid_policy_names(
    question: str, intent: str, document_type: str
):
    plan = PolicyQueryPlanner().invoke(question)

    assert plan.intent == intent
    assert document_type in plan.preferred_document_types
    assert plan.expanded_terms


@pytest.mark.parametrize(
    ("question", "document_type"),
    [
        ("学位证怎么拿", "national_bachelor_degree_regulation"),
        ("计算机专业都学啥", "official_major_profile"),
        ("通信工程以后干什么", "official_major_profile"),
        ("能换到别的专业吗", "school_undergraduate_major_transfer_policy"),
        ("考试带小抄怎么处理", "school_exam_misconduct_policy"),
        ("毕业要满足什么", "school_undergraduate_status_policy"),
        ("比赛获奖能改课程成绩吗", "school_competition_course_grade_reward_policy"),
        ("论文奖励成绩需要什么材料", "school_competition_grade_reward_forms"),
        ("国奖怎么评", "school_national_scholarship_policy"),
        ("励志奖要什么条件", "school_national_inspirational_scholarship_policy"),
        ("贫困生怎么认定", "school_financial_hardship_recognition_policy"),
        ("临时补助怎么申请", "school_grant_and_temporary_aid_policy"),
        ("孤儿能免学费住宿费吗", "school_orphan_aid_policy"),
        ("校内兼职一小时多少钱", "school_work_study_policy"),
    ],
)
def test_policy_query_planner_routes_colloquial_questions_to_owned_documents(
    question: str, document_type: str
):
    plan = PolicyQueryPlanner().invoke(question)

    assert document_type in plan.preferred_document_types
    assert plan.exact_terms or plan.expanded_terms


@pytest.mark.parametrize(
    ("question", "first_document_type"),
    [
        ("国奖怎么评", "school_national_scholarship_policy"),
        ("励志奖要什么条件", "school_national_inspirational_scholarship_policy"),
        ("国家助学金咋申请", "school_national_grant_policy"),
        ("论文奖励成绩需要什么材料", "school_competition_grade_reward_forms"),
    ],
)
def test_policy_query_planner_prioritizes_the_specific_policy_named_by_user(
    question: str, first_document_type: str
):
    plan = PolicyQueryPlanner().invoke(question)

    assert plan.preferred_document_types[0] == first_document_type


def test_policy_query_planner_expands_colloquial_profile_and_degree_terms_for_lexical_recall():
    profile = PolicyQueryPlanner().invoke("计算机专业都学啥")
    degree = PolicyQueryPlanner().invoke("学位证怎么拿")

    assert profile.normalized_question == "计算机科学与技术专业都学啥"
    assert "计算机科学与技术" in profile.exact_terms
    assert "学士学位" in degree.expanded_terms
    assert "学位授予" in degree.expanded_terms


def test_python_policy_contract_matches_the_knowledge_base_contract():
    service_contract = (
        Path(__file__).parents[1]
        / "app"
        / "chains"
        / "policy_query_contract_v0.8.json"
    ).read_text(encoding="utf-8")
    knowledge_contract = (
        Path(__file__).parents[2]
        / "knowledge-base"
        / "sylu-academic-policy"
        / "v0.8"
        / "policy_query_contract_v0.8.json"
    ).read_text(encoding="utf-8")

    assert json.loads(service_contract) == json.loads(knowledge_contract)


def test_shadow_index_switch_disables_vector_and_records_channel_metrics():
    candidate = _candidate(1, 1, "school_undergraduate_status_policy")
    store = _FakeSearchStore(
        channels={"exact": [candidate], "fts": [candidate], "trigram": [candidate]}
    )
    metrics = LocalRAGMetrics(
        chain_name="shenliyuan_policy_rag",
        chain_version="observability-release-v5",
        hash_secret="retrieval-metrics-secret",
    )
    retriever = HybridPolicyRetriever(
        search_store=store,
        embeddings=_FixedEmbeddings(),
        embedding_model_version="fixture-3-v1",
        shadow_index_enabled=False,
        metrics_recorder=metrics,
    )

    documents = retriever.invoke("如何申请休学")
    snapshot = metrics.snapshot()

    assert "vector" not in store.calls
    assert documents[0].metadata["degraded_modes"] == ["shadow_index_disabled"]
    assert snapshot["retrieval_channels"]["vector"]["outcomes"] == {"disabled": 1}
    assert snapshot["retrieval_channels"]["fts"]["candidate_total"] == 1


def test_general_plan_excludes_history_and_fts_uses_grouped_or_semantics():
    plan = PolicyQueryPlanner().invoke("如何申请休学")
    query = build_or_fts_query(plan)

    assert plan.history_policy == "exclude"
    assert plan.version_boundary == "current_only"
    assert "school_undergraduate_status_policy" in plan.preferred_document_types
    assert " OR " in query
    assert " AND " not in query


def test_weighted_fusion_prefers_exact_current_rules_and_uses_trigram_as_fallback():
    plan = PolicyQueryPlanner().invoke("如何申请休学")
    exact = _candidate(1, 1, "school_undergraduate_status_policy")
    fuzzy = _candidate(2, 2, "school_competition_course_grade_reward_policy")
    documents = fuse_policy_candidates(
        plan,
        {"exact": _ranked(exact), "trigram": _ranked(fuzzy)},
        5,
    )

    assert [document.metadata["chunk_id"] for document in documents] == [1, 2]
    assert (
        documents[0].metadata["score_details"]["exact"]
        > documents[1].metadata["score_details"]["trigram"]
    )
    audit = documents[0].metadata["retrieval_audit"]
    assert set(audit) == {"content_hash", "score", "version", "locator"}
    assert len(audit["content_hash"]) == 64

    enough_lexical = [
        _candidate(index, index, "school_undergraduate_status_policy")
        for index in range(10, 16)
    ]
    documents = fuse_policy_candidates(
        plan,
        {"exact": _ranked(*enough_lexical), "trigram": _ranked(fuzzy)},
        5,
    )
    assert all(document.metadata["chunk_id"] != 2 for document in documents)


def test_second_exam_top_five_contains_current_and_historical_rules_without_competition_first():
    plan = PolicyQueryPlanner().invoke("补考成绩怎么算")
    competition = _candidate(50, 50, "school_competition_course_grade_reward_policy")
    current_status = _candidate(30, 30, "school_undergraduate_status_policy")
    current_retake = _candidate(20, 20, "school_undergraduate_retake_policy")
    history = _candidate(
        40, 40, "historical_school_second_exam_policy", historical=True
    )
    documents = fuse_policy_candidates(
        plan,
        {
            "exact": _ranked(history, current_status, current_retake),
            "fts": _ranked(current_status, current_retake, history),
            "vector": _ranked(competition, current_status),
        },
        5,
    )
    types = [document.metadata["document_type"] for document in documents]

    assert types[0] != "school_competition_course_grade_reward_policy"
    assert "historical_school_second_exam_policy" in types
    assert "school_undergraduate_status_policy" in types
    assert "school_undergraduate_retake_policy" in types


def test_diversity_limits_adjacent_chunks_from_one_document():
    plan = PolicyQueryPlanner().invoke("如何申请休学")
    candidates = [
        _candidate(1, 1, "school_undergraduate_status_policy", section="第九条"),
        _candidate(2, 1, "school_undergraduate_status_policy", section="第九条"),
        _candidate(3, 1, "school_undergraduate_status_policy", section="第十条"),
        _candidate(4, 1, "school_undergraduate_status_policy", section="第十一条"),
        _candidate(5, 2, "school_undergraduate_retake_policy"),
        _candidate(6, 3, "school_exam_misconduct_policy"),
    ]
    documents = fuse_policy_candidates(plan, {"exact": _ranked(*candidates)}, 6)

    assert [document.metadata["document_id"] for document in documents[:3]] == [1, 2, 3]
    assert 2 not in [document.metadata["chunk_id"] for document in documents]
    assert len({document.metadata["document_id"] for document in documents[:3]}) == 3


@pytest.mark.asyncio
async def test_hybrid_retriever_is_base_retriever_and_runs_all_channels_in_parallel():
    evidence = _candidate(1, 1, "school_undergraduate_status_policy")
    store = _FakeSearchStore({"exact": [evidence]}, delay=0.1)
    retriever = HybridPolicyRetriever(
        search_store=store,
        embeddings=_FixedEmbeddings(),
        embedding_model_version="fixture-3-v1",
        channel_timeout_seconds=1,
    )

    started = time.perf_counter()
    documents = await retriever.ainvoke("如何申请休学")
    elapsed = time.perf_counter() - started

    assert isinstance(retriever, BaseRetriever)
    assert len(documents) == 1
    assert set(store.calls) == {"exact", "fts", "vector", "trigram"}
    assert elapsed < 0.3

    event_names = []
    async for event in retriever.astream_events("如何申请休学", version="v2"):
        event_names.append(event["name"])
    assert "policy_query_planner" in event_names


def test_single_channel_failure_degrades_and_all_failures_raise_stable_error():
    evidence = _candidate(1, 1, "school_undergraduate_status_policy")
    retriever = HybridPolicyRetriever(
        search_store=_FakeSearchStore({"exact": [evidence]}, failures={"vector"}),
        embeddings=_FixedEmbeddings(),
        embedding_model_version="fixture-3-v1",
    )
    documents = retriever.invoke("如何申请休学")
    assert documents[0].metadata["degraded_modes"] == ["vector_failed"]

    failed = HybridPolicyRetriever(
        search_store=_FakeSearchStore(failures={"exact", "fts", "vector", "trigram"}),
        embeddings=_FixedEmbeddings(),
        embedding_model_version="fixture-3-v1",
    )
    with pytest.raises(
        PolicyRetrievalUnavailable, match="^policy retrieval unavailable$"
    ):
        failed.invoke("如何申请休学")


def test_slow_channel_times_out_without_blocking_successful_channels():
    evidence = _candidate(1, 1, "school_undergraduate_status_policy")
    # 排除 jieba 首次加载词典的冷启动，使本用例只测量四路通道的并发计时。
    build_or_fts_query(PolicyQueryPlanner().invoke("如何申请休学"))
    metrics = LocalRAGMetrics(
        chain_name="shenliyuan_policy_rag",
        chain_version="observability-release-v5",
        hash_secret="channel-timing-secret",
    )
    retriever = HybridPolicyRetriever(
        search_store=_FakeSearchStore(
            {"exact": [evidence]}, channel_delays={"trigram": 0.2}
        ),
        embeddings=_FixedEmbeddings(),
        embedding_model_version="fixture-3-v1",
        channel_timeout_seconds=0.05,
        metrics_recorder=metrics,
    )

    started = time.perf_counter()
    documents = retriever.invoke("如何申请休学")

    assert time.perf_counter() - started < 0.15
    assert documents[0].metadata["degraded_modes"] == ["trigram_timeout"]
    channels = metrics.snapshot()["retrieval_channels"]
    assert channels["exact"]["duration_ms"]["max"] < 50
    assert channels["trigram"]["duration_ms"]["max"] >= 40


def test_shared_v06_fixture_recall_at_five_matches_t01_baseline():
    data = (
        Path(__file__).parents[2]
        / "server"
        / "testdata"
        / "ai_eval"
        / "policy_quality.jsonl"
    )
    cases = [
        json.loads(line)
        for line in data.read_text(encoding="utf-8").splitlines()
        if line
    ]
    key_cases = [case for case in cases if case["category"] == "v06_core"]
    assert len(key_cases) == 21

    relevant_total = 0
    relevant_hit = 0
    reciprocal_rank = 0.0
    for case in key_cases:
        candidates = []
        for item in case["fixture"]["retrieved"]:
            historical = bool(item.get("historical", False))
            candidates.append(
                RetrievalCandidate(
                    chunk_id=item["chunk_id"],
                    document_id=item["document_id"],
                    content=item.get("content", "fixture"),
                    title=item.get("title", "fixture"),
                    document_type=item["document_type"],
                    source_type="official_historical_compilation"
                    if historical
                    else "official",
                    historical=historical,
                )
            )
        retriever = HybridPolicyRetriever(
            search_store=_FakeSearchStore({"exact": candidates, "fts": candidates}),
            embeddings=_FixedEmbeddings(),
            embedding_model_version="fixture-3-v1",
            k=5,
        )
        documents = retriever.invoke(case["question"])
        top_types = [document.metadata["document_type"] for document in documents[:5]]
        targets = case["target_document_types"]
        relevant_total += len(targets)
        for target in targets:
            if target in top_types:
                relevant_hit += 1
        first_rank = min(
            (top_types.index(target) + 1 for target in targets if target in top_types),
            default=0,
        )
        if first_rank:
            reciprocal_rank += 1 / first_rank

    assert relevant_hit / relevant_total == 1.0
    assert reciprocal_rank / len(key_cases) == 1.0


def test_shared_fixture_report_matches_t01_retrieval_metrics():
    directory = Path(__file__).parents[2] / "server" / "testdata" / "ai_eval"
    report = evaluate_shared_fixture(directory, k=5)

    assert report["cases"] == 42
    assert report["relevant_targets"] == 42
    assert report["recall_at_k"] == 1.0
    assert report["mrr"] == 1.0
    assert report["failures"] == []
