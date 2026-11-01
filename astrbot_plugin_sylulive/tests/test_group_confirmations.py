"""群内本人确认后才读、才展示；确认不跨人、跨群、跨机器人或重放。"""
import asyncio

import pytest

from astrbot_plugin_sylulive.group_confirmations import ConfirmationProblem, GroupConfirmations
from test_group_permissions import BOT, FIRST, SECOND, GROUP, allow_rule, code_from, group_fixture, invoke, source


@pytest.mark.asyncio
async def test_confirmation_first_returns_metadata_only_then_original_sender_reads_fresh_once():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    own = accounts.clients[(BOT, FIRST)]
    message = await plugin.personal_result(event, "grades", 20)
    code = code_from(message)
    assert "尚未读取" in message and "私人成绩" not in message
    assert not own.calls and not plugin.client.calls
    row = plugin.group_confirmations.rows[code]
    assert row["params"] == {"offset": 20}
    assert set(row) == {"actor", "action", "params", "generation", "stamp", "expires"}
    result = await invoke(plugin.share_private_review, event, code)
    assert "私人成绩-" + FIRST in result and event.is_stopped()
    assert own.calls == [("GET", "/me/grades", {"params": {"offset": 20, "limit": 20}})]
    result = await plugin.group_personal_decision(event, code, True)
    assert "私人成绩" not in result and len(own.calls) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize("wrong", [
    source(SECOND), source(group="111111111"), source(bot="111111112"),
    source(platform="different-platform"), source(group=""),
])
async def test_wrong_sender_group_bot_platform_or_private_chat_cannot_read_or_consume_rightful_confirmation(wrong):
    plugin, original, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    code = code_from(await plugin.personal_result(original, "grades"))
    result = await plugin.group_personal_decision(wrong, code, True)
    assert "私人成绩" not in result and "确认码" in result
    assert code in plugin.group_confirmations.rows
    assert not any(client.calls for client in accounts.clients.values())
    assert "私人成绩-" + FIRST in await plugin.group_personal_decision(original, code, True)


@pytest.mark.asyncio
async def test_expired_confirmation_is_consumed_without_reading_private_data():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    clock = [10.0]
    plugin.group_confirmations = GroupConfirmations(now=lambda: clock[0])
    code = code_from(await plugin.personal_result(event, "grades"))
    clock[0] += 301
    result = await plugin.group_personal_decision(event, code, True)
    assert "过期" in result and "私人成绩" not in result
    assert code not in plugin.group_confirmations.rows
    assert not any(client.calls for client in accounts.clients.values())


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["new_generation", "permission_denied", "delivery_changed", "feature_disabled"])
async def test_connection_or_policy_change_invalidates_old_confirmation_without_read(change):
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    code = code_from(await plugin.personal_result(event, "grades"))
    own = accounts.clients[(BOT, FIRST)]
    if change == "new_generation": own.generation += 1
    if change == "permission_denied": plugin.config["access_rules"].append(allow_rule("grades", effect="deny"))
    if change == "delivery_changed": plugin.config["group_personal_delivery"] = "direct"
    if change == "feature_disabled": plugin.config["allow_personal_queries"] = False
    result = await plugin.group_personal_decision(event, code, True)
    assert "变化" in result and "私人成绩" not in result
    assert not own.calls and not plugin.client.calls
    assert code not in plugin.group_confirmations.rows


@pytest.mark.asyncio
async def test_remote_revocation_is_rechecked_on_confirm_and_never_returns_stale_or_other_account_data():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    code = code_from(await plugin.personal_result(event, "grades"))
    own = accounts.clients[(BOT, FIRST)]
    own.reject = "invalid_token"
    result = await plugin.group_personal_decision(event, code, True)
    assert "私人成绩" not in result
    assert len(own.calls) == 1 and not accounts.clients[(BOT, SECOND)].calls and not plugin.client.calls


@pytest.mark.asyncio
async def test_group_cancel_consumes_own_code_without_query_and_share_after_cancel_is_rejected():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("erke")])
    code = code_from(await plugin.personal_result(event, "erke"))
    result = await invoke(plugin.cancel_private_review, event, code)
    assert "已取消" in result and event.is_stopped()
    assert "私人二课" not in await plugin.group_personal_decision(event, code, True)
    assert not any(client.calls for client in accounts.clients.values())


@pytest.mark.asyncio
async def test_parallel_share_requests_read_at_most_once():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    code = code_from(await plugin.personal_result(event, "grades"))
    results = await asyncio.gather(*[plugin.group_personal_decision(event, code, True) for _ in range(4)])
    assert sum("私人成绩-" + FIRST in result for result in results) == 1
    assert len(accounts.clients[(BOT, FIRST)].calls) == 1


@pytest.mark.asyncio
async def test_new_same_query_replaces_old_code_and_scope_rejection_never_creates_a_confirmation():
    plugin, event, accounts = group_fixture(mode="confirm", rules=[allow_rule("grades")])
    first = code_from(await plugin.personal_result(event, "grades", 0))
    second = code_from(await plugin.personal_result(event, "grades", 20))
    assert first != second and first not in plugin.group_confirmations.rows
    assert "私人成绩" not in await plugin.group_personal_decision(event, first, True)
    own = accounts.clients[(BOT, FIRST)]
    own.tokens["scope"] = "profile:read_minimal"
    message = await plugin.personal_result(event, "grades", 40)
    assert "gp_" not in message and "权限" in message
    assert not own.calls


@pytest.mark.asyncio
async def test_confirmation_store_replaces_own_existing_request_even_at_capacity_and_does_not_evict_other_user():
    clock = [10.0]
    store = GroupConfirmations(now=lambda: clock[0], limit=1)
    first = await store.create(source(), "grades", {"offset": 0}, 0, "policy")
    replacement = await store.create(source(), "grades", {"offset": 20}, 0, "policy")
    assert replacement != first and first not in store.rows
    with pytest.raises(ConfirmationProblem, match="较多"):
        await store.create(source(SECOND), "grades", {"offset": 0}, 0, "policy")
    assert replacement in store.rows
    clock[0] += 301
    next_code = await store.create(source(SECOND), "grades", {"offset": 0}, 0, "policy")
    assert next_code in store.rows and replacement not in store.rows


@pytest.mark.asyncio
@pytest.mark.parametrize("field,value", [("bot", None), ("bot", ""), ("platform", ""), ("sender", ""), ("group", "")])
async def test_confirmation_store_rejects_missing_real_identity(field, value):
    options = {"sender": FIRST, "group": GROUP, "platform": "configured-platform", "bot": BOT}
    options[field] = value
    event = source(**options)
    store = GroupConfirmations()
    with pytest.raises(ConfirmationProblem):
        await store.create(event, "grades", {"offset": 0}, 0, "policy")
    assert not store.rows
