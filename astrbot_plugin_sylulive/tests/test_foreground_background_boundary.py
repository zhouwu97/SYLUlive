"""Native plugin construction keeps public chat independent of managed account policy."""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock
import pytest
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.main import SYLUlivePlugin, StarTools
from astrbot_plugin_sylulive.client import BusinessClient
from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess
from test_group_public_read import fixture
from test_community_read_complete import source

@pytest.mark.asyncio
@pytest.mark.parametrize("paused", [False, True])
async def test_public_group_reads_survive_missing_or_paused_owner_bot(tmp_path, monkeypatch, paused):
    import keyring
    monkeypatch.setattr(keyring, "get_keyring", lambda: object())
    monkeypatch.setattr(StarTools, "get_data_dir", lambda *a: tmp_path)
    public=AsyncMock(return_value={"data":source()})
    authenticated=AsyncMock(side_effect=IntegrationProblem("bot_read_disabled"))
    monkeypatch.setattr(BusinessClient, "public_call", public)
    monkeypatch.setattr(BusinessClient, "call", authenticated)
    context=SimpleNamespace(get_config=lambda **kw: {"admins_id":["owner"]})
    config={"server_origin":"https://fixture.invalid", "owner_sender_id":"owner",
        "owner_platform_id":"configured-platform", "public_read_group_ids":["allowed-group"],
        "community_agent_enabled":True,"community_allowed_sections":["campus"],"community_retrieval_mode":"lexical"}
    plugin=SYLUlivePlugin(context,config)
    _,event,_=fixture()
    try:
        if paused:getattr(plugin,"owner_agent",plugin.public_agent).pause()
        value=json.loads(await plugin.get_post(event,811))
        assert value["data"]["post_id"]==811
        public.assert_awaited()
        authenticated.assert_not_awaited()
        assert isinstance(plugin.owner_agent.public_call,ManagedBotAccess)
        assert plugin.owner_agent is not plugin.public_agent
        assert plugin.owner_agent.memory is not plugin.public_agent.memory
    finally:
        await plugin.terminate()
