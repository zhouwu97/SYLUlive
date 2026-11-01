"""多用户授权、私聊个人查询与群隔离；不接真实QQ或学校服务。"""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from astrbot.api.provider import ProviderRequest
from astrbot.core.agent.tool import FunctionTool, ToolSet
from test_group_public_read import fixture
from astrbot_plugin_sylulive.accounts import Accounts
from astrbot_plugin_sylulive.client import BusinessClient
from astrbot_plugin_sylulive.personal import format_personal
from astrbot_plugin_sylulive.personal import personal_intent


class Store:
    persistent = False
    def load(self): return None
    def save(self, value): pass
    def delete(self): pass


@pytest.mark.asyncio
async def test_native_plugin_constructor_initializes_multi_user_storage_and_closes_clients(tmp_path, monkeypatch):
    import importlib
    module = importlib.import_module('astrbot_plugin_sylulive.main')
    accounts_module = importlib.import_module('astrbot_plugin_sylulive.accounts')
    monkeypatch.setattr(module.StarTools, 'get_data_dir', lambda _: str(tmp_path))
    monkeypatch.setattr(module, 'CredentialStore', lambda _: Store())
    monkeypatch.setattr(accounts_module, 'CredentialStore', lambda _: Store())
    plugin = module.SYLUlivePlugin(SimpleNamespace(), {
        'owner_sender_id':'owner', 'owner_platform_id':'configured-platform',
        'server_origin':'https://fixture.invalid', 'allow_multi_user':True,
    })
    _, event, _ = fixture(group='',sender='one')
    try:
        first, installation = plugin.account(event,create=True)
        assert first is not plugin.client and installation != plugin.installation
        assert len(list(tmp_path.glob('*.json'))) == 2
        assert plugin.allowed(event)
    finally:
        await plugin.terminate()


@pytest.mark.parametrize('text,dataset', [('我的成绩','grades'),('帮我查一下成绩','grades'),('请看看我的二课情况','erke'),('我二课还差多少分','erke')])
def test_common_personal_requests_have_a_deterministic_route(text,dataset):
    assert personal_intent(text)==dataset


@pytest.mark.parametrize('text', ['查一下张三的成绩','查询QQ123的成绩','不要查我的成绩','帖子里写着我的成绩','《我的成绩》','学校二课有哪些活动'])
def test_other_subjects_negation_and_quotes_do_not_trigger_private_queries(text):
    assert personal_intent(text) is None


@pytest.mark.asyncio
async def test_registry_isolates_users_pending_tokens_and_installations(tmp_path, monkeypatch):
    import astrbot_plugin_sylulive.accounts as module
    monkeypatch.setattr(module, "CredentialStore", lambda _: Store())
    accounts = Accounts("https://fixture.invalid", "qq-instance", tmp_path)
    try:
        first, first_id = accounts.get("one")
        second, second_id = accounts.get("two")
        first.tokens = {"scope": "checkin:write", "synthetic": "first-only"}
        first.pending = {"device_code": "secret-one"}
        assert first_id != second_id and second.tokens is None and second.pending is None
        assert first.lock is not second.lock
        assert accounts.get("one") == (first, first_id)
        files = list(tmp_path.glob("*.json"))
        assert len(files) == 2 and all(set(json.loads(p.read_text())) == {"installation_id"} for p in files)
    finally:
        await accounts.close()


@pytest.mark.asyncio
async def test_same_sender_on_different_bots_has_distinct_credentials(tmp_path, monkeypatch):
    import astrbot_plugin_sylulive.accounts as module
    monkeypatch.setattr(module, "CredentialStore", lambda _: Store())
    accounts = Accounts("https://fixture.invalid", "qq-instance", tmp_path)
    try:
        first, first_id = accounts.get("one", "bot-one")
        second, second_id = accounts.get("one", "bot-two")
        assert first is not second and first_id != second_id
    finally:
        await accounts.close()


@pytest.mark.asyncio
async def test_each_private_actor_connects_with_their_own_link_and_no_owner_credential():
    plugin, first, _ = fixture(group="", sender="one")
    _, second, _ = fixture(group="", sender="two")
    plugin.config.update(allow_multi_user=True, allow_personal_queries=True)
    clients = {key: SimpleNamespace(begin=AsyncMock(return_value={"user_code": key, "verification_uri": f"https://fixture.invalid/web/connected-apps?user_code={key}"})) for key in ("one", "two")}
    plugin.accounts = SimpleNamespace(get=lambda sender, bot, **kwargs: (clients[sender], sender + "-installation"))
    plugin.client.begin = AsyncMock(side_effect=AssertionError("owner credentials must not be used"))
    for event in (first, second):
        replies = [r async for r in plugin.connect(event)]
        text = ''.join(p.text for r in replies for p in r.chain if hasattr(p, 'text'))
        assert f"user_code={event.get_sender_id()}" in text
        assert event.is_stopped()
    assert clients['one'].begin.await_args.args[0] == 'one-installation'
    assert clients['two'].begin.await_args.args[0] == 'two-installation'
    assert clients['one'].begin.await_args.args[1].startswith('QQ one · ')
    assert clients['two'].begin.await_args.args[1].startswith('QQ two · ')
    plugin.client.begin.assert_not_awaited()


@pytest.mark.asyncio
async def test_personal_scopes_are_explicitly_requested_without_school_secrets():
    requests = []
    def respond(request):
        requests.append(request)
        return httpx.Response(200, json={"device_code": "secret", "user_code": "ABCD-1234", "expires_in": 600, "interval": 5, "verification_uri_complete": "https://fixture.invalid/web/connected-apps?user_code=ABCD-1234"})
    client = BusinessClient('https://fixture.invalid', Store(), transport=httpx.MockTransport(respond))
    try:
        await client.begin('00000000-0000-4000-8000-000000000001', '合成用户', False, personal=True, checkin=True)
        data = requests[0].content.decode()
        assert 'academic%3Agrades%3Aread' in data and 'academic%3Aerke%3Aread' in data
        assert 'password' not in data and 'Authorization' not in requests[0].headers
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('sender', ['one', 'two'])
async def test_private_queries_and_checkin_use_actual_actor_only(sender):
    plugin, event, _ = fixture(group='', sender=sender)
    plugin.config.update(allow_multi_user=True, allow_personal_queries=True, allow_checkin=True)
    client = SimpleNamespace(tokens={'scope': 'checkin:write'}, call=AsyncMock(return_value={'data': {'dataset':'grades','grades':[{'course_name': sender+'课程','fraction':80}], 'fetched_at':'2026-11-01T00:00:00Z','is_stale':False}}))
    plugin.accounts = SimpleNamespace(get=lambda actor, bot, **kwargs: (client, 'own-installation') if actor == sender else None)
    result = await plugin.personal_result(event, 'grades')
    assert sender+'课程' in result and '非学校实时查询' in result
    client.call.assert_awaited_once_with('GET', '/me/grades', params={'offset':0,'limit':20})
    client.call.return_value = {'data': {'already':False,'check_in_date':'2026-11-01','streak_days':1,'exp_earned':5}}
    assert '签到成功' in await plugin.checkin_result(event, submit=True)
    assert client.call.await_args.args == ('POST','/me/checkin')


@pytest.mark.asyncio
async def test_group_and_admin_do_not_inherit_another_users_private_client():
    plugin, event, _ = fixture(sender='owner')
    plugin.config.update(allow_multi_user=True, allow_personal_queries=True, allow_checkin=True)
    plugin.accounts = SimpleNamespace(get=AsyncMock(side_effect=AssertionError('must not access private account')))
    assert '请本人私聊' in await plugin.personal_result(event,'grades')
    assert '群里不能代签' in await plugin.checkin_result(event,submit=True)
    plugin.accounts.get.assert_not_called()


@pytest.mark.asyncio
async def test_multi_user_private_llm_still_excludes_owner_knowledge_and_cross_session_tools():
    plugin, event, _ = fixture(group='', sender='one')
    plugin.config['allow_multi_user'] = True
    req = ProviderRequest(prompt='看看公开帖子', func_tool=ToolSet([FunctionTool(name=n,description='synthetic',parameters={}) for n in ['sylulive_posts','search_knowledge_base','send_message_to_user']]))
    await plugin.isolate_public_group_knowledge(event)
    await plugin.present_community_naturally(event, req)
    assert {t.name for t in req.func_tool.tools} == {'sylulive_posts'}


def test_private_format_marks_stale_partial_and_pagination():
    text=format_personal({'data':{'dataset':'grades','grades':[{'course_name':'课程','fraction':80}],'fetched_at':'2026-11-01T00:00:00Z','is_stale':True,'is_partial':True,'next_offset':20}},'grades')
    assert '已过期' in text and '部分数据' in text and '/sylu-grades 20' in text


@pytest.mark.asyncio
async def test_status_accepts_personal_only_scope_without_forcing_profile_permission():
    from astrbot_plugin_sylulive.client import IntegrationProblem
    plugin,event,_=fixture(group='',sender='one')
    plugin.config['allow_multi_user']=True
    client=SimpleNamespace(pending=None,tokens={'scope':'academic:grades:read'},call=AsyncMock(side_effect=IntegrationProblem('insufficient_scope')))
    plugin.accounts=SimpleNamespace(get=lambda *args,**kwargs:(client,'own-installation'))
    replies=[r async for r in plugin.status(event)]
    text=''.join(p.text for r in replies for p in r.chain if hasattr(p,'text'))
    assert '凭证有效' in text and '没有授权昵称' in text
    assert '请本人重新连接' not in text


@pytest.mark.asyncio
async def test_first_query_completes_own_pending_authorization_without_requiring_status_command():
    plugin, event, _ = fixture(group='', sender='one')
    plugin.config.update(allow_multi_user=True, allow_personal_queries=True)
    client=SimpleNamespace(pending={'device_code':'only-one'},call=AsyncMock(return_value={'data':{'dataset':'grades','grades':[],'fetched_at':'2026-11-01T00:00:00Z'}}))
    client.poll=AsyncMock()
    plugin.accounts=SimpleNamespace(get=lambda actor,bot,**kwargs:(client,'one-installation'))
    result=await plugin.personal_result(event,'grades')
    client.poll.assert_awaited_once()
    client.call.assert_awaited_once()
    assert '已同步成绩' in result


@pytest.mark.asyncio
async def test_revoking_one_user_does_not_clear_another_users_token():
    first = BusinessClient('https://fixture.invalid', Store(), transport=httpx.MockTransport(
        lambda _: httpx.Response(401, json={'code':'invalid_token'})))
    second = BusinessClient('https://fixture.invalid', Store(), transport=httpx.MockTransport(
        lambda _: httpx.Response(200, json={'data':{'own':'two'}})))
    import time
    for client, suffix in ((first,'one'),(second,'two')):
        client.tokens={'access_token':'sa_'+suffix,'refresh_token':'sr_'+suffix,'expires_at':time.time()+600,'scope':'academic:grades:read'}
    try:
        from astrbot_plugin_sylulive.client import IntegrationProblem
        with pytest.raises(IntegrationProblem):
            await first.call('GET','/me/grades')
        assert first.tokens is None
        assert (await second.call('GET','/me/grades'))['data']['own']=='two'
        assert second.tokens['access_token']=='sa_two'
    finally:
        await first.close()
        await second.close()
