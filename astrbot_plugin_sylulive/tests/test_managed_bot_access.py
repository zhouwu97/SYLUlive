import copy
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess


def bot():
    return {"bot": {"bot_user_id": 71, "enabled": True, "policy": {
        "public_read_enabled": True, "allowed_post_types": ["campus_life"],
        "reply_enabled": False, "sticker_enabled": False}}}


@pytest.mark.asyncio
async def test_bound_bot_uses_only_authenticated_public_reader_and_revalidates_policy():
    response = {"data": {"items": []}}
    client = SimpleNamespace(generation=1, call=AsyncMock(side_effect=[bot(), response, bot()]))
    assert await ManagedBotAccess(client)("/api/integrations/v1/public/community/posts", params={"limit": 5}) == response
    assert [c.args for c in client.call.call_args_list] == [
        ("GET", "/bot/policy"), ("GET", "/community/posts"), ("GET", "/bot/policy")]
    assert client.call.call_args_list[1].kwargs == {"params": {"limit": 5}}


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["paused", "read_off", "no_bot", "empty", "malformed"])
async def test_disabled_or_invalid_server_bot_never_reads_sources(change):
    policy = bot()
    if change == "paused": policy["bot"]["enabled"] = False
    if change == "read_off": policy["bot"]["policy"]["public_read_enabled"] = False
    if change == "no_bot": policy["bot"] = None
    if change == "empty": policy["bot"]["policy"]["allowed_post_types"] = []
    if change == "malformed": policy["bot"]["policy"]["allowed_post_types"] = [7]
    client = SimpleNamespace(generation=1, call=AsyncMock(return_value=policy))
    with pytest.raises(IntegrationProblem, match="bot_read_disabled"):
        await ManagedBotAccess(client)("/api/integrations/v1/public/community/posts")
    assert client.call.await_count == 1


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["policy", "account"])
async def test_inflight_policy_or_binding_switch_cannot_return_old_source(change):
    current = bot()
    async def call(method, path, **kwargs):
        if path == "/bot/policy": return copy.deepcopy(current)
        if change == "policy": current["bot"]["policy"]["allowed_post_types"] = ["course_study"]
        else: client.generation += 1
        return {"data": {"content": "not allowed to leave wrapper"}}
    client = SimpleNamespace(generation=1, call=call)
    with pytest.raises(IntegrationProblem, match="bot_policy_changed"):
        await ManagedBotAccess(client)("/api/integrations/v1/public/community/posts/1")


@pytest.mark.asyncio
@pytest.mark.parametrize("path", ["https://private.invalid/", "/api/user/profile", "/api/integrations/v1/public/community/posts/1?x=1", "/api/integrations/v1/public/community/posts/../me"])
async def test_arbitrary_private_path_is_rejected_before_credentials_are_used(path):
    client = SimpleNamespace(generation=1, call=AsyncMock())
    with pytest.raises(IntegrationProblem, match="public_path_refused"):
        await ManagedBotAccess(client)(path)
    client.call.assert_not_called()
