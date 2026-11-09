"""群签到的真实 SDK 入口；网络与校园账号写入均使用夹具。"""
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from test_group_public_read import fixture
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.main import PUBLIC_GROUP_TOOLS


def group_owner():
    plugin, event, _ = fixture(sender="owner")
    plugin.config["allow_checkin"] = True
    plugin.config["access_rules"] = [{
        "effect": "allow", "subjects": "everyone", "chat_types": ["group"],
        "group_ids": ["allowed-group"], "user_ids": [], "capabilities": ["checkin"],
    }]
    plugin.client = SimpleNamespace(
        tokens={"scope": "checkin:write"},
        call=AsyncMock(return_value={"data": {
            "already": False, "streak_days": 2, "exp_earned": 5,
            "check_in_date": "2026-11-02",
        }}),
    )
    return plugin, event


@pytest.mark.asyncio
async def test_owner_explicit_group_checkin_stops_default_model():
    plugin, event = group_owner()
    replies = [r async for r in plugin.daily_checkin(event)]
    assert len(replies) == 1 and "签到成功" in str(replies[0])
    plugin.client.call.assert_awaited_once_with("POST", "/me/checkin")
    assert event.is_stopped() and event.call_llm is True
    assert not plugin.allowed(event), "群签到不能开放其他私人模型工具"
    assert "sylulive_checkin_status" not in PUBLIC_GROUP_TOOLS


@pytest.mark.asyncio
async def test_group_status_command_is_readonly_but_model_cannot_read_it():
    plugin, event = group_owner()
    plugin.client.call.return_value = {"data": {
        "checked_in": True, "streak_days": 2, "check_in_date": "2026-11-02",
        "user_id": 987654, "total_exp": 999999,
    }}
    assert "不能由群模型代读" in await plugin.checkin_status(event)
    plugin.client.call.assert_not_called()
    result = await plugin.checkin_result(event, submit=False)
    plugin.client.call.assert_awaited_once_with("GET", "/me/checkin")
    assert "今天已签到" in result and "987654" not in result and "999999" not in result


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["disabled", "unbound", "readonly", "timeout", "repeat"])
async def test_group_checkin_preserves_consent_and_truthful_outcomes(case):
    plugin, event = group_owner()
    if case == "disabled":
        plugin.config["allow_checkin"] = False
    elif case == "unbound":
        plugin.client.tokens = None
    elif case == "readonly":
        plugin.client.tokens = {"scope": "community:read"}
        plugin.client.refresh_scope = AsyncMock(return_value="community:read")
    elif case == "timeout":
        plugin.client.call.side_effect = IntegrationProblem("network_unavailable")
    else:
        plugin.client.call.return_value["data"].update(already=True, exp_earned=0)
    result = await plugin.checkin_result(event, submit=True)
    expected = {"disabled": "尚未启用", "unbound": "尚未授权", "readonly": "没有签到权限",
                "timeout": "未能确认", "repeat": "不会重复领奖"}
    assert expected[case] in result and "签到成功" not in result
    if case in {"disabled", "unbound", "readonly"}:
        plugin.client.call.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("woken,text,expected", [
    (True, "签到", 1), (True, "帮我签到", 1),
    (False, "签到", 0), (True, "帖子里有人说签到", 0),
    (True, "替其他人签到", 0),
])
async def test_group_shortcuts_require_explicit_self_request(woken, text, expected):
    plugin, event = group_owner()
    event.is_at_or_wake_command, event.message_str = woken, text
    replies = [r async for r in plugin.daily_shortcuts(event)]
    assert len(replies) == expected and plugin.client.call.await_count == expected
