"""Optional vendor workflow contract; uses only synthetic assets and captured sends.

Set ASTRBOT_STEALER_ROOT to an installed, reviewed plugin checkout. No vendor code
or user meme database is copied into this repository.
"""

import importlib
import importlib.util
import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from PIL import Image


@pytest.mark.asyncio
async def test_installed_stealer_search_send_and_cross_chat_denial(
    tmp_path, monkeypatch
):
    root = os.getenv("ASTRBOT_STEALER_ROOT")
    if not root:
        pytest.skip("optional reviewed Stealer checkout not configured")
    path = Path(root)
    assert (path / "core/tools/meme_search_tool.py").is_file()
    # Do not prepend the live plugin parent: it also contains an older SYLUlive
    # package, which would silently test that installed version instead of HEAD.
    alias = "verified_stealer_contract"
    spec = importlib.util.spec_from_file_location(
        alias, path / "__init__.py", submodule_search_locations=[str(path)]
    )
    package = importlib.util.module_from_spec(spec)
    monkeypatch.setitem(sys.modules, alias, package)
    spec.loader.exec_module(package)
    workflow = importlib.import_module(
        alias + ".core.tools.meme_search_tool"
    ).MemeSearchToolWorkflow
    selector_class = importlib.import_module(
        alias + ".core.search.meme_selector"
    ).MemeSelector
    engine_class = importlib.import_module(
        alias + ".core.events.meme_sender_engine"
    ).MemeSenderEngine
    renderer_class = importlib.import_module(
        alias + ".core.processing.image_render_service"
    ).ImageRenderService
    from astrbot.api.provider import LLMResponse
    from astrbot.api.star import Context
    from astrbot.core.agent.tool import FunctionTool, ToolSet
    from astrbot.core.provider.provider import Provider
    from test_group_public_read import fixture

    from astrbot_plugin_sylulive.chat_media import chat_tools

    _, event, _ = fixture()
    event.send = AsyncMock()
    public, private = tmp_path / "approved.png", tmp_path / "private.png"
    for image in (public, private):
        Image.new("RGB", (8, 8), "green").save(image)
    index = {
        str(public): {"scope_mode": "public", "overlay_text": "开心"},
        str(private): {"scope_mode": "local", "origin_target": "group:other-chat"},
    }
    plugin = workflow()
    (
        plugin.MAX_SEARCH_RESULTS,
        plugin.SEND_MEME_TOOL_NAME,
        plugin.SEARCH_MEME_TOOL_NAME,
    ) = 5, "send_meme", "search_meme"
    plugin.plugin_config = SimpleNamespace(
        character_info={}, get_event_target=lambda e: ("group", e.get_group_id())
    )
    plugin.db_service = SimpleNamespace(
        count_total=lambda: 2,
        get_index_cache_readonly=lambda: index,
        get_emoji=lambda p: index.get(p),
        get_all_paths=lambda: list(index),
        increment_usage_sync=Mock(return_value=True),
    )
    plugin.is_send_enabled_for_event = lambda e: True
    plugin.send_meme_as_gif = False
    plugin.image_render_service = renderer_class(plugin)
    plugin._emoji_sender_engine = engine_class(plugin)
    plugin.meme_selector = selector_class(plugin)
    # Candidate ranking is deterministic here; actual vendor event state, scope
    # validation, image encoding/sending and consumption remain unmodified.
    plugin.meme_selector.smart_search = AsyncMock(
        return_value=[(str(public), "合成开心图片", "happy", "开心")]
    )

    async def search(event, query: str):
        async for value in plugin._search_meme_impl(event, query):
            yield value

    async def send(event, emoji_id: int):
        async for value in plugin._send_meme_impl(event, emoji_id):
            yield value

    tools = [
        FunctionTool(
            name=name,
            description="synthetic contract",
            parameters={
                "type": "object",
                "properties": {field: {"type": kind}},
                "required": [field],
            },
            handler=handler,
            handler_module_path="data.plugins.astrbot_plugin_stealer.main",
        )
        for name, field, kind, handler in [
            ("search_meme", "query", "string", search),
            ("send_meme", "emoji_id", "integer", send),
        ]
    ]
    selected = chat_tools(tools, set(), memes=True)

    class Model(Provider):
        def get_current_key(self):
            return "synthetic"

        def set_key(self, key):
            pass

        async def get_models(self):
            return ["synthetic"]

        async def text_chat(self, **kwargs):
            self.calls += 1
            if self.calls == 1:
                return LLMResponse(
                    role="assistant",
                    tools_call_name=["search_meme"],
                    tools_call_args=[{"query": "开心"}],
                    tools_call_ids=["synthetic-search"],
                )
            if self.calls == 2:
                assert "合成开心图片" in str(kwargs["contexts"])
                return LLMResponse(
                    role="assistant",
                    tools_call_name=["send_meme"],
                    tools_call_args=[{"emoji_id": 1}],
                    tools_call_ids=["synthetic-send"],
                )
            assert "发送成功" in str(kwargs["contexts"][-1])
            return LLMResponse(role="assistant", completion_text="已发送")

    model = Model({"id": "synthetic", "type": "synthetic"}, {})
    model.calls = 0
    context = Context.__new__(Context)
    context.provider_manager = SimpleNamespace(
        get_provider_by_id=AsyncMock(return_value=model)
    )
    await context.tool_loop_agent(
        event=event,
        chat_provider_id="synthetic",
        contexts=[],
        tools=ToolSet(selected),
        prompt="合成测试",
        max_steps=4,
    )
    assert model.calls == 3
    event.send.assert_awaited_once()
    plugin.db_service.increment_usage_sync.assert_called_once_with(str(public))
    again = "".join([r async for r in plugin._send_meme_impl(event, 1)])
    assert "candidate_expired" in again
    _, other_event, _ = fixture(group="other-group")
    other_event.send = AsyncMock()
    assert "candidate_expired" in "".join(
        [r async for r in plugin._send_meme_impl(other_event, 1)]
    )
    plugin._emoji_sender_engine.emoji_turn_state(event).set_candidates(
        [{"path": str(private), "desc": "private", "emotion": "happy"}]
    )
    assert "scope_denied" in "".join(
        [r async for r in plugin._send_meme_impl(event, 1)]
    )
    event.send.assert_awaited_once()
    other_event.send.assert_not_called()
