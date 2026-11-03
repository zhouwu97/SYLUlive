import copy
import json
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import jwt
import pytest
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from astrbot.dashboard.api.plugins import legacy_router
from astrbot.dashboard.responses import ApiError
from astrbot_plugin_sylulive.permission_console import parse_target, preview, register_console
from test_group_public_read import fixture


def console_fixture():
    plugin, event, _ = fixture(sender="900000002", group="700000001", platform="snowluma")
    plugin.owner, plugin.platform = "900000001", "snowluma"
    plugin.config.update(community_agent_enabled=True, allow_multi_user=True,
                         public_read_all_sessions=True, allow_personal_queries=True,
                         public_read_group_ids=["700000001"], access_rules=[{
                             "name": "合成本人查询", "effect": "allow", "subjects": "everyone",
                             "chat_types": ["group"], "group_ids": ["700000001"],
                             "capabilities": ["grades", "erke"]}])
    plugin.context = SimpleNamespace(get_config=lambda **kwargs: {"admins_id": ["900000001"]})
    client = SimpleNamespace(tokens={"scope": "academic:grades:read", "expires_at": time.time()-1,
                                    "access_token": "SYNTHETIC-ACCESS-DO-NOT-RETURN",
                                    "refresh_token": "SYNTHETIC-REFRESH-DO-NOT-RETURN"},
                             pending=None, call=AsyncMock())
    plugin.client = SimpleNamespace(tokens=None, pending=None, call=AsyncMock())
    plugin.accounts = SimpleNamespace(entries={("800000001", "900000002"): (client, "not-public-installation")})
    target = {"platform_id": "snowluma", "bot_id": "800000001", "sender_id": "900000002", "group_id": "700000001"}
    return plugin, target, client


def native_app(plugin):
    routes = []
    register_console(SimpleNamespace(register_web_api=lambda *args: routes.append(args)), plugin)
    app = FastAPI()
    app.state.jwt_secret = "synthetic-dashboard-secret-at-least-thirty-two-bytes"
    app.state.core_lifecycle = SimpleNamespace(star_context=SimpleNamespace(registered_web_apis=routes))
    # The actual SDK route retains require_dashboard_user; never override its dependency.
    app.router.routes.append(next(r for r in legacy_router.routes if r.name == "dashboard_plugin_extension_route"))
    @app.exception_handler(ApiError)
    async def failed(_, exc):
        return JSONResponse({"error": exc.message}, status_code=exc.status_code)
    return app


def test_preview_uses_actual_policy_and_never_returns_or_uses_credentials():
    plugin, target, client = console_fixture()
    before = copy.deepcopy(plugin.config)
    result = preview(plugin, target)
    items = {r["action"]:r for r in result["items"]}
    assert items["grades"]["state"] == "server_check_required"
    assert items["erke"]["state"] == "scope_required"
    assert items["public_read"]["state"] == "public_allowed"
    assert result["is_admin"] is False and result["grant"]["access_expired"] is True
    assert plugin.config == before
    assert "SYNTHETIC-ACCESS" not in json.dumps(result) and "refresh_token" not in json.dumps(result)
    client.call.assert_not_called()
    plugin.client.call.assert_not_called()
    plugin.config["access_rules"].append({"effect":"deny","subjects":"everyone","chat_types":["group"],"capabilities":["public_read"]})
    assert next(r for r in preview(plugin,target)["items"] if r["action"]=="public_read")["state"] == "denied"


@pytest.mark.parametrize("change", [{"is_admin":True},{"target_user_id":1},{"scope":"*"},{"sender_id":"../secret"},{"bot_id":""},{"group_id":"-123"},{"platform_id":"https://example.org"},{"member_isolated":"true"}])
def test_preview_rejects_extra_authority_and_malformed_context(change):
    _, target, _ = console_fixture()
    with pytest.raises(ValueError): parse_target(target | change)


def test_preview_does_not_create_installations_or_clients(tmp_path):
    plugin,target,_ = console_fixture()
    plugin.accounts = SimpleNamespace(entries={},directory=tmp_path,origin="https://fixture.invalid",platform="snowluma")
    assert preview(plugin,target)["grant"]["state"] == "not_loaded"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.asyncio
async def test_real_native_dashboard_route_requires_login_and_returns_metadata_only():
    plugin,target,client = console_fixture();app=native_app(plugin)
    path="/api/plug/astrbot_plugin_sylulive/permissions/preview"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url="http://test") as h:
        assert (await h.post(path,json=target)).status_code==401
        assert (await h.post(path,json=target,headers={"Authorization":"ApiKey synthetic-key"})).status_code==401
        token=jwt.encode({"username":"synthetic-admin","exp":time.time()+60},app.state.jwt_secret,algorithm="HS256")
        h.headers["Authorization"]="Bearer "+token
        r=await h.post(path,json=target)
        assert r.status_code==200 and r.headers["cache-control"]=="no-store"
        assert r.json()["grant"]["scopes"]==["academic:grades:read"]
        assert (await h.post(path,json=target|{"scope":"*"})).status_code==422
        assert (await h.post(path,content=b"x"*262145)).status_code==413
        status=await h.get("/api/plug/astrbot_plugin_sylulive/permissions/status")
        assert status.status_code==200 and status.json()["version"]=="0.5.0"
        assert "runtime" not in status.json() and "persona" not in status.json()
        plugin._console_active=False
        assert (await h.post(path,json=target)).status_code==503
        expired=jwt.encode({"username":"synthetic-admin","exp":time.time()-60},app.state.jwt_secret,algorithm="HS256")
        assert (await h.post(path,json=target,headers={"Authorization":"Bearer "+expired})).status_code==401
    client.call.assert_not_called()


def test_native_auth_rejects_scoped_page_asset_token_on_console_api():
    from astrbot.dashboard.server import AstrBotDashboard
    dashboard=AstrBotDashboard.__new__(AstrBotDashboard)
    dashboard._jwt_secret="synthetic-dashboard-secret-at-least-thirty-two-bytes"
    token=jwt.encode({"username":"synthetic-admin","token_type":"plugin_page_asset",
                      "plugin_name":"astrbot_plugin_sylulive","page_name":"permissions",
                      "exp":time.time()+60},dashboard._jwt_secret,algorithm="HS256")
    payload,_=dashboard._validate_dashboard_token(token,"/api/plug/astrbot_plugin_sylulive/permissions/status")
    assert payload is None, "静态页面资源凭据不能扩为后台诊断 API 权限"


@pytest.mark.asyncio
async def test_native_plugin_page_discovery_finds_index_and_local_assets():
    from astrbot.core.star.star import StarMetadata
    from astrbot.dashboard.services.plugin_page_service import PluginPageService
    root=Path(__file__).resolve().parents[1]
    manager=SimpleNamespace(plugin_store_path=str(root.parent),reserved_plugin_path=str(root.parent))
    service=PluginPageService(manager)
    meta=StarMetadata(name="astrbot_plugin_sylulive",root_dir_name="astrbot_plugin_sylulive")
    assert "permissions" in {p.name for p in await service.discover_plugin_pages(meta)}
    for asset in ("", "app.css", "app.js"):
        resolved=await service.resolve_plugin_page_file(meta,"permissions",asset)
        assert resolved.is_file()


@pytest.mark.asyncio
async def test_public_tools_and_current_chat_memes_survive_both_persona_filters(tmp_path):
    from astrbot.api.provider import ProviderRequest
    from astrbot.core.agent.tool import FunctionTool,ToolSet
    from astrbot_plugin_sylulive.public_agent import PublicAgent,PublicMemory
    plugin,event,_=fixture()
    plugin.config.update(community_agent_enabled=True,community_chat_memes_enabled=True,
                         allow_personal_queries=True,access_rules=[{"effect":"allow","subjects":"everyone","chat_types":["group"],"capabilities":["grades"]}])
    plugin.public_agent=PublicAgent(plugin.config,plugin.client.public_call,PublicMemory(tmp_path/'public.sqlite3'))
    names=["sylulive_canteens","sylulive_eat_what","sylulive_canteen","sylulive_campus_map","sylulive_public_image","sylulive_news","sylulive_school_calendar","sylulive_checkin_status","get_group_message_history","run_shell","private_memory"]
    tools=[FunctionTool(name=n,description="synthetic",parameters={}) for n in names]
    for name in ["search_meme","send_meme"]:
        tools.append(FunctionTool(name=name,description="synthetic",parameters={"type":"object","properties":{"emoji_id": {"type":"string"}} if name=="send_meme" else {"query":{"type":"string"}}},handler_module_path="data.plugins.astrbot_plugin_stealer.main"))
    request=ProviderRequest(prompt="今天吃什么",system_prompt="PRIVATE",contexts=[{"role":"user","content":"PRIVATE"}],func_tool=ToolSet(tools))
    await plugin.present_community_naturally(event,request)
    kept={t.name for t in request.func_tool.tools}
    assert {"sylulive_canteens","sylulive_eat_what","sylulive_public_image","sylulive_campus_map","sylulive_news","search_meme","send_meme"} <= kept
    assert not {"sylulive_checkin_status","get_group_message_history","run_shell","private_memory"} & kept
    assert "[当前聊天表情]" in request.system_prompt and request.contexts==[]
    assert "[当前会话本人命令权限]" in request.system_prompt and "/sylu-grades已允许" in request.system_prompt
    await plugin.public_agent.close()
