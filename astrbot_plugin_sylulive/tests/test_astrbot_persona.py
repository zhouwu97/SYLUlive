from types import SimpleNamespace
from unittest.mock import AsyncMock
from unittest.mock import patch

import pytest

from astrbot.api.provider import ProviderRequest
from astrbot_plugin_sylulive.astrbot_persona import selected_prompt
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory
from test_group_public_read import fixture
from test_public_agent import config, post


@pytest.mark.asyncio
async def test_foreground_persona_is_native_session_selection_not_plugin_fallback(tmp_path):
    plugin, event, _ = fixture(sender="owner", group="")
    plugin.config.update(config(), community_persona="LEGACY-FISH-SHOULD-NOT-BE-INJECTED")
    manager = SimpleNamespace(resolve_selected_persona=AsyncMock(return_value=("native", {"prompt": "NATIVE-SELECTED-PERSONA"}, None, False)))
    plugin.context.persona_manager = manager
    plugin.public_agent = PublicAgent(plugin.config, plugin.client.public_call, PublicMemory(tmp_path / "public.db"))
    request = ProviderRequest(prompt="你好", system_prompt="PRIVATE-PRELOAD", contexts=[{"role": "user", "content": "PRIVATE-HISTORY"}],
                              conversation=SimpleNamespace(user_id=event.unified_msg_origin, persona_id="native", cid="own"))
    try:
        await plugin.present_community_naturally(event, request)
        assert request.system_prompt.startswith("NATIVE-SELECTED-PERSONA")
        assert "LEGACY-FISH" not in request.system_prompt and "PRIVATE" not in request.system_prompt
        assert request.contexts == [] and request.conversation is None
        assert manager.resolve_selected_persona.call_args.kwargs["conversation_persona_id"] == "native"
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_no_persona_or_foreign_conversation_has_no_bundled_character():
    plugin, event, _ = fixture()
    manager = SimpleNamespace(resolve_selected_persona=AsyncMock(return_value=(None, None, None, False)))
    plugin.context.persona_manager = manager
    assert await selected_prompt(plugin.context, event, SimpleNamespace(user_id="foreign", persona_id="private")) == ""
    assert manager.resolve_selected_persona.call_args.kwargs["conversation_persona_id"] is None
    assert await selected_prompt(SimpleNamespace(), event) == ""


@pytest.mark.asyncio
@pytest.mark.parametrize("forced,conversation_id,expected", [("native-a", "native-b", "A"), (None, "native-b", "B"), (None, "[%None]", ""), (None, None, "A")])
async def test_actual_native_persona_resolver_respects_session_and_none(forced, conversation_id, expected):
    from astrbot.core.persona_mgr import PersonaManager
    _, event, _ = fixture()
    manager = PersonaManager.__new__(PersonaManager)
    manager.acm = SimpleNamespace(get_conf=lambda _: {"agent_runner": {"runner_type": "local", "config": {"persona": {"persona_id": "native-a"}}}})
    manager.personas_v3 = [{"name": "native-a", "prompt": "A"}, {"name": "native-b", "prompt": "B"}]
    conversation = SimpleNamespace(user_id=event.unified_msg_origin, persona_id=conversation_id)
    with patch("astrbot.core.persona_mgr.sp.get_async", new=AsyncMock(return_value={"persona_id": forced} if forced else {})):
        assert await selected_prompt(SimpleNamespace(persona_manager=manager), event, conversation) == expected


@pytest.mark.asyncio
async def test_background_uses_current_native_default_without_private_session(tmp_path):
    manager = SimpleNamespace(get_default_persona_v3=AsyncMock(side_effect=[{"prompt": "NATIVE-FIRST"}, {"prompt": "NATIVE-UPDATED"}]),
                              resolve_selected_persona=AsyncMock())
    context = SimpleNamespace(persona_manager=manager, tool_loop_agent=AsyncMock())
    reader = AsyncMock(return_value={"data": {"items": [post()]}})
    now = [1000]
    agent = PublicAgent(config(community_persona="LEGACY-FISH"), reader, PublicMemory(tmp_path / "public.db"), clock=lambda: now[0])
    try:
        await agent.browse(context)
        first = context.tool_loop_agent.call_args.kwargs["system_prompt"]
        now[0] += agent.interval()
        await agent.browse(context)
        second = context.tool_loop_agent.call_args.kwargs["system_prompt"]
        assert first.startswith("NATIVE-FIRST") and second.startswith("NATIVE-UPDATED")
        assert "LEGACY-FISH" not in first + second
        manager.resolve_selected_persona.assert_not_called()
    finally:
        await agent.close()
