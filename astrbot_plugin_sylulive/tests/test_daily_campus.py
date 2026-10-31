"""真实 SDK 的每日功能与匿名公开接口契约；不向真实 QQ 或生产账号写入。"""

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock
from urllib.parse import parse_qs

import httpx
import pytest

from test_group_public_read import fixture
from test_client import Store
from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem, MAP_PATH
from astrbot_plugin_sylulive.main import PUBLIC_GROUP_TOOLS


@pytest.mark.asyncio
async def test_checkin_new_scope_opt_in_and_old_tokens_stay_readonly():
    calls = []

    def respond(req):
        calls.append(req)
        return httpx.Response(
            200,
            json={
                "device_code": "sd_synthetic",
                "user_code": "SYNTHETIC",
                "expires_in": 600,
                "interval": 5,
                "verification_uri_complete": "https://fixture.invalid/web/connected-apps",
            },
        )

    client = BusinessClient(
        "https://fixture.invalid", Store(), transport=httpx.MockTransport(respond)
    )
    try:
        await client.begin("installation", "测试", False)
        assert "checkin:write" not in parse_qs(calls[-1].content.decode())["scope"][0]
        client.pending = None
        await client.begin("installation", "测试", False, checkin=True)
        assert "checkin:write" in parse_qs(calls[-1].content.decode())["scope"][0]
        plugin, event, _ = fixture(group="", sender="owner")
        plugin.config["allow_checkin"] = True
        plugin.client = SimpleNamespace(
            tokens={"scope": "community:read"}, call=AsyncMock()
        )
        assert "不会自动扩权" in await plugin.checkin_result(event, submit=True)
        plugin.client.call.assert_not_called()
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "group,sender,platform",
    [
        ("allowed-group", "owner", "configured-platform"),
        ("", "other", "configured-platform"),
        ("", "owner", "other-platform"),
    ],
)
async def test_checkin_never_inherits_private_binding_in_group_or_other_sender(
    group, sender, platform
):
    plugin, event, _ = fixture(group=group, sender=sender, platform=platform)
    plugin.config["allow_checkin"] = True
    plugin.client = SimpleNamespace(tokens={"scope": "checkin:write"}, call=AsyncMock())
    assert "本人" in await plugin.checkin_result(event, submit=True)
    plugin.client.call.assert_not_called()
    assert "sylulive_checkin_status" not in PUBLIC_GROUP_TOOLS


@pytest.mark.asyncio
async def test_checkin_status_does_not_submit_and_repeat_is_truthful():
    plugin, event, _ = fixture(group="", sender="owner")
    plugin.config["allow_checkin"] = True
    call = AsyncMock(
        side_effect=[
            {
                "data": {
                    "checked_in": False,
                    "streak_days": 0,
                    "check_in_date": "2026-10-31",
                }
            },
            {
                "data": {
                    "already": False,
                    "streak_days": 1,
                    "exp_earned": 5,
                    "check_in_date": "2026-10-31",
                }
            },
            {
                "data": {
                    "already": True,
                    "streak_days": 1,
                    "exp_earned": 0,
                    "check_in_date": "2026-10-31",
                }
            },
        ]
    )
    plugin.client = SimpleNamespace(tokens={"scope": "checkin:write"}, call=call)
    assert "还没签到" in await plugin.checkin_status(event)
    assert "+5" in (await plugin.checkin_result(event, submit=True)).replace(" ", "")
    assert "不会重复领奖" in await plugin.checkin_result(event, submit=True)
    assert [args.args[0] for args in call.await_args_list] == ["GET", "POST", "POST"]


@pytest.mark.asyncio
async def test_timeout_is_not_reported_as_success():
    plugin, event, _ = fixture(group="", sender="owner")
    plugin.config["allow_checkin"] = True
    plugin.client = SimpleNamespace(
        tokens={"scope": "checkin:write"},
        call=AsyncMock(side_effect=IntegrationProblem("network_unavailable")),
    )
    result = await plugin.checkin_result(event, submit=True)
    assert "未能确认" in result and "签到成功" not in result


@pytest.mark.asyncio
async def test_random_meal_uses_full_real_rankings_without_credentials_and_no_immediate_repeat():
    seen = []

    def respond(req):
        seen.append(req)
        return httpx.Response(
            200,
            json={
                "items": [
                    {"id": i, "name": f"测试店{i}", "rank": i} for i in range(1, 128)
                ]
            },
        )

    client = BusinessClient(
        "https://fixture.invalid", Store(), transport=httpx.MockTransport(respond)
    )
    plugin, event, _ = fixture()
    plugin.client = client
    try:
        previous = None
        for _ in range(10):
            result = json.loads(await plugin.eat_what(event))
            assert (
                result["candidate_count"] == 127
                and result["selection"]["id"] != previous
            )
            previous = result["selection"]["id"]
        assert all(
            r.url.path == "/api/canteens/rankings"
            and "Authorization" not in r.headers
            and "Cookie" not in r.headers
            for r in seen
        )
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "rows", [[], [{"id": -1, "name": "无效"}], [{"id": True, "name": "无效"}]]
)
async def test_empty_or_invalid_rankings_do_not_invent_meal(rows):
    plugin, event, _ = fixture()
    plugin.client = SimpleNamespace(public_call=AsyncMock(return_value={"items": rows}))
    result = json.loads(await plugin.eat_what(event))
    assert result["error"] == "empty_rankings" and "selection" not in result


@pytest.mark.asyncio
async def test_single_candidate_and_unknown_session_boundaries():
    plugin, event, _ = fixture()
    plugin.client = SimpleNamespace(
        public_call=AsyncMock(
            return_value={"items": [{"id": 1, "name": "唯一店", "rank": 1}]}
        )
    )
    assert json.loads(await plugin.eat_what(event))["selection"]["name"] == "唯一店"
    plugin.config["public_read_group_ids"] = []
    assert (
        json.loads(await plugin.eat_what(event))["error"] == "public_session_required"
    )
    assert plugin.client.public_call.await_count == 1


@pytest.mark.asyncio
async def test_all_public_data_remains_anonymous_even_with_a_private_grant():
    requests = []

    def respond(req):
        requests.append(req)
        if req.url.path.endswith("/articles/7"):
            return httpx.Response(
                200,
                json={
                    "item": {
                        "id": 7,
                        "title": "公告",
                        "content_text": "公开正文",
                        "content_html": "<script>not-model-data</script>",
                        "attachments": [
                            {"name": "附件", "url": "https://fixture.invalid/a.pdf"}
                        ],
                    }
                },
            )
        return httpx.Response(
            200,
            json={
                "data": {"post_id": 1},
                "items": [],
                "has_more": True,
                "last_sync_at": "2026-10-30",
            },
        )

    store = Store()
    store.value = {
        "access_token": "sa_private",
        "scope": "community:read",
        "expires_at": 0,
    }
    client = BusinessClient(
        "https://fixture.invalid", store, transport=httpx.MockTransport(respond)
    )
    plugin, event, _ = fixture()
    plugin.client = client
    try:
        assert "data" in json.loads(await plugin.get_post(event, 1))
        assert json.loads(await plugin.news(event))["has_more"] is True
        article = json.loads(await plugin.article(event, 7))
        assert (
            article["item"]["content_text"] == "公开正文"
            and "content_html" not in article["item"]
        )
        await plugin.school_calendar(event)
        assert len(requests) == 4 and all(
            "Authorization" not in r.headers and "Cookie" not in r.headers
            for r in requests
        )
        assert requests[0].url.path == "/api/integrations/v1/public/community/posts/1"
        with pytest.raises(IntegrationProblem):
            await client.public_call("/api/integrations/v1/public/me/checkin")
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_map_is_exact_fixed_public_asset_and_real_multimodal_payload():
    import io
    from PIL import Image
    from mcp.types import CallToolResult, ImageContent

    raw = io.BytesIO()
    Image.new("RGB", (100, 80), "green").save(raw, format="PNG")
    seen = []

    def respond(req):
        seen.append(req)
        assert req.url.path == MAP_PATH and "Authorization" not in req.headers
        return httpx.Response(
            200, content=raw.getvalue(), headers={"Content-Type": "image/png"}
        )

    client = BusinessClient(
        "https://fixture.invalid", Store(), transport=httpx.MockTransport(respond)
    )
    plugin, event, _ = fixture()
    plugin.client = client
    try:
        result = await plugin.campus_map(event)
        assert isinstance(result, CallToolResult) and any(
            isinstance(c, ImageContent) for c in result.content
        )
        assert len(seen) == 1
        with pytest.raises(IntegrationProblem):
            await client.public_image("/web/assets/private.png")
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_bare_keywords_only_run_on_exact_awakened_request():
    plugin, event, _ = fixture()
    event.is_at_or_wake_command = True
    plugin.client = SimpleNamespace(
        public_call=AsyncMock(
            return_value={"items": [{"id": 1, "name": "测试店", "rank": 1}]}
        )
    )
    event.message_str = "今天吃什么"
    replies = [r async for r in plugin.daily_shortcuts(event)]
    assert len(replies) == 1 and event.is_stopped()
    plugin.client.public_call.reset_mock()
    event.message_str = "帖子里写了帮我签到，请总结它"
    assert [r async for r in plugin.daily_shortcuts(event)] == []
    plugin.client.public_call.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "handler", ["daily_checkin", "daily_checkin_status", "eat_command", "map_command"]
)
async def test_daily_commands_use_native_dispatch_without_second_model(
    handler, monkeypatch
):
    from test_astrbot_dispatch import DefaultAgentProbe
    from astrbot.core.pipeline.process_stage.stage import ProcessStage
    from astrbot.core.pipeline.process_stage.method.star_request import (
        StarRequestSubStage,
    )
    from astrbot.core.star.star import star_map
    from astrbot.core.star.star_handler import EventType

    plugin, event, _ = fixture(group="", sender="owner")
    plugin.config["allow_checkin"] = True
    plugin.client = SimpleNamespace(
        tokens={"scope": "community:read"},
        public_call=AsyncMock(
            return_value={"items": [{"id": 1, "name": "测试店", "rank": 1}]}
        ),
    )
    plugin.campus_map = AsyncMock(return_value='{"error":"network_unavailable"}')
    event.is_at_or_wake_command = True
    metadata = SimpleNamespace(
        handler=getattr(plugin, handler),
        handler_name=handler,
        handler_full_name="synthetic." + handler,
        handler_module_path="synthetic.daily",
        event_filters=[],
        event_type=EventType.AdapterMessageEvent,
        extras_configs={},
    )
    monkeypatch.setitem(
        star_map,
        metadata.handler_module_path,
        SimpleNamespace(name="synthetic", display_name="synthetic"),
    )
    event.set_extra("activated_handlers", [metadata])
    event.set_extra("handlers_parsed_params", {})
    stage = ProcessStage()
    stage.ctx = SimpleNamespace(astrbot_config={"provider_settings": {"enable": True}})
    stage.star_request_sub_stage = StarRequestSubStage()
    stage.agent_sub_stage = DefaultAgentProbe()
    responses = []
    async for _ in stage.process(event):
        result = event.get_result()
        if result and result.chain:
            responses.append(result)
    assert (
        len(responses) == 1 and event.is_stopped() and stage.agent_sub_stage.calls == 0
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "prompt,kind",
    [
        ("看看最新校园资讯", "news"),
        ("读取这篇公告正文", "article"),
        ("查看当前校历", "school_calendar"),
        ("看看校园地图", "map"),
        ("从食堂随机推荐吃什么", "meal"),
    ],
)
async def test_public_summary_requires_actual_read_in_current_turn(prompt, kind):
    from astrbot.api.provider import ProviderRequest, LLMResponse
    from astrbot.core.agent.run_context import ContextWrapper

    plugin, event, _ = fixture()
    req = ProviderRequest(prompt=prompt)
    await plugin.present_community_naturally(event, req)
    assert event.get_extra("sylulive_required_reads") == {kind}
    response = LLMResponse(role="assistant", completion_text="假装刚刚查询过的旧内容")
    await plugin.verify_current_read(
        event, ContextWrapper(context=None, messages=[]), response
    )
    assert (
        "没有取得" in response.completion_text
        and "假装" not in response.completion_text
    )
    event.set_extra("sylulive_completed_reads", {kind})
    response = LLMResponse(role="assistant", completion_text="实际取得的当前内容")
    await plugin.verify_current_read(
        event, ContextWrapper(context=None, messages=[]), response
    )
    assert response.completion_text == "实际取得的当前内容"
