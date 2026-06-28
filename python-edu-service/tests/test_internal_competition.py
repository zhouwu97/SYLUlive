"""
比赛通知内部接口测试

测试 /api/internal/campus/competition/crawl 端点的认证、并发锁和响应结构。
不测试真实网络抓取（爬虫逻辑由 test_competition_public_crawler.py 覆盖）。
"""

import os
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    """创建测试客户端，设置内部 Token。

    使用与 test_internal_jwc.py 相同的 token 值，避免 pytest 同一 session
    中 auth 模块的 _INTERNAL_SERVICE_TOKEN 缓存冲突。
    """
    monkeypatch.setenv("INTERNAL_SERVICE_TOKEN", "test-token-jwc")

    # 重置 internal_auth 的 token 缓存
    import dependencies.internal_auth as auth_mod
    auth_mod._INTERNAL_SERVICE_TOKEN = None

    from main import app
    return TestClient(app)


@pytest.fixture
def auth_headers():
    """返回认证头。"""
    return {"Authorization": "Bearer test-token-jwc"}


class TestCompetitionCrawlEndpoint:
    """比赛通知爬虫端点测试。"""

    def test_no_token_returns_401(self, client):
        """无 Token → 401。"""
        resp = client.post(
            "/api/internal/campus/competition/crawl",
            json={"known_source_urls": [], "max_pages": 1, "reconcile": False},
        )
        assert resp.status_code == 401

    def test_wrong_token_returns_401(self, client):
        """错误 Token → 401。"""
        resp = client.post(
            "/api/internal/campus/competition/crawl",
            json={"known_source_urls": [], "max_pages": 1, "reconcile": False},
            headers={"Authorization": "Bearer wrong-token"},
        )
        assert resp.status_code == 401

    def test_known_urls_wrong_host_returns_422(self, client, auth_headers):
        """known_source_urls 包含非 cxcyxy 域名 → 422。"""
        resp = client.post(
            "/api/internal/campus/competition/crawl",
            json={
                "known_source_urls": [
                    "https://jwc.sylu.edu.cn/info/1089/123.htm"
                ],
                "max_pages": 1,
                "reconcile": False,
            },
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_known_urls_http_returns_422(self, client, auth_headers):
        """known_source_urls 包含 HTTP 协议 → 422。"""
        resp = client.post(
            "/api/internal/campus/competition/crawl",
            json={
                "known_source_urls": [
                    "http://cxcyxy.sylu.edu.cn/info/1089/123.htm"
                ],
                "max_pages": 1,
                "reconcile": False,
            },
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_max_pages_out_of_range_returns_422(self, client, auth_headers):
        """max_pages 超出范围 → 422。"""
        resp = client.post(
            "/api/internal/campus/competition/crawl",
            json={
                "known_source_urls": [],
                "max_pages": 10,
                "reconcile": False,
            },
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_route_registered(self, client):
        """路由已注册（OpenAPI schema 中存在）。"""
        resp = client.get("/openapi.json")
        assert resp.status_code == 200
        paths = resp.json().get("paths", {})
        assert "/api/internal/campus/competition/crawl" in paths
