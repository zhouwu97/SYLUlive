"""Regression at AstrBot's real command dispatch/default-agent boundary.

Install the fixed AstrBot version to run this integration check. It never opens
QQ, calls a model, connects a school account, or uses production data.
"""
import importlib
import json
from copy import deepcopy
from types import SimpleNamespace

import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")

from astrbot.core.message.components import Plain
from astrbot.core.pipeline.process_stage.stage import ProcessStage
from astrbot.core.pipeline.process_stage.method.star_request import StarRequestSubStage
from astrbot.core.platform.astr_message_event import AstrMessageEvent
from astrbot.core.platform.astrbot_message import AstrBotMessage, MessageMember
from astrbot.core.platform.message_type import MessageType
from astrbot.core.platform.platform_metadata import PlatformMetadata
from astrbot.core.star.star import star_map
from astrbot.core.star.filter.command import CommandFilter
from astrbot.api.provider import ProviderRequest, LLMResponse
from astrbot.core.agent.message import Message, TextPart
from astrbot.core.agent.run_context import ContextWrapper
from astrbot.core.star.star_handler import EventType, star_handlers_registry

from astrbot_plugin_sylulive.client import IntegrationProblem


class BusinessClientFixture:
    pending = None
    store = SimpleNamespace(persistent=False)

    def __init__(self, fail):
        self.fail = fail

    async def begin(self, *args):
        if self.fail:
            raise IntegrationProblem("network_unavailable")
        return {"user_code": "SYNTHETIC", "verification_uri": "https://fixture.invalid/authorize"}

    async def call(self, *args, **kwargs):
        if self.fail:
            raise IntegrationProblem("connect_first")
        if args[1] == "/community/sections":
            return {"sections": []}
        return {"account": {"id": 1, "nickname": "synthetic"}}

    async def disconnect(self):
        if self.fail:
            raise IntegrationProblem("network_unavailable")


class DefaultAgentProbe:
    calls = 0

    async def process(self, event):
        self.calls += 1
        yield


def message(sender):
    obj = AstrBotMessage()
    obj.type = MessageType.FRIEND_MESSAGE
    obj.self_id = "synthetic-bot"
    obj.message_id = "synthetic-command"
    obj.sender = MessageMember(sender, "synthetic-user")
    obj.message = [Plain("synthetic command")]
    obj.message_str = "synthetic command"
    obj.raw_message = {}
    event = AstrMessageEvent(
        obj.message_str, obj,
        PlatformMetadata("aiocqhttp", "synthetic", "synthetic-platform"), sender,
    )
    event.is_at_or_wake_command = True
    event.is_wake = True
    return event


@pytest.mark.asyncio
@pytest.mark.parametrize("command", ["connect", "status", "disconnect"])
@pytest.mark.parametrize("sender", ["owner", "other", "group"])
@pytest.mark.parametrize("fail", [True, False])
async def test_business_command_never_falls_through_to_default_agent(monkeypatch, command, sender, fail):
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner = "owner"
    plugin.platform = "synthetic-platform"
    plugin.installation = "synthetic-installation"
    plugin.config = {"public_read_group_ids": ["synthetic-group"]}
    plugin.client = BusinessClientFixture(fail)
    event = message(sender)
    if sender == "group":
        event.message_obj.type = MessageType.GROUP_MESSAGE
        event.message_obj.group_id = "synthetic-group"
    metadata = SimpleNamespace(
        handler=getattr(plugin, command), handler_name=command,
        handler_full_name="synthetic." + command,
        handler_module_path="synthetic.command_plugin",
        event_filters=[], event_type=EventType.AdapterMessageEvent,
        extras_configs={},
    )
    monkeypatch.setitem(star_map, metadata.handler_module_path,
                        SimpleNamespace(name="synthetic", display_name="synthetic"))
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
            responses.append("".join(getattr(c, "text", "") for c in result.chain))
    assert stage.agent_sub_stage.calls == 0, "Business command triggered a second model reply"
    assert event.is_stopped(), "Command must terminate propagation after its response"
    assert len(responses) == (1 if sender in ("owner", "group") or command == "connect" else 0)


def test_connection_error_does_not_claim_a_publish_was_attempted():
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    text = cls.problem(IntegrationProblem("network_unavailable"))
    assert "发布结果" not in text


@pytest.mark.parametrize("handler_name,keyword", [
    ("connect", "sylu-connect"), ("status", "sylu-status"),
    ("disconnect", "sylu-disconnect"),
])
def test_english_keywords_match_real_registered_command_filters(handler_name, keyword):
    module = importlib.import_module("astrbot_plugin_sylulive.main")
    metadata = next(
        item for item in star_handlers_registry.star_handlers_map.values()
        if item.handler_module_path == module.__name__ and item.handler_name == handler_name
    )
    event = message("owner")
    # AstrBot removes the configured '/' wake prefix before its command filters.
    event.message_str = keyword
    filters = [f for f in metadata.event_filters if isinstance(f, CommandFilter)]
    assert len(filters) == 1
    assert filters[0].filter(event, {})


@pytest.mark.asyncio
@pytest.mark.parametrize("scope", ["owner_private", "other_sender", "other_platform", "group"])
async def test_presentation_hook_preserves_context_and_is_scoped(scope):
    module = importlib.import_module("astrbot_plugin_sylulive.main")
    plugin = module.SYLUlivePlugin.__new__(module.SYLUlivePlugin)
    plugin.owner = "owner"
    plugin.platform = "synthetic-platform"
    event = message("other" if scope == "other_sender" else "owner")
    if scope == "other_platform":
        event.platform_meta = PlatformMetadata("aiocqhttp", "synthetic", "another-platform")
    if scope == "group":
        event.message_obj.type = MessageType.GROUP_MESSAGE
        event.message_obj.group_id = "synthetic-group"
    contexts = [{"role": "tool", "content": '{"post_id":811,"reply_id":2013,"source_version":"fixture"}'}]
    request = ProviderRequest(prompt="总结刚才那篇帖子", system_prompt="原有人格", contexts=deepcopy(contexts))
    await plugin.present_community_naturally(event, request)
    assert request.prompt == "总结刚才那篇帖子" and request.contexts == contexts
    if scope == "owner_private":
        assert request.system_prompt.startswith("原有人格") and request.system_prompt != "原有人格"
        first = request.system_prompt
        await plugin.present_community_naturally(event, request)
        assert request.system_prompt == first
    else:
        assert request.system_prompt == "原有人格"


def test_presentation_hook_is_registered_with_real_sdk():
    module = importlib.import_module("astrbot_plugin_sylulive.main")
    metadata = next(item for item in star_handlers_registry.star_handlers_map.values()
                    if item.handler_module_path == module.__name__ and item.handler_name == "present_community_naturally")
    assert metadata.event_type == EventType.OnLLMRequestEvent


@pytest.mark.asyncio
async def test_status_uses_nickname_without_database_account_id():
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner, plugin.platform = "owner", "synthetic-platform"
    plugin.client = BusinessClientFixture(False)
    event = message("owner")
    responses = [result async for result in plugin.status(event)]
    text = "".join(getattr(component, "text", "") for component in responses[0].chain)
    assert "synthetic" in text and "#1" not in text


@pytest.mark.asyncio
@pytest.mark.parametrize("fresh_reads", [[], ["/community/posts/811"], ["/community/posts/811", "/community/posts/811/replies"]])
async def test_followup_summary_requires_new_post_and_comment_reads(fresh_reads):
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner, plugin.platform = "owner", "synthetic-platform"
    class ReaderFixture:
        async def call(self, *args, **kwargs):
            return {"data": {"post_id": 811}}
    plugin.client = ReaderFixture()
    event = message("owner")
    request = ProviderRequest(prompt="把刚才那篇讨论再自然地总结一下", contexts=[
        {"role": "assistant", "tool_calls": [{"id": "previous", "type": "function", "function": {"name": "sylulive_get_post", "arguments": '{"post_id":811}'}}]},
        {"role": "tool", "tool_call_id": "previous", "content": '{"data":{"post_id":811,"content":"旧帖子正文"}}'},
    ])
    await plugin.present_community_naturally(event, request)
    for path in fresh_reads:
        await plugin.tool(event, "GET", path)
    response = LLMResponse(role="assistant", completion_text="刚刚读到的讨论内容。")
    run_context = ContextWrapper(context=None, messages=[Message(role="assistant", content=[TextPart(text=response.completion_text)])])
    await plugin.verify_current_read(event, run_context, response)
    if len(fresh_reads) < 2:
        assert "没有取得新的社区查询结果" in response.completion_text
        assert "刚刚读到" not in response.completion_text
        assert run_context.messages[-1].content[0].text == response.completion_text
    else:
        assert response.completion_text == "刚刚读到的讨论内容。"


@pytest.mark.asyncio
async def test_explicit_rewrite_can_use_previous_result_without_claiming_a_new_read():
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner, plugin.platform = "owner", "synthetic-platform"
    event = message("owner")
    request = ProviderRequest(prompt="只改写上面的总结，不要重新读取。")
    await plugin.present_community_naturally(event, request)
    response = LLMResponse(role="assistant", completion_text="根据上次读取的内容整理。")
    await plugin.verify_current_read(event, ContextWrapper(context=None), response)
    assert response.completion_text == "根据上次读取的内容整理。"


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [None, "post", "replies"])
async def test_comment_tool_rereads_parent_and_fails_closed(failure):
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner, plugin.platform = "owner", "synthetic-platform"
    calls = []

    class ReaderFixture:
        async def call(self, method, path, **kwargs):
            calls.append((method, path, kwargs.get("params")))
            kind = "replies" if path.endswith("/replies") else "post"
            if kind == failure:
                raise IntegrationProblem("invalid_token")
            if kind == "post":
                return {"data": {"post_id": 811, "content": "本轮原帖", "source_version": "fresh"}}
            return {"data": {"items": [{"reply_id": 2013, "post_id": 811}], "next_after_id": 2013}}

    plugin.client = ReaderFixture()
    event = message("owner")
    result = json.loads(await plugin.replies(event, 811, after_id=2000))
    assert calls[0][:2] == ("GET", "/community/posts/811")
    if failure == "post":
        assert len(calls) == 1
    else:
        assert calls[1] == ("GET", "/community/posts/811/replies", {"after_id": 2000})
    if failure:
        assert result["error"] == "invalid_token" and "data" not in result
        assert "message" in result
        assert "replies" not in event.get_extra("sylulive_completed_reads", set())
    else:
        assert result["data"]["post"]["content"] == "本轮原帖"
        assert result["data"]["items"][0]["reply_id"] == 2013
        assert {"post", "replies"}.issubset(event.get_extra("sylulive_completed_reads"))


def test_first_post_comments_and_campus_feed_require_current_reads():
    from astrbot_plugin_sylulive.main import required_read_kinds
    contexts = [{"role": "assistant", "tool_calls": [{"function": {"name": "sylulive_posts"}}]}]
    assert required_read_kinds(ProviderRequest(prompt="列出最近的校园帖子")) == {"feed"}
    assert required_read_kinds(ProviderRequest(prompt="看看刚才列表中第一篇帖子的评论", contexts=contexts)) == {"post", "replies"}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "handler,args",
    [
        ("request_private_review", {"source": "account"}),
        ("share_private_review", {"code": "0123456789abcdef"}),
        ("cancel_private_review", {"code": "0123456789abcdef"}),
    ],
)
@pytest.mark.parametrize("fail", [True, False])
async def test_private_review_commands_do_not_enter_group_or_private_model(
    monkeypatch, handler, args, fail
):
    from astrbot_plugin_sylulive.private_review import ReviewProblem

    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)

    async def result(*a, **k):
        if fail:
            raise ReviewProblem("受控拒绝")
        return "受控处理结果"

    plugin.private_reviews = SimpleNamespace(request=result, decide=result)
    event = message("owner")
    event.message_obj.type = MessageType.GROUP_MESSAGE
    event.message_obj.group_id = "synthetic-group"
    md = SimpleNamespace(
        handler=getattr(plugin, handler),
        handler_name=handler,
        handler_full_name="review." + handler,
        handler_module_path="synthetic.review",
        event_filters=[],
        event_type=EventType.AdapterMessageEvent,
        extras_configs={},
    )
    monkeypatch.setitem(
        star_map,
        md.handler_module_path,
        SimpleNamespace(name="review", display_name="review"),
    )
    event.set_extra("activated_handlers", [md])
    event.set_extra("handlers_parsed_params", {md.handler_full_name: args})
    stage = ProcessStage()
    stage.ctx = SimpleNamespace(astrbot_config={"provider_settings": {"enable": True}})
    stage.star_request_sub_stage = StarRequestSubStage()
    stage.agent_sub_stage = DefaultAgentProbe()
    async for _ in stage.process(event):
        pass
    assert event.is_stopped() and stage.agent_sub_stage.calls == 0


@pytest.mark.parametrize(
    "handler,command",
    [
        ("request_private_review", "sylu-review account"),
        ("share_private_review", "sylu-share 0123456789abcdef"),
        ("cancel_private_review", "sylu-cancel 0123456789abcdef"),
    ],
)
def test_native_command_parser_accepts_review_commands(handler, command):
    module = importlib.import_module("astrbot_plugin_sylulive.main")
    metadata = next(
        item
        for item in star_handlers_registry.star_handlers_map.values()
        if item.handler_module_path == module.__name__ and item.handler_name == handler
    )
    event = message("owner")
    event.message_str = command
    assert next(
        f for f in metadata.event_filters if isinstance(f, CommandFilter)
    ).filter(event, {})
