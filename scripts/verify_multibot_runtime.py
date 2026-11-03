"""Called only by the loopback cross-runtime fixture, with two synthetic App sessions."""
import asyncio
import hashlib
import os
import tempfile
import time
import uuid
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit
from unittest.mock import AsyncMock

import httpx


async def verify_multi_account_runtime(first):
    from astrbot.api.star import Context
    from astrbot.api.provider import LLMResponse
    from astrbot.core.provider.provider import Provider
    from astrbot_plugin_sylulive.bot_runtime import BotRuntimeManager
    from astrbot_plugin_sylulive.client import BusinessClient
    from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess
    from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory
    from test_client import Store

    origin = os.environ['SYLULIVE_FULL_CHAIN_ORIGIN']
    assert urlsplit(origin).hostname == '127.0.0.1'
    second = BusinessClient(origin, Store())
    async with httpx.AsyncClient(base_url=origin, trust_env=False) as app:
        async def own(method, path, body=None, *, other=False):
            jwt = os.environ['SYLULIVE_FULL_CHAIN_SECOND_JWT' if other else 'SYLULIVE_FULL_CHAIN_JWT']
            response = await app.request(method, path, json=body, headers={'Authorization': 'Bearer ' + jwt})
            assert response.status_code == 200, (path, response.status_code)
            return response.json()

        try:
            device = await second.begin(str(uuid.uuid4()), '第二个合成执行账号', True, bot_reply=True, bot_post=True)
            consent = await own('POST', '/api/connected-apps/device-requests/lookup', {'user_code': device['user_code']}, other=True)
            await own('POST', '/api/connected-apps/device-requests/' + consent['consent_id'] + '/decision',
                      {'allow': True, 'scopes': consent['requested_scopes'], 'confirmation_nonce': consent['confirmation_nonce']}, other=True)
            await asyncio.sleep(max(0, second.pending['next'] - time.monotonic()) + .1)
            await second.poll()
            await own('POST', '/api/connected-apps/bot', {'name':'第二个合成机器人', 'enabled':True,
                      'policy': {'public_read_enabled':True, 'reply_enabled':True, 'sticker_enabled':False,
                                 'post_enabled':True, 'image_enabled':False, 'allowed_post_types':['campus_life'],
                                 'blocked_terms':[], 'block_links':True, 'daily_reply_limit':3, 'min_reply_interval_minutes':30}}, other=True)
            gate, started = asyncio.Event(), asyncio.Event()
            models = []
            class Model(Provider):
                def get_current_key(self): return 'synthetic-unused'
                def set_key(self, key): pass
                async def get_models(self): return ['synthetic']
                async def text_chat(self, **kwargs):
                    self.calls += 1
                    tools = kwargs['func_tool']
                    assert not {'sylulive_grades','private_memory','send_message','send_meme'}.intersection(t.name for t in tools.tools)
                    if self.calls == 1:
                        assert [getattr(message, 'role', None) for message in kwargs['contexts']] == ['system', 'user']
                        self.started = True
                        if len(models) == 2 and all(m.started for m in models): started.set()
                        await gate.wait()
                        name, args = 'read_public_post', {'post_id':1}
                    elif self.calls == 2:
                        name, args = 'read_public_replies', {'post_id':1}
                    elif self.calls == 3:
                        if tools.get_tool('publish_public_post') is not None:
                            name, args = 'publish_public_post', {'title':'第二个账号独立发帖', 'content':'按本人授权发表的合成公开讨论', 'post_type':'campus_life', 'source_post_ids':[1]}
                        else:
                            name, args = 'comment_public_post', {'post_id':1, 'content':'第二个账号独立运行的合成评论'}
                    else:
                        return LLMResponse(role='assistant', completion_text='合成运行完成')
                    return LLMResponse(role='assistant', tools_call_name=[name], tools_call_args=[args], tools_call_ids=[str(self.calls)])
            async def provider(_):
                model = Model({'id':'synthetic-runtime-provider','type':'synthetic'}, {})
                model.calls, model.started = 0, False
                models.append(model)
                return model
            context = Context.__new__(Context)
            context.provider_manager = SimpleNamespace(get_provider_by_id=provider)
            config = {'community_agent_enabled':True, 'community_multi_user_runtime_enabled':True, 'allow_multi_user':True,
                      'community_auto_browse':True, 'community_auto_comment':True, 'community_allowed_sections':['campus_life'],
                      'community_agent_provider_id':'synthetic-runtime-provider', 'community_browse_topic':'跨端公开合成帖子'}
            with tempfile.TemporaryDirectory(prefix='sylulive-two-runtime-') as directory:
                directory = Path(directory)
                legacy = PublicAgent(config, ManagedBotAccess(first), PublicMemory(directory/'legacy.sqlite3'))
                accounts = SimpleNamespace(clients=lambda:[(hashlib.sha256(b'second').hexdigest(), second, 'synthetic')], restore=lambda:None)
                wall, monotonic = [time.time()], [time.monotonic()]
                manager = BotRuntimeManager(config, context, directory, accounts, first, hashlib.sha256(b'first').hexdigest(), legacy,
                                            clock=lambda:wall[0], monotonic=lambda:monotonic[0])
                try:
                    await manager.discover(start_workers=False)
                    for worker in manager.workers.values():
                        await manager.sync(worker)
                        assert worker.round_task is not None, (worker.state, worker.error)
                    await asyncio.wait_for(started.wait(), 20)
                    b_task = manager.workers[second].round_task
                    await own('POST', '/api/connected-apps/bot', {'enabled':False})
                    await manager.sync(manager.workers[first])
                    assert b_task is not None and not b_task.done()
                    gate.set()
                    result = await asyncio.wait_for(b_task, 30)
                    assert result['state'] == 'completed' and result['read_count'] == 1
                    a_view = await own('GET', '/api/connected-apps/bot/runtime')
                    b_view = await own('GET', '/api/connected-apps/bot/runtime', other=True)
                    assert a_view['runtime']['state'] == 'paused'
                    assert b_view['runtime']['state'] == 'completed'
                    assert b_view['runtime']['last_action']['kind'] == 'reply'
                    assert b_view['runtime']['last_read_at']
                    # Advance the synthetic scheduler to a new round; comment and post stay separate attempts.
                    wall[0] += 1801
                    monotonic[0] += 1801
                    config['community_auto_comment'], config['community_auto_post'] = False, True
                    await manager.sync(manager.workers[second])
                    assert manager.workers[second].round_task is not None
                    assert (await manager.workers[second].round_task)['state'] == 'completed'
                    b_view = await own('GET', '/api/connected-apps/bot/runtime', other=True)
                    assert b_view['runtime']['last_action']['kind'] == 'post'
                    assert b_view['runtime']['last_action']['post_id']
                finally:
                    gate.set()
                    await manager.close()
        finally:
            await second.close()
