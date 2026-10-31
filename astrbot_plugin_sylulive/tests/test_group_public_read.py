"""指定群仅可共享公开读取，不能继承维护者个人账号能力。"""
import importlib
import json

import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")
from astrbot.api.provider import ProviderRequest
from astrbot.core.platform.astr_message_event import AstrMessageEvent
from astrbot.core.platform.astrbot_message import AstrBotMessage, MessageMember
from astrbot.core.platform.message_type import MessageType
from astrbot.core.platform.platform_metadata import PlatformMetadata
from astrbot_plugin_sylulive.client import IntegrationProblem


def fixture(*, group="allowed-group", sender="member", platform="configured-platform", enabled=True, fail=False):
    module = importlib.import_module("astrbot_plugin_sylulive.main")
    plugin = module.SYLUlivePlugin.__new__(module.SYLUlivePlugin)
    plugin.owner, plugin.platform = "owner", "configured-platform"
    plugin.installation = "00000000-0000-4000-8000-000000000001"
    plugin.config = {"public_read_group_ids": ["allowed-group"] if enabled else [], "allow_proposals": True}
    calls = []

    class Reader:
        async def call(self, method, path, **kwargs):
            calls.append((method, path))
            if fail:
                raise IntegrationProblem("connect_first")
            if path == "/community/sections":
                return {"sections": []}
            if path.endswith("/replies"):
                return {"data": {"items": [{"post_id": 811, "reply_id": 2013}]}}
            return {"data": {"post_id": 811, "content": "本轮公开原帖"}}

    plugin.client = Reader()
    obj = AstrBotMessage()
    obj.type = MessageType.GROUP_MESSAGE if group else MessageType.FRIEND_MESSAGE
    obj.self_id = "synthetic-bot"
    obj.group_id = group
    obj.sender = MessageMember(sender, "synthetic")
    obj.message_id, obj.message_str, obj.message, obj.raw_message = "synthetic", "synthetic", [], {}
    event = AstrMessageEvent("synthetic", obj, PlatformMetadata("aiocqhttp", "synthetic", platform), group or sender)
    return plugin, event, calls


@pytest.mark.asyncio
@pytest.mark.parametrize("path", ["/community/posts", "/community/posts/811", "/community/posts/811/replies", "/community/replies/2013/context", "/community/stickers", "/community/sections"])
async def test_enabled_group_can_only_read_public_resources(path):
    plugin, event, calls = fixture()
    result = json.loads(await plugin.tool(event, "GET", path))
    assert "error" not in result and calls == [("GET", path)]
    assert not plugin.allowed(event)


@pytest.mark.asyncio
@pytest.mark.parametrize("method,path", [
    ("GET", "/binding"), ("GET", "/me/public-posts"), ("GET", "/actions/synthetic"),
    ("POST", "/actions"), ("POST", "/community/posts"),
    ("DELETE", "/community/posts/811"), ("GET", "/community/posts/811/../../binding"),
    ("GET", "/community/posts/811/replies/extra"),
])
async def test_group_cannot_inherit_owner_or_write_abilities(method, path):
    plugin, event, calls = fixture(sender="owner")
    result = json.loads(await plugin.tool(event, method, path))
    assert result["error"] == "private_owner_only" and calls == []


@pytest.mark.asyncio
@pytest.mark.parametrize("options", [{"group": "other-group"}, {"platform": "other-platform"}, {"enabled": False}, {"group": "", "sender": "other"}])
async def test_other_sessions_do_not_gain_public_access(options):
    plugin, event, calls = fixture(**options)
    assert json.loads(await plugin.tool(event, "GET", "/community/posts"))["error"] == "private_owner_only"
    assert calls == []


@pytest.mark.asyncio
async def test_group_comment_tool_returns_new_parent_and_comments():
    plugin, event, calls = fixture()
    request = ProviderRequest(prompt="总结帖子 811 的讨论", system_prompt="原有人格")
    await plugin.present_community_naturally(event, request)
    result = json.loads(await plugin.replies(event, 811))
    assert calls == [("GET", "/community/posts/811"), ("GET", "/community/posts/811/replies")]
    assert result["data"]["post"]["content"] == "本轮公开原帖"
    assert result["data"]["items"][0]["reply_id"] == 2013
    assert event.get_extra("sylulive_required_reads").issubset(event.get_extra("sylulive_completed_reads"))
    assert request.system_prompt.startswith("原有人格") and "群内范围" in request.system_prompt


@pytest.mark.asyncio
async def test_group_status_queries_public_resource_without_owner_profile():
    plugin, event, calls = fixture()
    results = [result async for result in plugin.status(event)]
    assert calls == [("GET", "/community/sections")]
    assert "本群" in str(results) and "nickname" not in str(results)
    assert event.is_stopped()


@pytest.mark.asyncio
async def test_group_error_does_not_offer_account_authorization_in_group():
    plugin, event, calls = fixture(fail=True)
    result = json.loads(await plugin.replies(event, 811))
    assert result["error"] == "connect_first" and "私聊" in result["message"]
    assert "/sylu-connect" not in result["message"] and "http" not in result["message"]
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_group_cannot_create_draft_even_when_owner_enabled_proposals():
    plugin, event, calls = fixture(sender="owner")
    result = json.loads(await plugin.draft_reply(event, 811, "synthetic", "不可代发"))
    assert result["error"] == "private_owner_only" and calls == []
