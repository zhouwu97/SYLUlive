"""多人授权、默认权限和群确认的反向用例；所有数据为合成夹具。"""
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")

from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem
from astrbot_plugin_sylulive.group_confirmations import GroupConfirmations, ConfirmationProblem
from astrbot_plugin_sylulive.permissions import decide
from test_client import Store
from test_group_public_read import fixture
from test_multiuser_group_checkin import multiuser_group


@pytest.mark.asyncio
async def test_private_member_can_start_own_binding_in_community_mode():
    from astrbot.core.platform.message_type import MessageType
    plugin, event, owner, own = multiuser_group()
    plugin.origin = "https://fixture.invalid"
    event.message_obj.type, event.message_obj.group_id = MessageType.FRIEND_MESSAGE, ""
    plugin.config["access_rules"] = []
    own.begin = AsyncMock(return_value={"user_code": "SYNTHETIC", "verification_uri":
        "https://fixture.invalid/web/connected-apps?user_code=SYNTHETIC"})
    plugin.track_binding_result = lambda *args: "授权结果会通知本人"
    replies = [r async for r in plugin.connect(event)]
    text = "".join(part.text for reply in replies for part in reply.chain if hasattr(part, "text"))
    assert len(replies) == 1 and "SYNTHETIC" in text and "222222" in text
    own.begin.assert_awaited_once()
    assert own.begin.call_args.args[0] == "own-installation"
    assert own.begin.call_args.kwargs["checkin"] is True
    owner.call.assert_not_called()
    assert event.is_stopped() and event.call_llm is True


@pytest.mark.parametrize("change,reason", [
    ("deny", "explicit_deny"), ("strict", "default_deny"),
    ("malformed", "invalid_policy"), ("platform", "invalid_context"),
])
def test_permissions_do_not_silently_ignore_restrictions(change, reason):
    plugin, event, _, _ = multiuser_group()
    if change == "deny":
        plugin.config["access_rules"].append(dict(plugin.config["access_rules"][0], effect="deny"))
    elif change == "strict":
        plugin.config.update(access_default="deny", access_rules=[])
    elif change == "malformed":
        plugin.config["access_rules"] = [{"effect": "allow"}]
    else:
        plugin.config["owner_platform_id"] = "other-platform"
    decision = decide(plugin.config, event, "checkin", is_admin=True, default=True)
    assert not decision.allowed and decision.reason == reason


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["sender", "group", "bot", "expired", "replay"])
async def test_group_disclosure_confirmation_belongs_to_exact_actor_and_session(change):
    plugin, event, _, _ = multiuser_group()
    clock = [100.0]
    confirmations = GroupConfirmations(now=lambda: clock[0])
    code = await confirmations.create(event, "grades", {"offset": 0}, 1, "policy")
    if change == "sender":
        event.message_obj.sender.user_id = "444444"
    elif change == "group":
        event.message_obj.group_id = "777777"
    elif change == "bot":
        event.message_obj.self_id = "another-bot"
    elif change == "expired":
        clock[0] += 301
    else:
        row = await confirmations.consume(event, code)
        assert row["params"] == {"offset": 0}
        assert "body" not in row
    with pytest.raises(ConfirmationProblem):
        await confirmations.consume(event, code)


@pytest.mark.asyncio
async def test_cancel_pending_binding_uses_server_cancel_and_preserves_failure_for_retry():
    requests = []
    def respond(request):
        requests.append(request)
        return httpx.Response(503, json={"error": "service_unavailable"})
    client = BusinessClient("https://fixture.invalid", Store(), transport=httpx.MockTransport(respond))
    pending = {"device_code": "synthetic-device-secret", "deadline": 0}
    client.pending = pending
    generation = client.generation
    try:
        with pytest.raises(IntegrationProblem):
            await client.disconnect()
        assert client.pending is pending and client.generation == generation
        assert len(requests) == 1 and requests[0].url.path == "/api/oauth/device_authorization/cancel"
    finally:
        await client.close()
