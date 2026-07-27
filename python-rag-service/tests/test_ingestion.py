from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings

from app.ingestion import FastEmbedLangChainEmbeddings
from app.ingestion.policy import ChinesePolicyTextSplitter, chunk_policy_document
from app.schemas import KnowledgeChunkRequest


class _FixedFastEmbed:
    def __init__(self, dimensions: int = 3) -> None:
        self.dimensions = dimensions
        self.inputs: list[str] = []

    def embed(self, texts: list[str]):
        self.inputs.extend(texts)
        for index, _ in enumerate(texts):
            yield [float(index + 1)] * self.dimensions


def _request(content: str, **overrides: object) -> KnowledgeChunkRequest:
    payload: dict[str, object] = {
        "document_id": 7,
        "title": "本科生课程考核办法",
        "content": content,
        "source_locator": "https://example.edu/policy/7",
        "document_type": "school_exam_policy",
        "department": "教务处",
        "version_status": "published",
    }
    payload.update(overrides)
    return KnowledgeChunkRequest.model_validate(payload)


def test_splitter_returns_langchain_documents_with_auditable_metadata():
    source = Document(
        page_content="第一章 总则\n第一条 学生应按时参加考试。\n第二条 实践环节另行规定。",
        metadata={
            "document_id": 7,
            "document_type": "school_exam_policy",
            "department": "教务处",
            "version_status": "published",
            "effective_from": "2025-09-01T00:00:00+08:00",
        },
    )
    chunks = ChinesePolicyTextSplitter(chunk_size=700, chunk_overlap=80).split_documents([source])

    assert len(chunks) == 2
    assert all(isinstance(chunk, Document) for chunk in chunks)
    assert chunks[0].metadata["document_id"] == 7
    assert chunks[0].metadata["section_path"] == ["第一章 总则", "第一条"]
    assert chunks[1].metadata["source_locator"] == "第二条"
    assert chunks[1].metadata["version_status"] == "published"


@pytest.mark.parametrize(
    ("content", "expected_locator", "expected_text"),
    [
        (
            "四、重修报名\n1. 每学期不得超过三门。\n2. 逾期未缴费不能参加。",
            "第四部分第1项",
            "每学期不得超过三门",
        ),
        (
            "## 常见问题\n\nQ：补考成绩怎么算？\n\nA：历史规则按D/F记载。",
            "Q：补考成绩怎么算？",
            "历史规则按D/F记载",
        ),
        (
            "第一段没有标题。\n\n第二段继续说明。",
            "正文",
            "第二段继续说明",
        ),
    ],
)
def test_chinese_policy_structures_keep_readable_locators(
    content: str,
    expected_locator: str,
    expected_text: str,
):
    result = chunk_policy_document(_request(content))

    target = next(chunk for chunk in result.chunks if expected_text in chunk.content)
    assert target.source_locator == expected_locator
    assert not target.source_locator.startswith("chunk:")


def test_table_title_and_rows_remain_in_one_document():
    result = chunk_policy_document(
        _request(
            "## 成绩奖励\n\n表3 国家级竞赛奖励倍率\n| 奖项 | 倍率 |\n|---|---|\n| 一等奖 | 1.8 |\n| 二等奖 | 1.6 |",
            chunk_size=100,
            chunk_overlap=10,
        )
    )

    table = next(chunk for chunk in result.chunks if "| 二等奖 | 1.6 |" in chunk.content)
    assert "表3 国家级竞赛奖励倍率" in table.content
    assert table.source_locator == "表3 国家级竞赛奖励倍率"


def test_long_article_below_hard_limit_is_not_cut_at_soft_boundary():
    article = "第九条 " + "完整条款内容" * 25
    result = chunk_policy_document(
        _request(
            "第一章 总则\n" + article + "\n第十条 后续条款。",
            chunk_size=150,
            chunk_overlap=20,
        )
    )

    target = next(chunk for chunk in result.chunks if "完整条款内容" in chunk.content)
    assert article in target.content
    assert "第十条" not in target.content


def test_empty_and_oversized_documents_have_deterministic_boundaries():
    with pytest.raises(ValueError):
        chunk_policy_document(_request("   "))

    result = chunk_policy_document(
        _request("超大正文" * 5_000, chunk_size=200, chunk_overlap=20)
    )
    assert len(result.chunks) > 1
    assert all(1 <= len(chunk.content) <= 200 for chunk in result.chunks)


def test_embedding_text_adds_metadata_without_mutating_display_content():
    result = chunk_policy_document(
        _request("## 办理规则\n\n检索别名：挂科、补考\n\n课程首次考核不合格可参加二次考试。")
    )
    chunk = result.chunks[0]

    assert chunk.content != chunk.embedding_text
    assert chunk.content.endswith("课程首次考核不合格可参加二次考试。")
    for expected in ["本科生课程考核办法", "school_exam_policy", "教务处", "办理规则", "挂科 补考"]:
        assert expected in chunk.embedding_text
    for key in [
        "document_id",
        "section_title",
        "section_path",
        "source_locator",
        "document_type",
        "department",
        "version_status",
        "effective_from",
    ]:
        assert key in chunk.metadata


def test_long_policy_unit_uses_whole_sentence_overlap():
    sentences = [character * 60 + "。" for character in "甲乙丙丁"]
    result = chunk_policy_document(
        _request(
            "第九条 " + "".join(sentences),
            chunk_size=100,
            chunk_overlap=50,
        )
    )

    assert len(result.chunks) > 1
    assert all(chunk.source_locator.startswith("第九条") for chunk in result.chunks)
    assert any(sentences[0] in chunk.content and sentences[1] in chunk.content for chunk in result.chunks)


def test_v06_second_exam_rule_is_complete_and_locatable():
    path = (
        Path(__file__).parents[2]
        / "knowledge-base"
        / "sylu-academic-policy"
        / "v0.6"
        / "documents"
        / "sylu-second-exam-retake-policy-card-v06.md"
    )
    result = chunk_policy_document(_request(path.read_text(encoding="utf-8")))

    target = next(chunk for chunk in result.chunks if "等级为D或F，对应绩点为1或0" in chunk.content)
    assert "第3项" in target.source_locator
    assert "二考成绩只记“及格”或“不及格”" in target.content


def test_fastembed_adapter_implements_langchain_contract_without_padding():
    client = _FixedFastEmbed(dimensions=3)
    embeddings = FastEmbedLangChainEmbeddings(
        client,
        model_name="fake-model",
        model_version="fake-model-3-v1",
        expected_dimensions=3,
    )

    assert isinstance(embeddings, Embeddings)
    assert embeddings.embed_documents(["文档"])[0] == [1.0, 1.0, 1.0]
    assert embeddings.embed_query("查询") == [1.0, 1.0, 1.0]
    assert client.inputs == ["文档", "查询"]
    assert embeddings.dimensions == 3


def test_embedding_dimension_mismatch_fails_instead_of_padding():
    embeddings = FastEmbedLangChainEmbeddings(
        _FixedFastEmbed(dimensions=3),
        model_name="fake-model",
        model_version="fake-model-4-v1",
        expected_dimensions=4,
    )

    with pytest.raises(ValueError, match="dimensions"):
        embeddings.embed_query("查询")


def test_embedding_endpoint_reports_real_dimensions(monkeypatch):
    from app import main

    main.SERVICE_TOKEN = "test-token"
    monkeypatch.setattr(main, "EXPECTED_DIMENSIONS", 3)
    monkeypatch.setattr(main, "TextEmbedding", lambda **_: _FixedFastEmbed(dimensions=3))
    with TestClient(main.app) as client:
        response = client.post(
            "/internal/rag/embed",
            headers={"X-Internal-Service-Token": "test-token"},
            json={"text": "补考规定"},
        )

    assert response.status_code == 200
    assert response.json()["dimensions"] == 3
    assert response.json()["embeddings"] == [[1.0, 1.0, 1.0]]
