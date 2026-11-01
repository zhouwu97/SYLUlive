"""真实设备授权客户端＋合成时钟／消息，验证结果通知与并发隔离。"""
import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

from astrbot_plugin_sylulive import client as client_module
from astrbot_plugin_sylulive.binding_delivery import BindingDelivery
from astrbot_plugin_sylulive.binding_notifications import BindingNotifications, BindingTarget, MESSAGES, send_notice
from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem
from test_client import Store, tokens
from test_group_permissions import FIRST, SECOND, BOT, GROUP, source, group_fixture, allow_rule, invoke


class Clock:
    def __init__(self): self.value, self.waits = 100.0, []
    def monotonic(self): return self.value
    def time(self): return 1800000000.0 + self.value
    async def sleep(self, seconds):
        self.waits.append(seconds)
        self.value += seconds
        await asyncio.sleep(0)


async def setup_client(monkeypatch, replies, *, lifetime=40, store=None):
    clock = Clock()
    monkeypatch.setattr(client_module, "time", clock)
    calls = []
    def respond(request):
        calls.append((request.url.path, clock.value))
        if request.url.path.endswith("device_authorization"):
            return httpx.Response(200, json={"device_code": "sd_fixture_only", "user_code": "ABCD-1234", "expires_in": lifetime, "interval": 5, "verification_uri_complete": "https://fixture.invalid/web/connected-apps?user_code=ABCD-1234"})
        if request.url.path.endswith("/token"):
            reply = replies.pop(0) if len(replies) > 1 else replies[0]
            if isinstance(reply, Exception): raise reply
            if reply == "success": return httpx.Response(200, json=tokens())
            return httpx.Response(400, json={"error": reply})
        return httpx.Response(200, json={})
    store = Store() if store is None else store
    client = BusinessClient("https://fixture.invalid", store, transport=httpx.MockTransport(respond))
    link = await client.begin("00000000-0000-4000-8000-000000000001", "合成安装", False)
    return client, clock, calls, link


def watcher(client, clock, *, target=None, allowed=None, notify=None):
    notify = AsyncMock(return_value=True) if notify is None else notify
    target = BindingTarget.from_event(source()) if target is None else target
    manager = BindingNotifications(notify, allowed or (lambda _: True), now=clock.monotonic, sleep=clock.sleep)
    assert manager.start(client, target)
    return manager, notify, target


async def finish(manager):
    await asyncio.wait_for(asyncio.gather(*list(manager.tasks.values())), timeout=2)
    await asyncio.sleep(0)


@pytest.mark.asyncio
async def test_success_polls_without_another_user_message_and_notifies_once(monkeypatch):
    client, clock, calls, _ = await setup_client(monkeypatch, ["authorization_pending", "success"])
    manager, notify, target = watcher(client, clock)
    try:
        assert manager.start(client, target)  # 重复登记不能创建第二个兑换任务。
        await finish(manager)
        assert client.pending is None and client.store.value is not None
        notify.assert_awaited_once_with(target, "success")
        assert [when for path, when in calls if path.endswith('/token')] == [105, 110]
        assert manager.start(client, target) is False  # 已领到令牌，不重新通知。
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("reply", ["authorization_pending", "slow_down", httpx.ConnectError("synthetic network outage")])
async def test_timeout_is_bounded_and_keeps_request_for_explicit_cancellation(monkeypatch, reply):
    client, clock, calls, _ = await setup_client(monkeypatch, [reply], lifetime=16)
    pending = client.pending
    manager, notify, target = watcher(client, clock)
    try:
        await finish(manager)
        notify.assert_awaited_once_with(target, "timeout")
        assert client.pending is pending and client.tokens is None
        assert clock.value == 116 and len([path for path, _ in calls if path.endswith('/token')]) <= 3
        assert all(wait > 0 for wait in clock.waits)
        assert "未能确认" in MESSAGES['timeout'] and "/sylu-disconnect" in MESSAGES['timeout']
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("reply,outcome", [("access_denied", "denied"), ("expired_token", "timeout"), ("invalid_response", "unavailable")])
async def test_terminal_errors_are_reported_once_without_exposing_remote_details(monkeypatch, reply, outcome):
    client, clock, _, _ = await setup_client(monkeypatch, [reply])
    manager, notify, target = watcher(client, clock)
    pending = client.pending
    try:
        await finish(manager)
        notify.assert_awaited_once_with(target, outcome)
        assert client.pending is pending and client.tokens is None
        assert manager.start(client, target) is True
        assert not manager.tasks and notify.await_count == 1
        assert "sd_fixture" not in MESSAGES[outcome] and "ABCD-1234" not in MESSAGES[outcome]
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_manual_poll_and_background_poll_can_share_one_successful_exchange(monkeypatch):
    client, clock, calls, _ = await setup_client(monkeypatch, ["success"])
    manager, notify, target = watcher(client, clock)
    try:
        client.pending['next'] = 0
        await asyncio.gather(client.poll(), *list(manager.tasks.values()))
        await client.poll()  # 已绑定不能因另一轮已取走pending而报过期。
        notify.assert_awaited_once_with(target, "success")
        assert len([path for path, _ in calls if path.endswith('/token')]) == 1
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_server_slow_down_increases_interval_before_retry(monkeypatch):
    client, clock, calls, _ = await setup_client(monkeypatch, ['slow_down', 'success'])
    manager, notify, target = watcher(client, clock)
    try:
        await finish(manager)
        assert [when for path, when in calls if path.endswith('/token')] == [105, 115]
        notify.assert_awaited_once_with(target, 'success')
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_credential_save_exception_never_announces_success_or_logs_secret(monkeypatch, caplog):
    client, clock, _, _ = await setup_client(monkeypatch, ['success'])
    def broken_save(_): raise RuntimeError('sr_fixture_do_not_log')
    client.store.save = broken_save
    pending = client.pending
    manager, notify, target = watcher(client, clock)
    try:
        await finish(manager)
        notify.assert_awaited_once_with(target, 'unavailable')
        assert client.pending is pending and client.store.value is None
        assert 'sr_fixture_do_not_log' not in caplog.text
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_lock_waiting_old_poll_cannot_exchange_a_replacement_request(monkeypatch):
    client, clock, calls, _ = await setup_client(monkeypatch, ["success"])
    old = client.pending
    try:
        async with client.lock:
            task = asyncio.create_task(client.poll(expected=old))
            await asyncio.sleep(0)
            client.pending = {**old, 'device_code': 'sd_new_request', 'next': 0}
        with pytest.raises(IntegrationProblem, match='authorization_changed'):
            await task
        assert not any(path.endswith('/token') for path, _ in calls)
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ['disconnect', 'replacement', 'permission'])
async def test_cancellation_replacement_or_permission_change_does_not_notify_old_success(monkeypatch, change):
    client, clock, _, _ = await setup_client(monkeypatch, ["success"])
    permitted = [True]
    manager, notify, _ = watcher(client, clock, allowed=lambda _: permitted[0])
    original_sleep = clock.sleep
    async def change_before_waking(seconds):
        if change == 'disconnect': await client.disconnect()
        elif change == 'replacement': client.pending = {**client.pending, 'device_code': 'sd_replacement'}
        else: permitted[0] = False
        await original_sleep(seconds)
    manager.sleep = change_before_waking
    try:
        await finish(manager)
        notify.assert_not_awaited()
        if change == 'permission': assert client.store.value is not None
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('failure', [False, RuntimeError('sd_do_not_log_this')])
async def test_delivery_uncertainty_does_not_retry_or_remove_saved_binding(monkeypatch, caplog, failure):
    client, clock, _, _ = await setup_client(monkeypatch, ['success'])
    notify = AsyncMock(return_value=False, side_effect=failure if isinstance(failure, Exception) else None)
    manager, _, _ = watcher(client, clock, notify=notify)
    try:
        await finish(manager)
        assert notify.await_count == 1 and client.store.value is not None
        assert 'binding_notice_delivery_unconfirmed' in caplog.text and 'sd_do_not_log' not in caplog.text
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_stop_and_close_cancel_sleeping_workers_without_false_timeout(monkeypatch):
    client, clock, _, _ = await setup_client(monkeypatch, ['authorization_pending'])
    manager, notify, _ = watcher(client, clock)
    sleeping = asyncio.Event()
    async def block(_):
        sleeping.set()
        await asyncio.Future()
    manager.sleep = block
    try:
        await sleeping.wait()
        await manager.stop(client)
        assert not manager.tasks
        await manager.close()
        notify.assert_not_awaited()
        assert client.pending is not None and client.tokens is None
    finally:
        await manager.close(); await client.close()


@pytest.mark.asyncio
async def test_two_users_are_notified_using_their_own_original_subjects(monkeypatch):
    first, clock, _, _ = await setup_client(monkeypatch, ['success'])
    second, second_clock, _, _ = await setup_client(monkeypatch, ['success'])
    # 两个客户端使用同一测试时钟，模拟同一个运行实例。
    clock = second_clock
    notify = AsyncMock(return_value=True)
    manager = BindingNotifications(notify, lambda _: True, now=clock.monotonic, sleep=clock.sleep)
    try:
        assert manager.start(first, BindingTarget.from_event(source(FIRST)))
        assert manager.start(second, BindingTarget.from_event(source(SECOND)))
        await finish(manager)
        actual = [(row.args[0].sender, row.args[0].bot_id, row.args[0].group, row.args[1]) for row in notify.await_args_list]
        assert sorted(actual) == sorted([(FIRST, BOT, GROUP, 'success'), (SECOND, BOT, GROUP, 'success')])
        assert first.store.value is not None and second.store.value is not None
    finally:
        await manager.close(); await first.close(); await second.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('private', [True, False])
@pytest.mark.parametrize('outcome', list(MESSAGES))
async def test_native_notification_targets_only_original_sender_bot_and_group(private, outcome):
    event = source()
    event.message_str = '@' + SECOND + '把通知发给别人'
    event.bot = SimpleNamespace(send_group_msg=AsyncMock(return_value={'message_id': 11}), send_private_msg=AsyncMock(return_value={'message_id': 12}))
    target = BindingTarget.from_event(event, private_reply=private)
    assert await send_notice(SimpleNamespace(), target, outcome)
    method = event.bot.send_private_msg if private else event.bot.send_group_msg
    sent = method.await_args.kwargs
    assert sent['self_id'] == BOT and sent['group_id'] == int(GROUP)
    assert sent['message'][-1] == {'type': 'text', 'data': {'text': MESSAGES[outcome] if private else '\n' + MESSAGES[outcome]}}
    if private:
        assert sent['user_id'] == int(FIRST)
        event.bot.send_group_msg.assert_not_awaited()
    else:
        assert sent['message'][0] == {'type': 'at', 'data': {'qq': FIRST}}
        event.bot.send_private_msg.assert_not_awaited()
    assert SECOND not in str(sent)


@pytest.mark.asyncio
async def test_uncertain_native_private_send_does_not_fall_back_to_group_or_second_channel():
    event = source()
    event.bot = SimpleNamespace(send_private_msg=AsyncMock(side_effect=RuntimeError('transport uncertain')), send_group_msg=AsyncMock())
    context = SimpleNamespace(send_message=AsyncMock())
    assert not await send_notice(context, BindingTarget.from_event(event, private_reply=True), 'success')
    event.bot.send_group_msg.assert_not_awaited(); context.send_message.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize('private', [True, False])
async def test_native_astrbot_fallback_routes_to_canonical_group_or_actual_private_sender(private):
    event = source()
    target = BindingTarget.from_event(event, private_reply=private)
    context = SimpleNamespace(send_message=AsyncMock(return_value=True))
    assert await send_notice(context, target, 'timeout')
    route, chain = context.send_message.await_args.args
    assert route == ('configured-platform:FriendMessage:' + FIRST if private else 'configured-platform:GroupMessage:' + GROUP)
    if not private: assert str(chain.chain[0].qq) == FIRST


@pytest.mark.asyncio
@pytest.mark.parametrize('mode,fallback,private', [('group', False, False), ('auto', True, False), ('auto', False, True), ('private', False, True)])
async def test_plugin_notification_route_follows_actual_link_delivery(mode, fallback, private):
    plugin, event, _ = group_fixture()
    plugin.config['binding_link_delivery'] = mode
    captured = []
    plugin.binding_notifications = SimpleNamespace(start=lambda client, target: captured.append(target) or True, now=lambda: 100)
    client = SimpleNamespace(pending={'deadline': 200})
    result = plugin.track_binding_result(event, client, BindingDelivery('fixture', used_fallback=fallback))
    assert captured[0].sender == FIRST and captured[0].route_private is private
    assert ('本人私聊' if private else '本群并 @ 你') in result
    assert '1分40秒' in result


@pytest.mark.asyncio
async def test_connect_command_starts_live_client_polling_and_uses_no_owner_account(monkeypatch):
    own, clock, _, _ = await setup_client(monkeypatch, ['success'])
    own.pending = None
    plugin, event, accounts = group_fixture(rules=[allow_rule('bind', 'status')])
    accounts.clients[(BOT, FIRST)] = own
    plugin._create_binding_notifications()
    notify = AsyncMock(return_value=True)
    plugin.binding_notifications.notify = notify
    plugin.binding_notifications.now, plugin.binding_notifications.sleep = clock.monotonic, clock.sleep
    try:
        reply = await invoke(plugin.connect, event)
        assert '等待超时后' in reply and 'user_code=ABCD-1234' in reply
        await finish(plugin.binding_notifications)
        assert notify.await_args.args[0].sender == FIRST and notify.await_args.args[1] == 'success'
        assert not plugin.client.calls and not accounts.clients[(BOT, SECOND)].calls
    finally:
        await plugin.binding_notifications.close(); await own.close()


@pytest.mark.asyncio
async def test_private_origin_always_notifies_the_same_private_sender():
    event = source(group='')
    event.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value={'message_id': 12}), send_group_msg=AsyncMock())
    target = BindingTarget.from_event(event)
    assert target.route_private and await send_notice(SimpleNamespace(), target, 'success')
    sent = event.bot.send_private_msg.await_args.kwargs
    assert sent['user_id'] == int(FIRST) and sent['self_id'] == BOT and 'group_id' not in sent
    event.bot.send_group_msg.assert_not_awaited()


@pytest.mark.asyncio
async def test_capacity_is_bounded_and_closing_stops_all_pending_workers(monkeypatch):
    first, _, _, _ = await setup_client(monkeypatch, ['authorization_pending'])
    second, clock, _, _ = await setup_client(monkeypatch, ['authorization_pending'])
    notify = AsyncMock()
    manager = BindingNotifications(notify, lambda _: True, now=clock.monotonic, sleep=clock.sleep, limit=1)
    try:
        assert manager.start(first, BindingTarget.from_event(source(FIRST)))
        assert manager.start(second, BindingTarget.from_event(source(SECOND))) is False
        await manager.close()
        assert not manager.tasks and first.pending is not None and second.pending is not None
        assert manager.start(first, BindingTarget.from_event(source(FIRST))) is False
        notify.assert_not_awaited()
    finally:
        await manager.close(); await first.close(); await second.close()


@pytest.mark.asyncio
async def test_plugin_unbind_cancels_its_worker_without_touching_other_subject(monkeypatch):
    own, clock, _, _ = await setup_client(monkeypatch, ['authorization_pending'])
    plugin, event, accounts = group_fixture(rules=[allow_rule('unbind', 'status')])
    accounts.clients[(BOT, FIRST)] = own
    plugin._create_binding_notifications()
    plugin.binding_notifications.now = clock.monotonic
    sleeping = asyncio.Event()
    async def sleep_until_cancelled(_):
        sleeping.set()
        await asyncio.Future()
    plugin.binding_notifications.sleep = sleep_until_cancelled
    notify = plugin.binding_notifications.notify = AsyncMock(return_value=True)
    plugin.binding_notifications.start(own, BindingTarget.from_event(event))
    try:
        await sleeping.wait()
        result = await invoke(plugin.disconnect, event)
        assert '已断开' in result and own.pending is None and own.tokens is None
        assert not plugin.binding_notifications.tasks and accounts.clients[(BOT, SECOND)].tokens
        notify.assert_not_awaited()
    finally:
        await plugin.binding_notifications.close(); await own.close()


@pytest.mark.asyncio
async def test_plugin_shutdown_joins_workers_before_closing_http_clients():
    plugin, _, _ = group_fixture()
    order = []
    plugin.binding_notifications = SimpleNamespace(close=AsyncMock(side_effect=lambda: order.append('notifications')))
    plugin.client = SimpleNamespace(close=AsyncMock(side_effect=lambda: order.append('owner')))
    plugin.accounts = SimpleNamespace(close=AsyncMock(side_effect=lambda: order.append('accounts')))
    await plugin.terminate()
    assert order == ['notifications', 'owner', 'accounts']
