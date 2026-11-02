"""多用户群签到回归；真实 SDK 事件，所有校园请求均用夹具。"""
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")

from test_group_public_read import fixture
from astrbot_plugin_sylulive.client import IntegrationProblem


def multiuser_group():
    plugin, event, _ = fixture(sender="222222", group="666666")
    plugin.config.update(
        community_agent_enabled=True, allow_multi_user=True, allow_group_binding=True,
        allow_checkin=True, public_read_group_ids=["666666"], access_default="inherit",
        access_rules=[{"effect": "allow", "subjects": "everyone", "chat_types": ["group"],
                       "group_ids": ["666666"], "user_ids": [],
                       "capabilities": ["bind", "status", "unbind", "checkin"]}],
    )
    plugin.is_bot_admin = lambda _: False
    owner = SimpleNamespace(tokens={"scope": "checkin:write"}, call=AsyncMock())
    own = SimpleNamespace(tokens={"scope": "checkin:write"}, pending=None, generation=1,
                          call=AsyncMock(return_value={"data": {"already": False,
                              "streak_days": 1, "exp_earned": 5, "check_in_date": "2026-11-02"}}))
    plugin.client = owner
    plugin.accounts = SimpleNamespace(get=lambda actor, bot, create=False: (own, "own-installation"))
    return plugin, event, owner, own


@pytest.mark.asyncio
async def test_group_checkin_uses_real_sender_account_never_owner():
    plugin, event, owner, own = multiuser_group()
    selected = []
    def get(actor, bot, create=False):
        selected.append((actor, bot, create))
        return own, "own-installation"
    plugin.accounts.get = get
    for action in ("bind", "status", "unbind", "checkin"):
        assert plugin.permission(event, action).allowed
    assert "签到成功" in await plugin.checkin_result(event, submit=True)
    assert selected == [("222222", "synthetic-bot", False)]
    own.call.assert_awaited_once_with("POST", "/me/checkin")
    owner.call.assert_not_called()
    for action in ("grades", "erke", "proposals", "private_review"):
        assert not plugin.permission(event, action).allowed
    assert not plugin.allowed(event)


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["other_group", "other_platform", "denied", "not_allowed", "disabled", "unbound", "readonly"])
async def test_group_checkin_fails_closed_without_falling_back_to_owner(case):
    plugin, event, owner, own = multiuser_group()
    if case == "other_group":
        event.message_obj.group_id = "777777"
    elif case == "other_platform":
        event.get_platform_id = lambda: "other-platform"
    elif case == "denied":
        plugin.config["access_rules"].append(dict(plugin.config["access_rules"][0], effect="deny"))
    elif case == "not_allowed":
        plugin.config["access_rules"] = []
        plugin.config["access_default"] = "deny"
    elif case == "disabled":
        plugin.config["allow_checkin"] = False
    elif case == "unbound":
        def missing(*args, **kwargs):
            raise IntegrationProblem("connect_first")
        plugin.accounts.get = missing
    elif case == "readonly":
        own.tokens = {"scope": "community:read"}
    result = await plugin.checkin_result(event, submit=True)
    assert result and "签到成功" not in result
    own.call.assert_not_called()
    owner.call.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["permission", "account"])
async def test_pending_authorization_rechecks_permission_and_account_before_submit(change):
    plugin, event, owner, own = multiuser_group()
    own.pending = object()
    async def poll():
        if change == "permission":
            plugin.config["access_rules"] = []
        else:
            own.generation += 1
    own.poll = poll
    assert "已变化" in await plugin.checkin_result(event, submit=True)
    own.call.assert_not_called()
    owner.call.assert_not_called()


@pytest.mark.asyncio
async def test_group_model_cannot_query_private_checkin_status():
    plugin, event, owner, own = multiuser_group()
    assert "不能由群模型代读" in await plugin.checkin_status(event)
    own.call.assert_not_called()
    owner.call.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("community", [False, True])
@pytest.mark.parametrize("private", [False, True])
async def test_default_multiuser_checkin_needs_no_per_user_allow_rule(community, private):
    from astrbot.core.platform.message_type import MessageType
    plugin, event, owner, own = multiuser_group()
    plugin.config.update(community_agent_enabled=community, access_rules=[])
    if private:
        event.message_obj.type = MessageType.FRIEND_MESSAGE
        event.message_obj.group_id = ""
    for action in ("bind", "status", "unbind", "checkin"):
        assert plugin.permission(event, action).allowed
    assert "签到成功" in await plugin.checkin_result(event, submit=True)
    own.call.assert_awaited_once_with("POST", "/me/checkin")
    owner.call.assert_not_called()
    if community:
        assert not plugin.allowed(event), "普通用户不能继承创建者的私人记忆身份"


@pytest.mark.asyncio
async def test_private_nonowner_status_reads_own_binding_in_community_mode():
    from astrbot.core.platform.message_type import MessageType
    plugin, event, owner, own = multiuser_group()
    event.message_obj.type, event.message_obj.group_id = MessageType.FRIEND_MESSAGE, ""
    plugin.config["access_rules"] = []
    own.store = SimpleNamespace(persistent=True)
    own.call.return_value = {"account": {"nickname": "合成用户"}}
    replies = [r async for r in plugin.status(event)]
    assert "合成用户" in str(replies) and "已连接" in str(replies)
    own.call.assert_awaited_once_with("GET", "/binding")
    owner.call.assert_not_called()


@pytest.mark.asyncio
async def test_public_all_sessions_does_not_open_unlisted_group_account_operations():
    plugin, event, owner, own = multiuser_group()
    plugin.config.update(community_agent_enabled=False, public_read_all_sessions=True, access_rules=[])
    event.message_obj.group_id = "777777"
    assert plugin.permission(event, "public_read").allowed
    for action in ("bind", "status", "checkin"):
        assert not plugin.permission(event, action).allowed
    own.call.assert_not_called()
    owner.call.assert_not_called()
