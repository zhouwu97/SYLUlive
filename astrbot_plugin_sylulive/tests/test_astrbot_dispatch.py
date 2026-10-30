"""Regression at AstrBot's real command dispatch/default-agent boundary.

Install the fixed AstrBot version to run this integration check. It never opens
QQ, calls a model, connects a school account, or uses production data.
"""
import importlib
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

    async def call(self, *args):
        if self.fail:
            raise IntegrationProblem("connect_first")
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
@pytest.mark.parametrize("sender", ["owner", "other"])
@pytest.mark.parametrize("fail", [True, False])
async def test_business_command_never_falls_through_to_default_agent(monkeypatch, command, sender, fail):
    cls = importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    plugin = cls.__new__(cls)
    plugin.owner = "owner"
    plugin.platform = "synthetic-platform"
    plugin.installation = "synthetic-installation"
    plugin.config = {}
    plugin.client = BusinessClientFixture(fail)
    event = message(sender)
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
    assert len(responses) == (1 if sender == "owner" or command == "connect" else 0)


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
