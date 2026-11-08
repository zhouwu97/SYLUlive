from types import SimpleNamespace

import pytest

from astrbot_plugin_sylulive.chat_media import chat_tools, trusted_meme


def tool(name, module="data.plugins.astrbot_plugin_stealer.main", **properties):
    return SimpleNamespace(name=name, handler_module_path=module, parameters={"type": "object", "properties": properties})


def test_only_current_chat_tools_from_reviewed_plugin_are_kept():
    search = tool("search_meme", query={"type": "string"})
    send = tool("send_meme", emoji_id={"type": "integer"})
    other = [tool("steal_meme", image_ref={"type": "string"}), tool("send_message_to_user"),
             tool("send_meme", "other_plugin.main", emoji_id={"type": "integer"}),
             tool("send_meme", emoji_id={}, target_user={}), tool("run_shell")]
    assert chat_tools([search, send, *other], set(), True) == [search, send]
    assert chat_tools([search, send], set(), False) == []


@pytest.mark.asyncio
async def test_public_persona_keeps_current_chat_media_but_not_private_or_collectors(tmp_path):
    from astrbot.api.provider import ProviderRequest
    from astrbot.core.agent.tool import FunctionTool, ToolSet
    from test_group_public_read import fixture
    from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory
    plugin, event, _ = fixture(group="allowed-group", sender="member")
    plugin.config.update(community_agent_enabled=True, community_chat_memes_enabled=True)
    plugin.public_agent = PublicAgent(plugin.config, plugin.client.public_call, PublicMemory(tmp_path / "public.db"))
    names = ["sylulive_public_image", "sylulive_canteen", "sylulive_campus_map", "sylulive_draft_post", "private_memory", "steal_meme", "send_message_to_user"]
    tools = [FunctionTool(name=n, description="test", parameters={}) for n in names]
    for name, field in [("search_meme", "query"), ("send_meme", "emoji_id")]:
        tools.append(FunctionTool(name=name, description="test", parameters={"type":"object", "properties":{field:{"type":"string"}}}, handler_module_path="data.plugins.astrbot_plugin_stealer.main"))
    req = ProviderRequest(prompt="发个开心表情，再看看食堂照片", func_tool=ToolSet(tools))
    try:
        await plugin.present_community_naturally(event, req)
        assert {t.name for t in req.func_tool.tools} == {"sylulive_public_image", "sylulive_canteen", "sylulive_campus_map", "search_meme", "send_meme"}
        assert "[当前聊天表情]" in req.system_prompt
    finally:
        await plugin.public_agent.close()
