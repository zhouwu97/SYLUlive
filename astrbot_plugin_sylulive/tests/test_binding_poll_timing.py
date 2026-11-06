"""授权轮询使用合成响应，不连接官网或消息平台。"""
import asyncio
import time
from types import SimpleNamespace

import httpx
import pytest

from astrbot_plugin_sylulive import client as client_module
from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem
from test_client import Store, tokens


@pytest.mark.asyncio
@pytest.mark.parametrize("outcome", ["authorization_pending", "slow_down", "network_unavailable"])
async def test_next_poll_waits_full_interval_after_response(monkeypatch, outcome):
    clock = SimpleNamespace(value=100.0)
    monkeypatch.setattr(client_module, "time", SimpleNamespace(
        monotonic=lambda: clock.value, time=time.time))

    def respond(request):
        clock.value += 2  # 模拟网络与服务端处理，不能抵扣下一次间隔。
        if outcome == "network_unavailable":
            raise httpx.ReadTimeout("synthetic")
        return httpx.Response(400, json={"error": outcome})

    client = BusinessClient("https://fixture.invalid", Store(), transport=httpx.MockTransport(respond))
    client.pending = {"device_code": "sd_fixture", "deadline": 200, "interval": 5, "next": 100}
    try:
        with pytest.raises(IntegrationProblem, match=outcome):
            await client.poll()
        interval = 10 if outcome == "slow_down" else 5
        assert client.pending["next"] == 102 + interval
        clock.value = client.pending["next"] - .01
        with pytest.raises(IntegrationProblem, match="poll_later"):
            await client.poll(wait=False)
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("replace", [False, True, "already_claimed"])
async def test_user_command_waits_without_holding_lock_or_polling_replacement(replace):
    requests = []
    client = BusinessClient("https://fixture.invalid", Store(), transport=httpx.MockTransport(
        lambda r: requests.append(r) or httpx.Response(200, json=tokens())))
    client.pending = {"device_code": "sd_fixture", "deadline": time.monotonic()+10,
                      "interval": 5, "next": time.monotonic()+.02}
    try:
        command = asyncio.create_task(client.poll())
        await asyncio.sleep(0)
        assert not client.lock.locked()
        if replace:
            client.clear()
            if replace == "already_claimed":
                client._save(tokens())
                with pytest.raises(IntegrationProblem, match="authorization_changed"):
                    await command
                assert not requests
                return
            replacement = {"device_code": "sd_new", "deadline": time.monotonic()+10,
                           "interval": 5, "next": 0}
            client.pending = replacement
            with pytest.raises(IntegrationProblem, match="authorization_changed"):
                await command
            assert not requests and client.pending is replacement
        else:
            await command
            assert len(requests) == 1 and client.pending is None
            assert client.tokens["access_token"] == "sa_synthetic"
    finally:
        await client.close()
