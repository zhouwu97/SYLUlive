"""真实 SDK 消息入口：人格不能覆盖功能规则或本人群内确认。"""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from test_group_public_read import fixture
from astrbot_plugin_sylulive.group_confirmations import GroupConfirmations


def rule(action, effect="allow", **extra):
    return {"name": "合成权限规则", "effect": effect, "subjects": "everyone",
            "chat_types": ["private", "group"], "capabilities": [action], **extra}


def enabled(**kwargs):
    plugin, event, calls = fixture(**kwargs)
    plugin.config.update(community_agent_enabled=True, allow_multi_user=True,
                         allow_personal_queries=True, group_personal_delivery="confirm")
    return plugin, event, calls


@pytest.mark.parametrize("group,sender", [("", "other"), ("other-group", "member")])
def test_open_public_queries_work_with_persona_without_granting_account_access(group, sender):
    plugin, event, _ = enabled(group=group, sender=sender)
    plugin.config["public_read_all_sessions"] = True
    assert plugin.allowed_reading(event)
    assert not plugin.allowed(event), "普通消息不能变成创建者记忆身份"
    if group:
        assert not plugin.permission(event, "bind").allowed
        assert not plugin.permission(event, "grades").allowed


@pytest.mark.asyncio
async def test_explicit_public_denial_reaches_actual_read_tool_not_just_preview():
    plugin, event, calls = enabled()
    plugin.config["access_rules"] = [rule("public_read", "deny")]
    assert not plugin.permission(event, "public_read").allowed
    result = json.loads(await plugin.tool(event, "GET", "/community/posts"))
    assert result["error"] == "permission_denied"
    assert calls == []


@pytest.mark.parametrize("action", ["grades", "erke"])
def test_explicit_personal_rules_are_not_disabled_by_persona(action):
    plugin, event, _ = enabled()
    plugin.config["access_rules"] = [rule(action, group_ids=["allowed-group"])]
    assert plugin.permission(event, action).allowed
    assert plugin.feature_available(event, action)
    plugin.config["allow_personal_queries"] = False
    assert not plugin.feature_available(event, action)


@pytest.mark.asyncio
async def test_persona_group_query_reads_only_requester_after_original_group_confirmation():
    plugin, event, _ = enabled()
    plugin.config["access_rules"] = [rule("grades", group_ids=["allowed-group"])]
    client = SimpleNamespace(tokens={"scope": "academic:grades:read"}, pending=None, generation=0,
                             call=AsyncMock(return_value={"data": {"dataset": "grades",
                                 "fetched_at": "2026-11-02T00:00:00Z",
                                 "grades": [{"course_name": "合成课程", "score": 88}]}}))
    looked_up = []
    def get(sender, bot_id, *, create=False):
        looked_up.append((sender, bot_id, create))
        return client, "synthetic-installation"
    plugin.accounts = SimpleNamespace(get=get)
    plugin.group_confirmations = GroupConfirmations()
    first = await plugin.personal_result(event, "grades")
    assert "本人确认" in first
    client.call.assert_not_called()
    code = next(iter(plugin.group_confirmations.rows))
    event.message_obj.sender.user_id = "another-member"
    assert "不属于你" in await plugin.private_review_decision(event, code, True)
    client.call.assert_not_called()
    event.message_obj.sender.user_id = "member"
    answer = await plugin.private_review_decision(event, code, True)
    assert "合成课程" in answer and "88" in answer
    assert all(row == ("member", "synthetic-bot", False) for row in looked_up)
    client.call.assert_awaited_once_with("GET", "/me/grades", params={"offset": 0, "limit": 20})
    assert "确认码无效" in await plugin.private_review_decision(event, code, True)


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["deny", "scope", "generation", "delivery"])
async def test_group_confirmation_rechecks_permission_and_authorization(change):
    plugin, event, _ = enabled()
    plugin.config["access_rules"] = [rule("grades")]
    client = SimpleNamespace(tokens={"scope": "academic:grades:read"}, pending=None,
                             generation=0, call=AsyncMock())
    plugin.accounts = SimpleNamespace(get=lambda *a, **k: (client, "synthetic"))
    plugin.group_confirmations = GroupConfirmations()
    assert "本人确认" in await plugin.personal_result(event, "grades")
    code = next(iter(plugin.group_confirmations.rows))
    if change == "deny":
        plugin.config["access_rules"].append(rule("grades", "deny"))
    elif change == "scope":
        client.tokens = {"scope": "profile:read_minimal"}
    elif change == "generation":
        client.generation += 1
    else:
        plugin.config["group_personal_delivery"] = "direct"
    answer = await plugin.private_review_decision(event, code, True)
    assert "合成课程" not in answer
    client.call.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("group,text,dataset", [("allowed-group", "我的成绩", "grades"), ("", "我的二课", "erke")])
async def test_explicit_natural_personal_command_stops_chat_and_uses_sender(group, text, dataset):
    plugin,event,_ = enabled(group=group)
    plugin.config["access_rules"] = [rule(dataset)]
    plugin.group_confirmations=GroupConfirmations()
    response={"data":{"dataset":dataset,"fetched_at":"2026-11-02T00:00:00Z","summary":{}}}
    client=SimpleNamespace(tokens={"scope":"academic:grades:read academic:erke:read"},pending=None,generation=0,call=AsyncMock(return_value=response))
    plugin.accounts=SimpleNamespace(get=lambda sender,bot,create=False:(client,"synthetic"))
    event.is_at_or_wake_command=True;event.message_str=text
    replies=[r async for r in plugin.daily_shortcuts(event)]
    assert len(replies)==1 and event.is_stopped()
    if group:
        assert "本人确认" in str(replies[0]);client.call.assert_not_called()
    else:
        assert "已同步二课" in str(replies[0])
        client.call.assert_awaited_once_with("GET","/me/erke",params={"offset":0,"limit":20})


@pytest.mark.asyncio
@pytest.mark.parametrize("sender,request_bot_scope", [("owner",True),("member",False)])
async def test_binding_requests_bot_comment_scope_only_for_creator(sender,request_bot_scope):
    plugin,event,_=enabled(group="",sender=sender)
    plugin.origin="https://fixture.invalid"
    plugin.config["community_auto_comment"]=True
    plugin.track_binding_result=lambda *args:"合成通知"
    client=SimpleNamespace(begin=AsyncMock(return_value={"user_code":"SYNTHETIC","verification_uri":"https://fixture.invalid/web/connected-apps?user_code=SYNTHETIC"}))
    if sender=="owner":plugin.client=client
    else:plugin.accounts=SimpleNamespace(get=lambda *a,**k:(client,"synthetic"))
    replies=[r async for r in plugin.connect(event)]
    assert replies and client.begin.await_count==1
    assert client.begin.await_args.kwargs["bot_reply"] is request_bot_scope
