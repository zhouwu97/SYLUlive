"""教务聚合路由注册回归测试。"""

from main import create_app


def test_context_bundle_route_is_registered() -> None:
    """主应用必须公开聚合入口，避免部署后把上游 404 映射为主服务 502。"""

    app = create_app(retired=False)
    assert any(
        route.path == "/api/edu/context-bundle" and "POST" in route.methods
        for route in app.routes
    )
