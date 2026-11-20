from langchain_core.documents import Document

from app.chains.policy import _should_generate_verified_answer, _parse_fallback_generated, _bounded_documents
from langchain_core.messages import AIMessage
from app.chains.query_planner import PolicyQueryPlanner
from app.schemas import PolicyRAGInput


def eligible(question, *, title='本科重修办法', effective_from='2026-01-01'):
    state = {'request':PolicyRAGInput(request_id='boundary',question=question),
        'query_plan':PolicyQueryPlanner().invoke(question),
        'documents':[Document(page_content='办理材料须由本人向学校申请。', metadata={
            'document_id':1,'chunk_id':1,'title':title,'effective_from':effective_from,
            'document_type':'school_undergraduate_retake_policy'})]}
    return _should_generate_verified_answer(state,.5,False)


def test_policy_evidence_does_not_authorize_issuing_an_official_document():
    assert not eligible('替我开具带有教务处公章的毕业证明。')


def test_asking_how_to_apply_remains_a_policy_question():
    assert eligible('帮我说明毕业证明应该如何开具，需要哪些材料？')


def test_specific_new_policy_version_requires_matching_version_evidence():
    assert not eligible('给出2027年新施行的重修收费通知中的确切金额。')
    assert eligible('给出2027年新施行的重修收费通知中的确切金额。', effective_from='2027-01-01')


def test_a_future_study_plan_does_not_imply_a_new_policy_version():
    assert eligible('2027年我到第九学期，按照现行办法最多重修几门？')


def test_general_circuit_explanation_can_use_resistor_names():
    question = '电阻R1和R2串联时怎样求总阻值？'
    request = PolicyRAGInput(request_id='circuit',question=question)
    result = _parse_fallback_generated({'state':{'request':request,
        'query_plan':PolicyQueryPlanner().invoke(question),'documents':[]},
        'message':AIMessage(content='电阻R1和R2串联时，总阻值为两者之和。',
            usage_metadata={'input_tokens':10,'output_tokens':10,'total_tokens':20})},'test','test')
    assert result.status == 'general_completed'
    assert result.answer_mode == 'general_answer'


def test_formal_policy_is_selected_before_a_preferred_derived_reasoning_card():
    request = PolicyRAGInput(request_id='authority',question='重修政策是什么？',max_sources=1)
    plan = PolicyQueryPlanner().invoke(request.question).model_copy(update={
        'preferred_document_types':['school_policy_reasoning_card','school_undergraduate_retake_policy']})
    documents = [Document(page_content='推理卡。',metadata={'document_id':1,'chunk_id':1,'document_type':'school_policy_reasoning_card'}),
        Document(page_content='正式政策原文。',metadata={'document_id':2,'chunk_id':2,'document_type':'school_undergraduate_retake_policy'})]
    selected = _bounded_documents({'request':request,'query_plan':plan,'documents':documents})
    assert selected[0].metadata['chunk_id'] == 2


def test_historical_comparison_reranking_uses_neutral_policy_terms():
    plan = PolicyQueryPlanner().invoke('有人把旧二考口径套在现行重修上，要求统一记60分，应如何区分？')
    assert plan.allow_historical
    assert plan.normalized_question not in plan.reranking_query
    assert all(term in plan.reranking_query for term in plan.exact_terms + plan.expanded_terms)
    assert '60' in plan.normalized_question
    assert '成绩记载' in plan.reranking_query


def test_current_policy_reranking_retains_the_original_question():
    plan = PolicyQueryPlanner().invoke('转专业后的学号是否改变？')
    assert not plan.allow_historical
    assert plan.reranking_query == plan.retrieval_query


def test_history_eligible_retake_question_keeps_its_specific_subject():
    plan = PolicyQueryPlanner().invoke('重修毕业论文，网上报名后还要去哪里报名？')
    assert not plan.uses_neutral_historical_query
    assert plan.reranking_query == plan.retrieval_query
    assert '毕业论文' in plan.reranking_query


def test_personal_past_does_not_become_a_policy_version_comparison():
    plan = PolicyQueryPlanner().invoke('我以前挂过科，现在想报名重修怎么办？')
    assert not plan.uses_neutral_historical_query
    assert plan.reranking_query == plan.retrieval_query
