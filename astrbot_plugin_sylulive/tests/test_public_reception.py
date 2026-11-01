"""开放接收时的匿名读取，与本人账号／私有分享权限保持独立。"""

import io
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from astrbot.api.provider import ProviderRequest
from astrbot.core.agent.tool import FunctionTool, ToolSet
from PIL import Image
from test_group_public_read import fixture
from test_meal_followup import meal_fixture
from test_private_review import setup

from astrbot_plugin_sylulive.private_review import ReviewProblem


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "group,sender", [("new-group", "other"), ("new-group", "owner"), ("", "other")]
)
async def test_open_public_reading_for_received_group_and_nonowner_private(
    group, sender
):
    plugin, event, calls = fixture(group=group, sender=sender)
    plugin.config["public_read_all_sessions"] = True
    assert plugin.allowed_reading(event) and not plugin.allowed(event)
    assert "sections" in json.loads(
        await plugin.tool(event, "GET", "/community/sections")
    )
    assert calls == [("GET", "/community/sections")]
    calls.clear()
    for path in ("/binding", "/me/checkin", "/me/public-posts", "/actions/synthetic"):
        assert (
            json.loads(await plugin.tool(event, "GET", path))["error"]
            == "permission_denied"
        )
    assert (
        json.loads(await plugin.tool(event, "POST", "/actions"))["error"]
        == "permission_denied"
    )
    assert calls == []


@pytest.mark.asyncio
async def test_public_mode_does_not_allow_other_platform_or_default_opening():
    plugin, event, _ = fixture(group="new-group")
    assert not plugin.allowed_reading(event)
    plugin.config["public_read_all_sessions"] = True
    _, other, _ = fixture(group="new-group", platform="other-platform")
    assert not plugin.allowed_reading(other)


@pytest.mark.asyncio
@pytest.mark.parametrize("group", ["new-group", ""])
async def test_new_public_sessions_receive_only_public_tools(group):
    plugin, event, _ = fixture(group=group, sender="other")
    plugin.config["public_read_all_sessions"] = True
    req = ProviderRequest(
        prompt="今天吃什么",
        func_tool=ToolSet(
            [
                FunctionTool(name=n, description="synthetic", parameters={})
                for n in (
                    "sylulive_eat_what",
                    "sylulive_canteen",
                    "sylulive_my_public_posts",
                    "sylulive_draft_reply",
                    "send_message_to_user",
                    "private_memory_search",
                )
            ]
        ),
    )
    await plugin.present_community_naturally(event, req)
    assert {t.name for t in req.func_tool.tools} == {
        "sylulive_eat_what",
        "sylulive_canteen",
    }


@pytest.mark.asyncio
async def test_open_public_group_is_not_a_private_share_target():
    plugin, event, _, review, _, send = setup()
    plugin.config["public_read_all_sessions"] = True
    event.message_obj.group_id = "new-group"
    assert plugin.allowed_public_group(event)
    with pytest.raises(ReviewProblem):
        await review.request(event, "account")
    plugin.client.call.assert_not_awaited()
    send.assert_not_awaited()


@pytest.mark.asyncio
async def test_denied_public_query_returns_human_error_not_invented_permission():
    plugin, event, _ = fixture(group="new-group")
    result = await plugin.food(event, "/api/canteens/rankings")
    assert result["error"] == "public_session_required"
    assert "message" in result and "不需要绑定" in result["message"]


@pytest.mark.asyncio
async def test_nonowner_private_public_reading_does_not_inherit_global_knowledge(
    monkeypatch,
):
    from astrbot.api import sp

    plugin, event, _ = fixture(group="", sender="other")
    plugin.config["public_read_all_sessions"] = True
    monkeypatch.setattr(
        sp, "session_get", AsyncMock(return_value={"kb_ids": ["private-owner-library"]})
    )
    write = AsyncMock()
    monkeypatch.setattr(sp, "session_put", write)
    await plugin.isolate_public_group_knowledge(event)
    write.assert_awaited_once_with(
        event.unified_msg_origin, "kb_config", {"kb_ids": []}
    )


@pytest.mark.asyncio
async def test_chinese_today_meal_alias_uses_real_native_command_filter():
    from astrbot.core.star.filter.command import CommandFilter
    from astrbot.core.star.star_handler import star_handlers_registry

    plugin, event, _ = fixture(group="new-group")
    plugin.config["public_read_all_sessions"] = True
    event.is_at_or_wake_command = True
    event.message_str = "今天吃什么"
    metadata = next(
        m
        for m in star_handlers_registry.star_handlers_map.values()
        if m.handler_name == "eat_command"
        and m.handler_module_path == "astrbot_plugin_sylulive.main"
    )
    command = next(f for f in metadata.event_filters if isinstance(f, CommandFilter))
    assert command.filter(event, {})
    plugin.client = SimpleNamespace(
        public_call=AsyncMock(return_value={"items": [{"id": 7, "name": "测试店"}]})
    )
    replies = [r async for r in plugin.eat_command(event)]
    assert replies and event.is_stopped()
    text = "".join(
        part.text for r in replies for part in r.chain if hasattr(part, "text")
    )
    assert "测试店" in text and "public_session_required" not in text


@pytest.mark.asyncio
@pytest.mark.parametrize("group", ["new-group", ""])
async def test_open_public_sessions_still_cannot_use_owner_checkin(group):
    plugin, event, _ = fixture(group=group, sender="other")
    plugin.config.update(public_read_all_sessions=True, allow_checkin=True)
    plugin.client = SimpleNamespace(tokens={"scope": "checkin:write"}, call=AsyncMock())
    assert "部署者尚未允许你在当前会话" in await plugin.checkin_result(event, submit=True)
    plugin.client.call.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "prompt",
    [
        "看看这家的图片，只给你看，不要发到群里",
        "这家评价怎么样，不要发图片",
        "这家图片私聊发我，别发群里",
    ],
)
async def test_explicit_no_group_image_blocks_prefetch_and_direct_send(prompt):
    plugin, event, _ = meal_fixture()
    await plugin.select_meal(event)
    _, follow, _ = fixture()
    follow.message_str = prompt
    follow.send = AsyncMock()
    raw = io.BytesIO()
    Image.new("RGB", (4, 4), "red").save(raw, format="PNG")
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    req = ProviderRequest(
        prompt=prompt,
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=follow.unified_msg_origin
        ),
    )
    await plugin.present_community_naturally(follow, req)
    follow.send.assert_not_awaited()
    assert len(req.image_urls) == 1
    assert "已发来" not in follow.get_extra("sylulive_food_caption", "")
    blocked = json.loads(
        await plugin.public_image(follow, "canteen", 119, send_to_chat=True)
    )
    assert blocked["error"] == "image_send_not_allowed"
    follow.send.assert_not_awaited()
