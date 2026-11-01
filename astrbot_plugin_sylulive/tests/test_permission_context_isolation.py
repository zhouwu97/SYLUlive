from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from astrbot.api.provider import ProviderRequest
from astrbot.core.agent.tool import FunctionTool, ToolSet
from test_group_public_read import fixture


def test_legacy_credential_owner_is_not_implicitly_a_deployment_admin():
    plugin, event, _ = fixture(group="", sender="owner")
    plugin.context.get_config = lambda **kwargs: {"admins_id": []}
    assert plugin.allowed(event), "旧授权本人仍能管理自己的账号"
    assert not plugin.is_bot_admin(event)
    assert plugin.public_only_session(event), "旧owner字段不能授予部署者私有知识库继承权限"
    plugin.context.get_config = lambda **kwargs: {"admins_id": ["owner"]}
    assert not plugin.public_only_session(event)
    event.set_extra("_api_key_allow_admin_role", False)
    assert plugin.public_only_session(event)


@pytest.mark.asyncio
async def test_denied_public_reading_does_not_restore_global_knowledge_or_private_tools(monkeypatch):
    from astrbot.api import sp
    plugin, event, calls = fixture(sender="member")
    plugin.config["access_rules"] = [{"effect":"deny", "capabilities":["public_read"], "chat_types":["group"], "subjects":"everyone"}]
    get, put = AsyncMock(return_value={"kb_ids":["deployment-private"]}), AsyncMock()
    monkeypatch.setattr(sp, "session_get", get)
    monkeypatch.setattr(sp, "session_put", put)
    await plugin.isolate_public_group_knowledge(event)
    put.assert_awaited_once_with(event.unified_msg_origin, "kb_config", {"kb_ids":[]})
    tools = ToolSet([FunctionTool(name=name, description="synthetic", parameters={}) for name in ("sylulive_posts","send_message_to_user","search_knowledge_base","get_group_message_history")])
    request = ProviderRequest(prompt="看看帖子", system_prompt="原人格", func_tool=tools)
    await plugin.present_community_naturally(event, request)
    assert {tool.name for tool in request.func_tool.tools} == {"get_group_message_history"}
    assert request.system_prompt.startswith("原人格")
    assert request.system_prompt.count("[当前会话本人命令权限]") == 1
    assert not calls


@pytest.mark.asyncio
async def test_disabling_multi_user_does_not_prevent_existing_user_group_unbind():
    plugin, event, _ = fixture(group="692905367", sender="123456789")
    event.message_obj.self_id = "2170194804"
    plugin.config.update(allow_multi_user=False, allow_group_binding=True, public_read_all_sessions=True)
    own = SimpleNamespace(disconnect=AsyncMock())
    plugin.accounts = SimpleNamespace(get=lambda actor,bot,**kwargs:(own,"own-installation"))
    assert plugin.permission(event,"unbind").allowed
    assert not plugin.feature_available(event,"bind")
    results = [result async for result in plugin.disconnect(event)]
    assert results
    own.disconnect.assert_awaited_once()
