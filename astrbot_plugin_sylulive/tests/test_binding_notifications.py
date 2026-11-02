"""授权通知只交给原发起人；虚拟时钟，不连接 QQ 或授权服务。"""
import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from astrbot_plugin_sylulive.binding_notifications import BindingNotifications, BindingTarget, MESSAGES, send_notice
from astrbot_plugin_sylulive.client import IntegrationProblem


class Clock:
    value = 100.0
    def now(self): return self.value
    async def sleep(self, seconds): self.value += seconds


class Client:
    def __init__(self, outcome):
        self.pending = {"deadline": 112, "next": 105, "interval": 5}
        self.tokens, self.generation, self.outcome, self.calls = None, 0, outcome, 0
    async def poll(self, *, expected):
        assert expected is self.pending
        self.calls += 1
        if self.outcome == "success":
            self.pending, self.tokens = None, {"scope": "checkin:write"}
        elif self.outcome == "timeout":
            raise IntegrationProblem("authorization_pending")
        elif self.outcome == "denied":
            raise IntegrationProblem("access_denied")
        else:
            raise IntegrationProblem("invalid_response")


@pytest.mark.asyncio
@pytest.mark.parametrize("outcome", ["success", "timeout", "denied", "unavailable"])
async def test_binding_reports_actual_terminal_outcome_once(outcome):
    clock, client, target, notify = Clock(), Client(outcome), object(), AsyncMock(return_value=True)
    notifications = BindingNotifications(notify, lambda _: True, now=clock.now, sleep=clock.sleep)
    assert notifications.start(client, target)
    task = notifications.tasks[client]
    assert notifications.start(client, target) and notifications.tasks[client] is task
    await task
    notify.assert_awaited_once_with(target, outcome)
    if outcome == "timeout":
        assert client.pending is not None, "超时不能假报已取消官网请求"
        assert "未能确认" in MESSAGES[outcome]
    await notifications.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["revoked", "new_generation", "delivery_uncertain"])
async def test_changed_permission_or_identity_cannot_leak_or_repeat_notice(case):
    clock, client = Clock(), Client("success")
    target, notify = object(), AsyncMock(return_value=False)
    notifications = BindingNotifications(notify, lambda _: case != "revoked", now=clock.now, sleep=clock.sleep)
    if case == "new_generation":
        original = client.poll
        async def changed(**kwargs):
            await original(**kwargs)
            client.generation += 1
        client.poll = changed
    assert notifications.start(client, target)
    await notifications.tasks[client]
    assert notify.await_count == (1 if case == "delivery_uncertain" else 0)
    await notifications.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("private", [False, True])
async def test_native_notice_routes_to_original_actor_and_group(private):
    bot = SimpleNamespace(send_private_msg=AsyncMock(return_value={"message_id": 123}),
                          send_group_msg=AsyncMock(return_value={"message_id": 124}))
    target = BindingTarget("synthetic", "aiocqhttp", "222222", "333333", "666666",
                           False, private, "synthetic:GroupMessage:222222_666666", bot=bot)
    assert await send_notice(None, target, "success")
    method = bot.send_private_msg if private else bot.send_group_msg
    other = bot.send_group_msg if private else bot.send_private_msg
    other.assert_not_called()
    args = method.call_args.kwargs
    assert args["self_id"] == "333333"
    if private:
        assert args["user_id"] == 222222
    else:
        assert args["group_id"] == 666666
        assert args["message"][0] == {"type": "at", "data": {"qq": "222222"}}


@pytest.mark.asyncio
async def test_ambiguous_private_delivery_never_falls_back_to_group():
    bot = SimpleNamespace(send_private_msg=AsyncMock(side_effect=TimeoutError), send_group_msg=AsyncMock())
    target = BindingTarget("synthetic", "aiocqhttp", "222222", "333333", "666666",
                           False, True, "synthetic:GroupMessage:666666", bot=bot)
    assert await send_notice(None, target, "success") is False
    bot.send_private_msg.assert_awaited_once()
    bot.send_group_msg.assert_not_called()
