"""群内发起只向真实发起者私发链接；不以帮助或绑定扩大私人查询权限。"""
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from test_group_public_read import fixture
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot.core.star.filter.command import CommandFilter
from astrbot.core.star.star_handler import star_handlers_registry


def group_fixture(sender="123456789"):
    plugin, event, _ = fixture(group="692905367", sender=sender)
    plugin.config.update(allow_group_binding=True, allow_multi_user=True, public_read_all_sessions=True, allow_personal_queries=False, allow_checkin=True)
    event.message_obj.self_id = "2170194804"
    plugin.client.begin = AsyncMock(side_effect=AssertionError("must not use owner account"))
    plugin.send_review_message = AsyncMock(return_value=True)
    accounts = {}
    def account(actor, bot, **kwargs):
        assert bot == "2170194804"
        if actor not in accounts:
            accounts[actor] = SimpleNamespace(
                pending=None, tokens=None,
                begin=AsyncMock(return_value={"user_code":f"CODE-{actor}","verification_uri":f"https://fixture.invalid/web/connected-apps?user_code={actor}"}),
                call=AsyncMock(return_value={"account":{"nickname":"never show in group"}}), poll=AsyncMock(),
            )
        return accounts[actor], actor+"-installation"
    plugin.accounts = SimpleNamespace(get=account)
    return plugin,event,accounts


def text(results):
    return "\n".join(part.text for result in results for part in result.chain if hasattr(part,"text"))


@pytest.mark.asyncio
async def test_two_group_actors_get_distinct_links_only_in_their_own_private_chat():
    plugin, first, accounts = group_fixture()
    _,second,_ = group_fixture("987654321")
    for event in (first,second):
        result = text([row async for row in plugin.connect(event)])
        assert "已私发" in result and "尚未绑定" not in result
        assert "https://" not in result and "CODE-" not in result
        assert event.is_stopped()
    targets = [row.args[0] for row in plugin.send_review_message.await_args_list]
    assert targets == ["configured-platform:FriendMessage:123456789", "configured-platform:FriendMessage:987654321"]
    assert len(accounts)==2
    for actor,client in accounts.items():
        assert client.begin.await_args.args[0]==actor+"-installation"
    plugin.client.begin.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize("failure",[False,RuntimeError("transport uncertain")])
async def test_private_delivery_failure_never_exposes_link_in_group(failure):
    plugin,event,_=group_fixture()
    if failure is False: plugin.send_review_message.return_value=False
    else: plugin.send_review_message.side_effect=failure
    result=text([row async for row in plugin.connect(event)])
    assert "未能确认" in result and "本次尚未绑定" in result
    assert "CODE-" not in result and "https://" not in result
    assert plugin.send_review_message.await_count==1


@pytest.mark.asyncio
async def test_qq_temporary_private_delivery_uses_only_real_sender_and_current_group():
    plugin,event,_=group_fixture()
    event.bot=SimpleNamespace(send_private_msg=AsyncMock(return_value={"message_id":123}))
    result=text([row async for row in plugin.connect(event)])
    assert "已私发" in result
    sent=event.bot.send_private_msg.await_args.kwargs
    assert sent['user_id']==123456789 and sent['group_id']==692905367
    assert "CODE-123456789" in sent['message'][0]['data']['text']
    plugin.send_review_message.assert_not_awaited()


@pytest.mark.asyncio
async def test_group_status_checks_own_server_token_without_publishing_nickname_or_private_tools():
    plugin,event,accounts=group_fixture()
    client,_=plugin.binding_account(event,create=True)
    client.tokens={"scope":"profile:read_minimal"}
    result=text([row async for row in plugin.status(event)])
    assert "已建立" in result and "never show" not in result
    client.call.assert_awaited_once_with("GET","/binding")
    assert not plugin.allowed(event)
    assert "不在群里" in await plugin.personal_result(event,'grades')
    client.call.side_effect=IntegrationProblem("invalid_token")
    result=text([row async for row in plugin.status(event)])
    assert "已建立" not in result


@pytest.mark.asyncio
async def test_group_binding_requires_explicit_flag_and_does_not_use_quoted_sender():
    plugin,event,accounts=group_fixture()
    plugin.config['allow_group_binding']=False
    result=text([row async for row in plugin.connect(event)])
    assert "私聊" in result and not accounts
    plugin.config['allow_group_binding']=True
    event.message_str='sylu-connect @987654321'
    result=text([row async for row in plugin.connect(event)])
    assert list(accounts)==['123456789']


@pytest.mark.asyncio
@pytest.mark.parametrize('handler,prompt',[('help_command','sylu-help'),('sylu_commands','sylu help')])
async def test_native_help_command_registered_and_does_not_invoke_model_or_connect(handler,prompt):
    plugin,event,accounts=group_fixture()
    event.message_str=prompt
    event.is_at_or_wake_command=True
    metadata=next(row for row in star_handlers_registry.star_handlers_map.values() if row.handler_name==handler and row.handler_module_path=='astrbot_plugin_sylulive.main')
    command=next(item for item in metadata.event_filters if isinstance(item,CommandFilter))
    assert command.filter(event,{})
    result=text([row async for row in getattr(plugin,handler)(event)])
    assert "不用绑定" in result and "/sylu-connect" in result and "/sylu-checkin" in result
    assert "尚未开放" in result and "成绩" in result
    assert event.is_stopped() and not accounts
