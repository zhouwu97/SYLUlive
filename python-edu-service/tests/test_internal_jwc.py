"""测试 internal_jwc 路由 — 参数校验、状态码、响应结构。

使用 standalone FastAPI app 避免导入 main.py（main.py 依赖的
services/crawler.py 有预存在的编码问题，不在本轮修改范围）。
"""
import os
import pytest
from unittest.mock import patch, AsyncMock

from fastapi import FastAPI
from fastapi.testclient import TestClient

os.environ.setdefault("INTERNAL_SERVICE_TOKEN", "test-token-jwc")


@pytest.fixture(autouse=True)
def _clear_lock():
    """每次测试前释放并发锁。"""
    from routers.internal_jwc import _jwc_crawl_lock
    if _jwc_crawl_lock.locked():
        _jwc_crawl_lock._locked = False
        _jwc_crawl_lock._waiters.clear()
    yield


@pytest.fixture
def client():
    """创建仅包含 JWC 路由的 standalone FastAPI app。

    避免导入 main.py，因为其间接依赖 services/crawler.py，
    而该文件存在预存在的 NEL 行终止符问题，不在本轮修改范围。
    """
    from routers import internal_jwc
    app = FastAPI()
    app.include_router(internal_jwc.router)
    return TestClient(app)


@pytest.fixture
def auth_headers():
    return {"Authorization": "Bearer test-token-jwc"}


class TestAuthRequired:
    def test_no_token_returns_401(self, client):
        resp = client.post("/api/internal/jwc/crawl", json={
            "categories": ["jwtz"],
            "max_pages": 1,
        })
        assert resp.status_code == 401

    def test_wrong_token_returns_401(self, client):
        resp = client.post(
            "/api/internal/jwc/crawl",
            json={"categories": ["jwtz"], "max_pages": 1},
            headers={"Authorization": "Bearer wrong"},
        )
        assert resp.status_code == 401

    def test_correct_token_calls_handler(self, client, auth_headers):
        with patch(
            "routers.internal_jwc.JWCPublicCrawler.crawl",
            new_callable=AsyncMock,
        ) as mock_crawl:
            mock_crawl.return_value = {
                "success": True,
                "generated_at": "2026-06-25T20:00:00+08:00",
                "items": [],
                "stats": {
                    "categories_requested": 1,
                    "pages_fetched": 0,
                    "list_items_seen": 0,
                    "article_details_fetched": 0,
                    "stop_reason": "max_pages_reached",
                    "partial_failure": False,
                },
                "errors": [],
            }
            resp = client.post(
                "/api/internal/jwc/crawl",
                json={"categories": ["jwtz"], "max_pages": 1},
                headers=auth_headers,
            )
            assert resp.status_code == 200


class TestParameterValidation:
    def test_invalid_category_rejected(self, client, auth_headers):
        resp = client.post(
            "/api/internal/jwc/crawl",
            json={"categories": ["invalid"], "max_pages": 1},
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_max_pages_too_large_rejected(self, client, auth_headers):
        resp = client.post(
            "/api/internal/jwc/crawl",
            json={"categories": ["jwtz"], "max_pages": 10},
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_max_pages_zero_rejected(self, client, auth_headers):
        resp = client.post(
            "/api/internal/jwc/crawl",
            json={"categories": ["jwtz"], "max_pages": 0},
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_known_urls_with_non_jwc_domain_rejected(self, client, auth_headers):
        resp = client.post(
            "/api/internal/jwc/crawl",
            json={
                "categories": ["jwtz"],
                "max_pages": 1,
                "known_source_urls": {
                    "jwtz": ["https://evil.com/info/1116/5946.htm"],
                },
            },
            headers=auth_headers,
        )
        assert resp.status_code == 422


class TestResponseStructure:
    def test_successful_response_structure(self, client, auth_headers):
        mock_items = [{
            "source": "jwc",
            "category": "教务通知",
            "category_slug": "jwtz",
            "category_id": "1116",
            "source_article_id": "5946",
            "source_url": "https://jwc.sylu.edu.cn/info/1116/5946.htm",
            "title": "Test Title",
            "publish_date": "2026-06-23",
            "author_department": "教务管理科",
            "content_html": "<p>test</p>",
            "content_text": "test",
            "attachments": [],
            "has_attachment": False,
            "content_hash": "a" * 64,
        }]

        with patch(
            "routers.internal_jwc.JWCPublicCrawler.crawl",
            new_callable=AsyncMock,
        ) as mock_crawl:
            mock_crawl.return_value = {
                "success": True,
                "generated_at": "2026-06-25T20:00:00+08:00",
                "items": mock_items,
                "stats": {
                    "categories_requested": 1,
                    "pages_fetched": 1,
                    "list_items_seen": 4,
                    "article_details_fetched": 1,
                    "stop_reason": "full_page_known",
                    "partial_failure": False,
                },
                "errors": [],
            }
            resp = client.post(
                "/api/internal/jwc/crawl",
                json={"categories": ["jwtz"], "max_pages": 1},
                headers=auth_headers,
            )
            assert resp.status_code == 200
            data = resp.json()
            assert data["success"] is True
            assert "generated_at" in data
            assert len(data["items"]) == 1
            assert data["items"][0]["content_hash"] == "a" * 64
            assert data["stats"]["stop_reason"] == "full_page_known"


class TestPartialFailure:
    def test_partial_failure_response(self, client, auth_headers):
        with patch(
            "routers.internal_jwc.JWCPublicCrawler.crawl",
            new_callable=AsyncMock,
        ) as mock_crawl:
            mock_crawl.return_value = {
                "success": True,
                "generated_at": "2026-06-25T20:00:00+08:00",
                "items": [],
                "stats": {
                    "categories_requested": 2,
                    "pages_fetched": 1,
                    "list_items_seen": 4,
                    "article_details_fetched": 0,
                    "stop_reason": "mixed",
                    "partial_failure": True,
                },
                "errors": [
                    {
                        "category": "jwgg",
                        "stage": "list_fetch",
                        "url": "https://jwc.sylu.edu.cn/jwgg.htm",
                        "code": "upstream_error",
                        "message": "HTTP 503",
                        "retryable": True,
                    }
                ],
            }
            resp = client.post(
                "/api/internal/jwc/crawl",
                json={"categories": ["jwtz", "jwgg"], "max_pages": 1},
                headers=auth_headers,
            )
            assert resp.status_code == 200
            data = resp.json()
            assert data["stats"]["partial_failure"] is True
            assert len(data["errors"]) == 1
