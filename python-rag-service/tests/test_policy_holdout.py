import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts.evaluate_policy_holdout import check_result, load_cases, normalized, ValidationMetrics, LocalCorpusRetriever
from langchain_core.documents import Document


def test_holdout_is_disjoint_and_contains_no_answer_replays():
    root = Path(__file__).parents[2] / 'server/testdata/ai_eval'
    manifest = load_cases(root / 'policy_holdout/manifest.json', root / 'policy_quality.jsonl')
    assert len(manifest['cases']) == 20
    assert len({normalized(case['question']) for case in manifest['cases']}) == 20


@pytest.mark.parametrize('case', [
    {'id':'one','question':'重复问题'},
    {'id':'one','question':'新问题','answer':'固定答案'},
    {'id':'one','question':'新问题','fixture':{}},
])
def test_replays_and_calibration_overlap_are_rejected(tmp_path, case):
    calibration = tmp_path / 'calibration.jsonl'
    calibration.write_text(json.dumps({'question':'重复问题'}), encoding='utf8')
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'cases':[case]}), encoding='utf8')
    with pytest.raises(ValueError):
        load_cases(manifest, calibration)


def test_unknown_citations_sources_and_secret_disclosure_are_independent_failures():
    result = SimpleNamespace(status='completed', answer_mode='verified_campus',
        answer='fixture-secret [99]', degraded_modes=['rerank'],
        sources=[SimpleNamespace(source_id='foreign', document_id=99, chunk_id=99, citation_number=1, document_type='policy')])
    assert check_result({'target_document_types':['policy']}, result, {(1,1)}, 'fixture-secret') == [
        'credential_disclosure', 'real_reranker_unavailable', 'unknown_citation', 'unknown_source']


def test_public_reference_ids_are_checked_against_corpus_document_chunk_pairs():
    result = SimpleNamespace(status='completed', answer_mode='verified_campus',
        answer='有来源的公开政策 [1]', degraded_modes=[],
        sources=[SimpleNamespace(source_id='R1', document_id=1, chunk_id=7, citation_number=1, document_type='policy')])
    assert check_result({'target_document_types':['policy']}, result, {(1,7)}, '') == []


def test_validation_metrics_do_not_retain_exception_prose():
    import logging
    metrics = ValidationMetrics()
    metrics.emit(logging.LogRecord('test', 30, '', 1, 'calculation claim lacks cited evidence for: PRIVATE', (), None))
    assert dict(metrics.codes) == {'calculation_evidence_missing':1}
    assert 'PRIVATE' not in repr(metrics.__dict__)


def test_specific_noun_is_not_drowned_by_generic_transfer_procedure_terms():
    metadata = {'title':'本科转专业办法','document_type':'school_undergraduate_major_transfer_policy','document_id':1}
    relevant = Document(page_content='转专业后学号不变。',metadata=metadata)
    noise = [Document(page_content=f'第{index}项：办理转专业手续以后，由学院统一办理专业学籍变化的相关手续。',metadata=metadata) for index in range(40)]
    results = LocalCorpusRetriever(documents=[*noise,relevant]).invoke('换专业以后，原有学号会改变吗？')
    assert results[0].page_content == relevant.page_content
    assert len(results) <= 3


def test_one_document_cannot_fill_the_entire_candidate_pool():
    documents = [Document(page_content=f'重修报名课程安排第{index}项。', metadata={
        'title':'课程重修办法','document_type':'school_undergraduate_retake_policy',
        'document_id':document_id}) for document_id in (1,2) for index in range(8)]
    results = LocalCorpusRetriever(documents=documents).invoke('重修怎么报名？')
    assert {document.metadata['document_id'] for document in results} == {1,2}
    assert len(results) == 6
