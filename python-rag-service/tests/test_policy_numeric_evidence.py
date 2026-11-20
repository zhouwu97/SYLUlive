import pytest

from app.chains.policy import _validate_structured_answer, PolicyCitationValidationError
from app.chains.query_planner import PolicyQueryPlanner
from app.schemas import PolicyAnswer
from langchain_core.documents import Document


def validate(statement, quote, citation_quote=None, reference='R1', title=''):
    answer = PolicyAnswer.model_validate({'answer':statement,
        'current_rules':[{'statement':statement,'citation_ids':['R1']}],
        'citations':[{'reference_id':reference,'quote':citation_quote or quote}], 'confidence':'high'})
    _validate_structured_answer(answer, documents=[Document(page_content=quote, metadata={'title':title})],
        plan=PolicyQueryPlanner().invoke('重修的集中授课与自学学时如何安排？'))


def test_cited_percentages_allow_the_general_word_proportion():
    validate('集中授课比例不少于70%，自学不超过30%。',
        '集中授课不少于总学时的70%，学生自学学时不超过总学时的30%。')


def test_equivalent_percentage_and_decimal_notation_is_supported():
    validate('集中授课比例不少于70.0%。', '集中授课不少于总学时的百分之70。')


def test_server_resolves_a_quote_anchor_to_the_actual_source_text():
    validate('集中授课比例不少于70%。', '集中授课不少于总学时的70%。', 'R1Q1')


def test_local_quote_anchor_has_a_distinct_namespace_from_source_ids():
    validate('集中授课比例不少于70%。', '集中授课不少于总学时的70%。', 'Q001')


@pytest.mark.parametrize('anchor', ['Q000','Q999'])
def test_unknown_local_quote_anchor_is_rejected(anchor):
    with pytest.raises(PolicyCitationValidationError):
        validate('集中授课比例不少于70%。', '集中授课不少于总学时的70%。', anchor)


@pytest.mark.parametrize('anchor', ['R2Q1','R1Q99'])
def test_forged_or_cross_source_quote_anchor_is_rejected(anchor):
    with pytest.raises(PolicyCitationValidationError):
        validate('集中授课比例不少于70%。', '集中授课不少于总学时的70%。', anchor)


def test_quote_anchor_cannot_authorize_a_number_absent_from_its_text():
    with pytest.raises(PolicyCitationValidationError):
        validate('集中授课比例不少于80%。', '集中授课不少于总学时的70%。', 'R1Q1')


def test_verified_document_number_is_not_mistaken_for_a_calculation_value():
    validate('按沈理工教〔2025〕6号，集中授课为70%。', '集中授课为原学时的70%。',
        'R1Q1', title='本科重修办法（沈理工教〔2025〕6号）')


def test_forged_document_number_is_not_exempted_from_numeric_validation():
    with pytest.raises(PolicyCitationValidationError):
        validate('按沈理工教〔2025〕8号，集中授课为70%。', '集中授课为原学时的70%。',
            'R1Q1', title='本科重修办法（沈理工教〔2025〕6号）')


@pytest.mark.parametrize('reference', ['（R1）','[R1]','来源R1','R1Q1','Q001','chunk:123'])
def test_temporary_source_identifiers_never_reach_reader_text(reference):
    with pytest.raises(PolicyCitationValidationError):
        validate('集中授课为70%。'+reference, '集中授课为70%。', 'R1Q1')


def test_proportion_paraphrase_does_not_authorize_new_numbers():
    with pytest.raises(PolicyCitationValidationError):
        validate('集中授课比例不少于80%，自学不超过20%。',
            '集中授课不少于总学时的70%，学生自学学时不超过总学时的30%。')


def test_grade_formula_still_requires_subject_and_calculation_evidence():
    with pytest.raises(PolicyCitationValidationError):
        validate('平时成绩和补考卷面按70%与30%的比例合成。',
            '集中授课不少于总学时的70%，学生自学学时不超过总学时的30%。')


@pytest.mark.parametrize('statement,quote', [
    ('集中授课不少于80%。', '集中授课不少于70%。'),
    ('集中授课不少于70%。', '集中授课不少于170%。'),
])
def test_numbers_next_to_chinese_text_require_exact_cited_values(statement, quote):
    with pytest.raises(PolicyCitationValidationError):
        validate(statement, quote)
