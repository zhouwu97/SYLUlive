"""教务聚合接口请求模型测试。"""

import pytest
from pydantic import ValidationError

from routers.context_bundle import ContextBundleRequest


def test_context_bundle_accepts_term_dataset_without_user_id():
    request = ContextBundleRequest.model_validate(
        {"datasets": [{"type": "grades", "year": "2025-2026", "semester": 3}]}
    )

    assert request.datasets[0].key == "grades:2025-2026:3"


def test_context_bundle_rejects_user_id_in_body():
    with pytest.raises(ValidationError):
        ContextBundleRequest.model_validate(
            {
                "datasets": [
                    {
                        "type": "grades",
                        "year": "2025-2026",
                        "semester": 3,
                        "user_id": "1",
                    }
                ]
            }
        )


def test_context_bundle_rejects_duplicate_dataset():
    with pytest.raises(ValidationError):
        ContextBundleRequest.model_validate(
            {
                "datasets": [
                    {"type": "academic_situation"},
                    {"type": "academic_situation"},
                ]
            }
        )
