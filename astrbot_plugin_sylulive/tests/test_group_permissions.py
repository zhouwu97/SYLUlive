"""真实消息主体的群内本人操作：入口权限不等于他人校园数据权限。"""
import re
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from test_group_public_read import fixture
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.group_confirmations import GroupConfirmations


GROUP = "692905367"
BOT = "2170194804"
FIRST = "123456789"
SECOND = "987654321"
OWNER = "3170305904"


def source(sender=FIRST, group=GROUP, *, platform="configured-platform", bot=BOT):
    _, event, _ = fixture(sender=sender, group=group, platform=platform)
    event.message_obj.self_id = bot
    return event


def allow_rule(*actions, effect="allow", users=None, groups=None, subjects="everyone"):
    return {
        "name": "群内本人操作", "enabled": True, "effect": effect,
        "capabilities": list(actions), "chat_types": ["group"],
        "subjects": subjects, "user_ids": [] if users is None else users,
        "group_ids": [GROUP] if groups is None else groups,
    }


class Client:
    def __init__(self, actor):
        self.actor = actor
        self.tokens = {"scope": "profile:read_minimal checkin:write academic:grades:read academic:erke:read"}
        self.pending = None
        self.generation = 0
        self.calls = []
        self.disconnected = 0
        self.begins = []
        self.reject = None
        self.store = SimpleNamespace(persistent=False)

    async def begin(self, installation, name, proposals, **options):
        self.begins.append((installation, name, proposals, options))
        code = "CODE-" + self.actor
        self.pending = {"device_code": "sd-only-" + self.actor}
        return {"user_code": code, "verification_uri": "https://fixture.invalid/web/connected-apps?user_code=" + code}

    async def poll(self):
        self.pending = None

    async def disconnect(self):
        self.disconnected += 1
        self.tokens = None
        self.pending = None
        self.generation += 1

    async def call(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if self.reject:
            raise IntegrationProblem(self.reject)
        if not self.tokens:
            raise IntegrationProblem("invalid_token")
        required = {"/me/grades": "academic:grades:read", "/me/erke": "academic:erke:read", "/me/checkin": "checkin:write"}.get(path)
        if required and required not in self.tokens["scope"].split():
            raise IntegrationProblem("insufficient_scope")
        if path == "/me/checkin":
            return {"data": {"already": False, "checked_in": True, "streak_days": 2, "exp_earned": 3, "check_in_date": "2026-11-01"}}
        if path == "/me/grades":
            return {"data": {"dataset": "grades", "grades": [{"course_name": "私人成绩-" + self.actor, "fraction": 81}], "fetched_at": "2026-11-01T00:00:00Z"}}
        if path == "/me/erke":
            return {"data": {"dataset": "erke", "summary": {"graduation": {"official_conclusion": "私人二课-" + self.actor}}, "fetched_at": "2026-11-01T00:00:00Z"}}
        return {"account": {"nickname": "合成账号-" + self.actor}}


class Accounts:
    def __init__(self):
        self.clients = {(BOT, actor): Client(actor) for actor in (FIRST, SECOND)}
        self.lookups = []

    def get(self, actor, bot, *, create=False):
        self.lookups.append((actor, bot, create))
        key = (bot, actor)
        if key not in self.clients:
            if not create:
                raise IntegrationProblem("connect_first")
            self.clients[key] = Client(actor)
        return self.clients[key], "installation-" + bot + "-" + actor


def group_fixture(*, mode="direct", rules=None):
    plugin, _, _ = fixture(group=GROUP, sender=FIRST)
    plugin.owner = OWNER
    plugin.origin = "https://fixture.invalid"
    plugin.config.update(
        owner_platform_id="configured-platform", allow_multi_user=True,
        allow_group_binding=True, allow_personal_queries=True, allow_checkin=True,
        public_read_group_ids=[GROUP], public_read_all_sessions=False,
        group_personal_delivery=mode, binding_link_delivery="group",
        access_rules=[] if rules is None else rules,
    )
    plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": [OWNER]})
    plugin.client = Client(OWNER)
    plugin.accounts = Accounts()
    plugin.send_review_message = AsyncMock(return_value=True)
    plugin.group_confirmations = GroupConfirmations()
    return plugin, source(), plugin.accounts


def text(results):
    return "\n".join(part.text for result in results for part in result.chain if hasattr(part, "text"))


async def invoke(handler, *args):
    return text([result async for result in handler(*args)])


def code_from(message):
    match = re.search(r"/sylu-share (gp_[A-Za-z0-9_-]+)", message)
    assert match, message
    return match[1]


@pytest.mark.asyncio
async def test_group_unbind_defaults_to_real_sender_and_leaves_other_and_owner_connected():
    plugin, first, accounts = group_fixture()
    first.message_str = "/sylu-disconnect @" + SECOND
    result = await invoke(plugin.disconnect, first)
    assert "已断开" in result and first.is_stopped()
    assert accounts.clients[(BOT, FIRST)].tokens is None
    assert accounts.clients[(BOT, SECOND)].tokens is not None
    assert plugin.client.tokens is not None and plugin.client.disconnected == 0
    assert {actor for actor, _, _ in accounts.lookups} == {FIRST}
    second = source(SECOND)
    assert "已断开" in await invoke(plugin.disconnect, second)
    assert accounts.clients[(BOT, SECOND)].tokens is None


@pytest.mark.asyncio
@pytest.mark.parametrize("condition", ["other_group", "other_platform", "deny"])
async def test_group_unbind_denial_never_touches_any_account(condition):
    plugin, event, accounts = group_fixture(rules=[allow_rule("unbind")])
    if condition == "other_group": event = source(group="111111111")
    if condition == "other_platform": event = source(platform="other-platform")
    if condition == "deny": plugin.config["access_rules"].append(allow_rule("unbind", effect="deny"))
    result = await invoke(plugin.disconnect, event)
    assert "已断开" not in result and event.is_stopped()
    assert not accounts.lookups and all(client.disconnected == 0 for client in accounts.clients.values())
    assert plugin.client.disconnected == 0


@pytest.mark.asyncio
async def test_disabling_query_features_does_not_prevent_explicitly_allowed_self_unbind():
    plugin, event, accounts = group_fixture(rules=[allow_rule("unbind")])
    plugin.config.update(allow_group_binding=False, allow_multi_user=False, allow_personal_queries=False, allow_checkin=False)
    assert "已断开" in await invoke(plugin.disconnect, event)
    assert accounts.clients[(BOT, FIRST)].disconnected == 1


@pytest.mark.asyncio
async def test_group_checkin_uses_actual_initiator_even_when_that_initiator_is_native_admin():
    plugin, event, accounts = group_fixture(rules=[allow_rule("checkin")])
    plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": [FIRST]})
    event.message_str = "替" + SECOND + "签到"
    result = await invoke(plugin.daily_checkin, event)
    assert "签到成功" in result and event.is_stopped()
    assert [(method, path) for method, path, _ in accounts.clients[(BOT, FIRST)].calls] == [("POST", "/me/checkin")]
    assert not accounts.clients[(BOT, SECOND)].calls and not plugin.client.calls


@pytest.mark.asyncio
@pytest.mark.parametrize("gate", ["local_switch", "scope", "rule"])
async def test_group_checkin_requires_feature_scope_and_permission_without_owner_fallback(gate):
    plugin, event, accounts = group_fixture(rules=[allow_rule("checkin")])
    own = accounts.clients[(BOT, FIRST)]
    if gate == "local_switch": plugin.config["allow_checkin"] = False
    if gate == "scope": own.tokens["scope"] = "profile:read_minimal"
    if gate == "rule": plugin.config["access_rules"].append(allow_rule("checkin", effect="deny"))
    assert "签到成功" not in await plugin.checkin_result(event, submit=True)
    assert not own.calls and not plugin.client.calls


@pytest.mark.asyncio
@pytest.mark.parametrize("dataset", ["grades", "erke"])
async def test_group_direct_queries_are_isolated_by_real_sender_and_do_not_enter_owner_account(dataset):
    plugin, first, accounts = group_fixture(rules=[allow_rule(dataset)])
    for actor in (FIRST, SECOND):
        event = first if actor == FIRST else source(actor)
        event.message_str = "/sylu-grades @" + OWNER
        result = await plugin.personal_result(event, dataset)
        assert actor in result and OWNER not in result
        assert (SECOND if actor == FIRST else FIRST) not in result
        own = accounts.clients[(BOT, actor)]
        assert own.calls == [("GET", "/me/" + dataset, {"params": {"offset": 0, "limit": 20}})]
    assert not plugin.client.calls


@pytest.mark.asyncio
async def test_group_direct_query_scope_rejection_does_not_return_or_retry_with_another_identity():
    plugin, event, accounts = group_fixture(rules=[allow_rule("grades")])
    own = accounts.clients[(BOT, FIRST)]
    own.tokens["scope"] = "profile:read_minimal"
    result = await plugin.personal_result(event, "grades")
    assert "私人成绩" not in result and "权限" in result
    assert len(own.calls) == 1 and not accounts.clients[(BOT, SECOND)].calls and not plugin.client.calls


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["direct", "private"])
@pytest.mark.parametrize("change", ["rule", "feature", "delivery", "connection", "admin"])
async def test_private_result_is_withheld_if_permission_or_connection_changes_during_read(mode, change):
    plugin, event, accounts = group_fixture(mode=mode, rules=[allow_rule("grades")])
    own = accounts.clients[(BOT, FIRST)]
    read = own.call
    if change == "admin":
        plugin.config["access_rules"] = [allow_rule("grades", subjects="admins")]
        plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": [FIRST]})

    async def changing_read(*args, **kwargs):
        result = await read(*args, **kwargs)
        if change == "rule": plugin.config["access_rules"].append(allow_rule("grades", effect="deny"))
        if change == "feature": plugin.config["allow_personal_queries"] = False
        if change == "delivery": plugin.config["group_personal_delivery"] = "confirm"
        if change == "connection": own.generation += 1
        if change == "admin": plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": []})
        return result

    own.call = changing_read
    event.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value={"message_id": 77}))
    result = await plugin.personal_result(event, "grades")
    assert "已变化" in result and "私人成绩" not in result
    event.bot.send_private_msg.assert_not_awaited()
    plugin.send_review_message.assert_not_awaited()
    assert len(own.calls) == 1 and not plugin.client.calls


@pytest.mark.asyncio
async def test_group_private_delivery_uses_only_the_real_sender_and_never_echoes_content_to_group():
    plugin, event, accounts = group_fixture(mode="private", rules=[allow_rule("grades")])
    event.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value={"message_id": 77}))
    result = await plugin.personal_result(event, "grades")
    assert "私聊" in result and "私人成绩" not in result
    sent = event.bot.send_private_msg.await_args.kwargs
    assert sent["user_id"] == int(FIRST) and sent["group_id"] == int(GROUP) and sent["self_id"] == BOT
    assert "私人成绩-" + FIRST in sent["message"][0]["data"]["text"]
    plugin.send_review_message.assert_not_awaited()
    assert not plugin.client.calls and not accounts.clients[(BOT, SECOND)].calls


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [False, RuntimeError("uncertain transport")])
async def test_private_result_delivery_failure_never_falls_back_into_group(failure):
    plugin, event, _ = group_fixture(mode="private", rules=[allow_rule("grades")])
    plugin.send_review_message = AsyncMock(return_value=False, side_effect=failure if isinstance(failure, Exception) else None)
    result = await plugin.personal_result(event, "grades")
    assert "未能确认" in result and "私人成绩" not in result
    assert plugin.send_review_message.await_count == 1
    assert plugin.send_review_message.await_args.args[0] == "configured-platform:FriendMessage:" + FIRST


@pytest.mark.asyncio
async def test_new_install_can_bind_without_legacy_owner_or_fixed_platform_and_does_not_claim_admin():
    plugin, event, accounts = group_fixture(rules=[allow_rule("bind")])
    plugin.owner, plugin.platform = "", ""
    plugin.config.update(owner_sender_id="", owner_platform_id="")
    plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": []})
    assert plugin.platform_allowed(event) and not plugin.is_bot_admin(event)
    result = await invoke(plugin.connect, event)
    assert FIRST in result and "https://fixture.invalid/web/connected-apps" in result
    assert accounts.clients[(BOT, FIRST)].begins[0][1].startswith("QQ " + FIRST)
    assert not plugin.client.begins and not plugin.client.calls


@pytest.mark.asyncio
async def test_legacy_owner_field_does_not_grant_native_admin_rule_access():
    plugin, _, accounts = group_fixture(rules=[allow_rule("grades", subjects="admins")])
    event = source(OWNER)
    plugin.context = SimpleNamespace(get_config=lambda **_: {"admins_id": []})
    assert not plugin.is_bot_admin(event)
    result = await plugin.personal_result(event, "grades")
    assert "私人成绩" not in result and not plugin.client.calls and not accounts.lookups
