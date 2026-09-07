from pathlib import Path

import pytest

from models.schemas import PreVerifyInput
from routers import auth
from routers.auth import _require_school_verified_student_id, pre_verify_edu_account
from services.crawler import EduCrawler, LoginFailedError, StudentInfo


FIXTURE_DIR = Path(__file__).parent / "fixtures" / "profile"


def _fixture(name: str) -> str:
    return (FIXTURE_DIR / name).read_text(encoding="utf-8")


def test_profile_parser_requires_all_three_school_identity_fields():
    crawler = EduCrawler()

    info = crawler._parse_student_info_body(
        _fixture("undergraduate_profile_verified.html")
    )

    assert info.school_verified_student_id == "TEST_STUDENT_ID"
    assert info.name == "测试学生"


@pytest.mark.parametrize(
    "fixture_name",
    [
        "undergraduate_profile_missing_identity.html",
        "undergraduate_profile_conflicting_identity.html",
    ],
)
def test_profile_parser_marks_missing_or_conflicting_identity_unverified(fixture_name):
    crawler = EduCrawler()

    info = crawler._parse_student_info_body(_fixture(fixture_name))

    assert info.school_verified_student_id is None


def test_pre_verify_rejects_school_identity_mismatch():
    info = StudentInfo(
        name="测试学生",
        grade="2026",
        college="测试学院",
        major="测试专业",
        school_verified_student_id="TEST_SCHOOL_ID",
    )

    with pytest.raises(LoginFailedError) as exc_info:
        _require_school_verified_student_id(info, "TEST_REQUEST_ID")

    assert exc_info.value.code == "EDU_IDENTITY_MISMATCH"


class _FakeCrawler:
    def __init__(self, student_info):
        self.student_info = student_info

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc_value, traceback):
        return None

    async def login(self, student_id, password):
        return "transient-cookie"

    async def get_student_info(self, cookie, student_id):
        return self.student_info


@pytest.mark.asyncio
async def test_pre_verify_returns_school_verified_student_id(monkeypatch):
    info = StudentInfo(
        name="测试学生",
        grade="2026",
        college="测试学院",
        major="测试专业",
        school_verified_student_id="1234567890",
    )
    monkeypatch.setattr(auth, "EduCrawler", lambda: _FakeCrawler(info))

    response = await pre_verify_edu_account(
        PreVerifyInput(student_id="1234567890", password="test-password")
    )

    assert response.success is True
    assert response.student_id == "1234567890"
    assert response.school_verified_student_id == "1234567890"


@pytest.mark.asyncio
async def test_pre_verify_returns_identity_unverified_without_persisting_cookie_or_password():
    info = StudentInfo(
        name="测试学生",
        grade="2026",
        college="测试学院",
        major="测试专业",
        school_verified_student_id=None,
    )
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(auth, "EduCrawler", lambda: _FakeCrawler(info))
    try:
        response = await pre_verify_edu_account(
            PreVerifyInput(student_id="1234567890", password="test-password")
        )
    finally:
        monkeypatch.undo()

    assert response.success is False
    assert response.code == "EDU_IDENTITY_UNVERIFIED"
    assert response.school_verified_student_id is None
    assert not hasattr(response, "cookie")
