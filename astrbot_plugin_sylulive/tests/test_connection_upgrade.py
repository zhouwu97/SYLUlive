import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem
from astrbot_plugin_sylulive.binding_notifications import BindingNotifications
from test_client import Store, tokens


def flow_response(request, *, outcome="approved"):
    if request.url.path.endswith("device_authorization"):
        return httpx.Response(200, json={"device_code":"sd_synthetic_upgrade", "user_code":"UPGD-1234",
            "expires_in":600, "interval":5,
            "verification_uri_complete":"https://fixture.invalid/web/connected-apps?user_code=UPGD-1234"})
    if request.url.path.endswith("/token"):
        if outcome == "denied":
            return httpx.Response(400, json={"error":"access_denied"})
        return httpx.Response(200, json={**tokens(), "access_token":"sa_upgrade", "refresh_token":"sr_upgrade",
            "scope":"profile:read_minimal community:read actions:read_own community:propose community:bot_post"})
    return httpx.Response(200, json={"ok":True})


@pytest.mark.asyncio
@pytest.mark.parametrize("options,missing", [
    ({"checkin": True}, {"checkin:write"}),
    ({"personal": True}, {"academic:grades:read", "academic:erke:read"}),
    ({"proposals": True}, {"community:propose"}),
])
async def test_existing_readonly_connection_requests_missing_non_bot_permissions(options, missing):
    from urllib.parse import parse_qs
    requests = []
    def respond(request):
        requests.append(request)
        return flow_response(request)
    client = BusinessClient("https://fixture.invalid", Store(), transport=httpx.MockTransport(respond))
    client._save({**tokens(), "scope": "profile:read_minimal content:read_own_public actions:read_own community:read"})
    old = client.tokens.copy()
    try:
        result = await client.begin("synthetic-installation", "合成安装", options.get("proposals", False),
                                    **{key: value for key, value in options.items() if key != "proposals"})
        assert result["upgrade"] and result["user_code"] == "UPGD-1234"
        requested = set(parse_qs(requests[0].content.decode())["scope"][0].split())
        assert missing.issubset(requested)
        assert "community:bot_reply" not in requested and "community:bot_post" not in requested
        assert client.tokens == old and client.store.value == old
        assert len(requests) == 1 and requests[0].url.path == "/api/oauth/device_authorization"
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_group_readonly_checkin_connect_approve_then_checkin_uses_only_sender():
    from test_multiuser_group_checkin import multiuser_group
    plugin, event, owner, _ = multiuser_group()
    plugin.origin = "https://fixture.invalid"
    requests = []
    granted = ["community:read"]  # 服务端当前实际范围，批准后才加入 checkin:write
    def respond(request):
        requests.append(request)
        if request.url.path.endswith("/token"):
            return httpx.Response(200, json={**tokens(), "scope": granted[0]})
        if request.url.path.endswith("/me/checkin"):
            return httpx.Response(200, json={"data": {"already": False, "streak_days": 1,
                "exp_earned": 5, "check_in_date": "2026-11-05"}})
        return flow_response(request)
    client = BusinessClient(plugin.origin, Store(), transport=httpx.MockTransport(respond))
    client._save(tokens())
    plugin.accounts = SimpleNamespace(get=lambda *args, **kwargs: (client, "synthetic-installation"))
    plugin.track_binding_result = lambda *args: "合成通知"
    plugin.config["binding_link_delivery"] = "group"
    try:
        assert "没有签到权限" in await plugin.checkin_result(event, submit=True)
        # 本地缺 scope 时只向服务端核对一次最新授权，核对期间不得代发签到请求。
        assert any(r.url.path.endswith("/token") for r in requests)
        assert not any(r.url.path.endswith("/me/checkin") for r in requests)
        replies = [r async for r in plugin.connect(event)]
        text = "".join(part.text for reply in replies for part in reply.chain if hasattr(part, "text"))
        assert "UPGD-1234" in text and "权限更新" in text
        assert "checkin:write" not in client.tokens["scope"]
        assert not any(r.url.path.endswith("/me/checkin") for r in requests)
        granted[0] = "community:read checkin:write"  # 官网批准后的服务端授权状态
        client.pending["next"] = 0
        await client.poll()
        assert "签到成功" in await plugin.checkin_result(event, submit=True)
        assert sum(r.url.path.endswith("/me/checkin") for r in requests) == 1
        owner.call.assert_not_called()
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("checkin", [False, True])
async def test_sufficient_permissions_do_not_create_device_request(checkin):
    requests = []
    client = BusinessClient("https://fixture.invalid", Store(), transport=httpx.MockTransport(
        lambda r: requests.append(r) or flow_response(r)))
    client._save({**tokens(), "scope": "profile:read_minimal content:read_own_public actions:read_own checkin:write"})
    try:
        with pytest.raises(IntegrationProblem, match="already_connected"):
            await client.begin("synthetic-installation", "合成安装", False, checkin=checkin)
        assert not requests and client.pending is None
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_first_checkin_query_can_finish_initial_authorization_without_false_account_change():
    from test_multiuser_group_checkin import multiuser_group
    plugin,event,owner,_=multiuser_group();requests=[]
    def respond(request):
        requests.append(request.url.path)
        if request.url.path.endswith('/token'):
            return httpx.Response(200,json={**tokens(),'scope':'checkin:write'})
        if request.url.path.endswith('/me/checkin'):
            return httpx.Response(200,json={'data':{'checked_in':False,'streak_days':0,'check_in_date':'2026-11-03'}})
        return flow_response(request)
    client=BusinessClient('https://fixture.invalid',Store(),transport=httpx.MockTransport(respond))
    plugin.accounts=SimpleNamespace(get=lambda *a,**k:(client,'synthetic-installation'))
    try:
        await client.begin('synthetic-installation','合成安装',False,checkin=True)
        client.pending['next']=0
        result=await plugin.checkin_result(event,submit=False)
        assert '权限或账号连接已变化' not in result
        assert requests.count('/api/integrations/v1/me/checkin')==1
        owner.call.assert_not_called()
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_existing_connection_can_request_bot_permission_without_revoking_old_grant():
    requests=[]
    def respond(request):
        requests.append(request)
        return flow_response(request)
    client=BusinessClient("https://fixture.invalid",Store(),transport=httpx.MockTransport(respond))
    client._save(tokens());old=client.tokens.copy();generation=client.generation
    try:
        result=await client.begin("synthetic-installation","合成安装",False,bot_post=True)
        assert result["user_code"]=="UPGD-1234"
        assert client.tokens==old and client.store.value==old
        assert client.generation>generation
        assert not any(r.url.path.endswith("/revoke") for r in requests)
        with pytest.raises(IntegrationProblem,match="authorization_pending"):
            await client.call("GET","/binding")
        client.pending["next"]=0
        await client.poll()
        assert client.tokens["access_token"]=="sa_upgrade" and client.pending is None
        assert await client.call("GET","/binding")=={"ok":True}
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("options,scope", [({"bot_post": True}, "community:bot_post"), ({"checkin": True}, "checkin:write")])
async def test_upgrade_denial_keeps_previous_connection_usable_without_granting_new_scope(options, scope):
    client=BusinessClient("https://fixture.invalid",Store(),transport=httpx.MockTransport(lambda r:flow_response(r,outcome="denied")))
    client._save(tokens());old=client.tokens.copy()
    try:
        await client.begin("synthetic-installation","合成安装",False,**options)
        client.pending["next"]=0
        with pytest.raises(IntegrationProblem,match="access_denied"):
            await client.poll()
        assert client.tokens==old and scope not in client.tokens["scope"]
        assert await client.call("GET","/binding")=={"ok":True}
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_upgrading_connection_invalidates_inflight_old_results_and_notifies_once():
    started,release=asyncio.Event(),asyncio.Event()
    async def respond(request):
        if request.url.path.endswith("/binding"):
            started.set();await release.wait()
        return flow_response(request)
    client=BusinessClient("https://fixture.invalid",Store(),transport=httpx.MockTransport(respond))
    client._save(tokens());notify=AsyncMock(return_value=True)
    notices=BindingNotifications(notify,lambda _:True)
    try:
        old=asyncio.create_task(client.call("GET","/binding"));await started.wait()
        await client.begin("synthetic-installation","合成安装",False,bot_post=True)
        client.pending["next"]=0
        assert notices.start(client,object())
        await notices.tasks[client]
        release.set()
        with pytest.raises(IntegrationProblem,match="authorization_changed"):
            await old
        assert notify.await_count==1 and notify.await_args.args[1]=="success"
    finally:
        release.set();await notices.close();await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("cancel_ok",[True,False])
@pytest.mark.parametrize("options", [{"bot_post": True}, {"checkin": True}])
@pytest.mark.parametrize("terminal", [False, True])
async def test_expired_request_is_cancelled_before_renewal_without_revoking_connection(cancel_ok, options, terminal):
    requests=[]
    def respond(request):
        requests.append(request)
        if request.url.path.endswith("/cancel") and not cancel_ok:
            return httpx.Response(503,json={"error":"service_unavailable"})
        return flow_response(request)
    client=BusinessClient("https://fixture.invalid",Store(),transport=httpx.MockTransport(respond))
    client._save(tokens());old=client.tokens.copy()
    import time
    pending={"device_code":"sd_expired_synthetic","deadline":time.monotonic()+600 if terminal else 0, "terminal":terminal}
    client.pending=pending
    try:
        if cancel_ok:
            await client.begin("synthetic-installation","合成安装",False,**options)
            assert client.pending is not pending
            assert [r.url.path for r in requests]==["/api/oauth/device_authorization/cancel","/api/oauth/device_authorization"]
        else:
            with pytest.raises(IntegrationProblem,match="service_unavailable"):
                await client.begin("synthetic-installation","合成安装",False,**options)
            assert client.pending is pending and len(requests)==1
        assert client.tokens==old
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("allowed,listed,multi,expected",[(True,True,True,True),(True,False,True,False),(False,True,True,None),(True,True,False,False)])
async def test_only_explicit_group_and_real_sender_can_request_own_bot_scopes(allowed,listed,multi,expected):
    from test_multiuser_group_checkin import multiuser_group
    plugin,event,owner,own=multiuser_group();plugin.origin="https://fixture.invalid"
    plugin.config.update(community_multi_user_runtime_enabled=multi,community_auto_comment=True,community_auto_post=True,
                         community_bot_authorization_group_ids=["666666"] if listed else [])
    if not allowed:plugin.config["access_rules"][0]["effect"]="deny"
    own.begin=AsyncMock(return_value={"user_code":"UPGD-1234","verification_uri":"https://fixture.invalid/web/connected-apps?user_code=UPGD-1234"})
    plugin.track_binding_result=lambda *args:"合成通知"
    replies=[r async for r in plugin.connect(event)]
    assert replies
    if expected is None:own.begin.assert_not_called()
    else:
        assert own.begin.await_count==1
        for key in ("community_read","bot_reply","bot_post"):
            assert own.begin.await_args.kwargs[key] is expected
    owner.call.assert_not_called()
