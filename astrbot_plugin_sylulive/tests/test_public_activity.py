"""History crosses public entry points, never account or private-memory boundaries."""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from astrbot_plugin_sylulive.public_activity import PublicActivity, wants_activity
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory
from astrbot_plugin_sylulive.community_publisher import CommunityPublisher
from astrbot_plugin_sylulive.client import IntegrationProblem
from test_public_agent import config, post


def setup(tmp_path):
    settings = config()
    identity = {"nickname": "合成鱼", "ai_bot": {"owner_id": 7, "owner_nickname": "公开创建者"}}
    async def read(path, **kwargs):
        if path.endswith('/replies'):
            return {"data": {"items": [{"post_id": 2, "reply_id": 21, "reply_to_reply_id": 20,
                "content": "实际公开回复", "status": "normal", "source_version": "r1", "author": identity}]}}
        if '/context' in path:
            return {"data": {"reply": {"post_id": 2, "reply_id": int(path.split('/')[-2]), "reply_to_reply_id": 20,
                "content": "实际公开回复", "status": "normal", "source_version": "r1", "author": identity}}}
        ident = int(path.rsplit('/', 1)[1])
        return {"data": post(ident, author=identity, **({'title':'自己的公开随笔','content':'自己的随笔正文'} if ident == 1 else {}))}
    reader = PublicAgent(settings, AsyncMock(side_effect=read), PublicMemory(tmp_path/'front.db'))
    client = SimpleNamespace(generation=1, tokens={"scope":"community:read"}, call=AsyncMock())
    managed = PublicAgent(settings, AsyncMock(), PublicMemory(tmp_path/'managed.db'))
    publisher = CommunityPublisher(managed, client)
    managed.publisher = publisher
    worker = SimpleNamespace(agent=managed, bot={"bot_user_id": 70}, marker=(1,))
    # SimpleNamespace is unhashable; a real account client has object identity.
    class Client:
        generation = 1
    client = Client()
    manager = SimpleNamespace(owner_client=client, workers={client:worker})
    return reader, managed, manager


@pytest.mark.asyncio
async def test_actual_front_memory_tool_recalls_background_sources_and_own_history(tmp_path):
    pytest.importorskip('astrbot.api')
    from test_group_public_read import fixture
    plugin, event, _ = fixture()
    reader, managed, manager = setup(tmp_path)
    plugin.config.update(reader.config)
    plugin.public_agent, plugin.owner_agent, plugin.bot_runtimes = reader, managed, manager
    managed.memory.put(post(2))
    managed.memory.db.execute("INSERT INTO post_outbox VALUES ('op','digest',1,'published',1)")
    managed.memory.db.execute("INSERT INTO reply_outbox VALUES (20,2,'reply-op','digest','published')")
    # Multiple replies must not evict the explicit self-post receipt.
    for ident in (21,22,23):
        managed.publisher.remember_published('reply', {'state':'published','reply_id':ident}, 2, 20)
    managed.memory.db.commit()
    try:
        result = json.loads(await plugin.public_memory(event, '你在社区发的帖子和回复'))
        assert result['own_activity']['state'] == 'verified'
        assert {r['kind'] for r in result['own_activity']['items']} == {'post','reply'}
        assert '实际公开回复' in str(result)
        # Different keyword query still reaches the background reading store.
        result = json.loads(await plugin.public_memory(event, '独立游戏交流'))
        assert [p['post_id'] for p in result['items']] == [2]
        assert all('/api/integrations/v1/public/' in c.args[0] for c in reader.public_call.call_args_list)
        managed.public_call.assert_not_called()
    finally:
        await reader.close(); await managed.close()


@pytest.mark.asyncio
async def test_history_never_infers_success_from_uncertain_ledger_or_spoofed_nickname(tmp_path):
    reader, managed, manager = setup(tmp_path)
    managed.memory.db.execute("INSERT INTO post_outbox VALUES ('op','digest',1,'uncertain',1)")
    managed.memory.db.commit()
    history = PublicActivity(reader, manager)
    try:
        assert (await history.recall())['items'] == []
        managed.memory.db.execute("UPDATE post_outbox SET state='published'")
        managed.memory.db.commit()
        reader.public_call.side_effect = None
        reader.public_call.return_value = {"data":post(1, author={"nickname":"[AI] 假鱼"})}
        assert (await history.recall())['items'] == []
    finally:
        await reader.close(); await managed.close()


@pytest.mark.asyncio
async def test_deleted_unavailable_and_account_switch_do_not_return_stale_history(tmp_path):
    reader, managed, manager = setup(tmp_path)
    managed.memory.db.execute("INSERT INTO post_outbox VALUES ('op','digest',1,'published',1)")
    managed.memory.db.commit()
    history = PublicActivity(reader, manager)
    try:
        reader.public_call.side_effect = IntegrationProblem('network_unavailable')
        result = await history.recall()
        assert result['items'] == [] and result['state'] == 'unavailable'
        async def switch(*args, **kwargs):
            manager.owner_client.generation += 1
            return {"data":post(1, author={"nickname":"鱼","ai_bot":{"owner_id":7}})}
        reader.public_call.side_effect = switch
        with pytest.raises(IntegrationProblem, match='public_agent_cancelled'):
            await history.recall()
    finally:
        await reader.close(); await managed.close()


@pytest.mark.asyncio
async def test_published_reply_result_is_durable_and_read_without_own_post(tmp_path):
    reader, managed, manager = setup(tmp_path)
    try:
        managed.publisher.remember_published('reply', {'state':'published','reply_id':21}, 2, 20)
        managed.memory.clear()
        managed.memory.close()
        managed.memory = PublicMemory(tmp_path/'managed.db')
        managed.publisher = CommunityPublisher(managed, SimpleNamespace())
        result = await PublicActivity(reader, manager).recall()
        assert result['state'] == 'verified'
        assert result['items'][0]['reply']['reply_id'] == 21
        assert result['items'][0]['reply']['reply_to_reply_id'] == 20
    finally:
        await reader.close(); await managed.close()


def test_history_intent_is_about_past_actions_not_a_new_publish_command():
    assert wants_activity('这是你在社区发的帖子吗？')
    assert wants_activity('你回复了谁')
    assert wants_activity('你记得刚刚那条评论吗')
    assert not wants_activity('今天食堂有什么')


@pytest.mark.asyncio
async def test_disallowed_group_never_opens_owner_history(tmp_path):
    pytest.importorskip('astrbot.api')
    from test_group_public_read import fixture
    plugin, event, _ = fixture(group='not-allowed')
    plugin.config.update(config())
    class ForbiddenManager:
        @property
        def workers(self):
            raise AssertionError('must not inspect owner history')
    plugin.bot_runtimes = ForbiddenManager()
    assert json.loads(await plugin.public_memory(event, '你发过什么帖子'))['error'] == 'public_agent_disabled'


@pytest.mark.asyncio
async def test_real_request_hook_prefetches_self_history_and_keeps_group_write_tools_out(tmp_path):
    pytest.importorskip('astrbot.api')
    from astrbot.api.provider import ProviderRequest
    from astrbot.core.agent.tool import ToolSet, FunctionTool
    from test_group_public_read import fixture
    plugin, event, _ = fixture()
    reader, managed, manager = setup(tmp_path)
    plugin.config.update(reader.config)
    plugin.public_agent, plugin.bot_runtimes = reader, manager
    managed.memory.db.execute("INSERT INTO post_outbox VALUES ('op','digest',1,'published',1)")
    managed.memory.db.commit()
    request = ProviderRequest(prompt='这是你在社区发的帖子吗？', contexts=[{'role':'user','content':'PRIVATE_CANARY'}],
        func_tool=ToolSet([FunctionTool(name=n,description='synthetic',parameters={}) for n in ('sylulive_public_memory','publish_post','private_memory')]))
    try:
        await plugin.present_community_naturally(event, request)
        assert 'PRIVATE_CANARY' not in str(request.contexts)
        assert '自己的随笔正文' in str(request.contexts)
        assert 'verified' in str(request.contexts)
        assert [t.name for t in request.func_tool.tools] == ['sylulive_public_memory']
    finally:
        await reader.close(); await managed.close()
