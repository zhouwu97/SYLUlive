"""角色、真实发起者、会话来源和禁止优先：不以允许规则替代本人校园授权。"""
import copy
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from astrbot_plugin_sylulive.permissions import CAPABILITY_LABELS, decide


def event(sender="123456789", group="692905367", platform="snowluma", *, private=None):
    return SimpleNamespace(
        get_sender_id=lambda: sender,
        get_group_id=lambda: group,
        get_platform_id=lambda: platform,
        is_private_chat=lambda: not bool(group) if private is None else private,
        message_str="@987654321 查询他的成绩",
        role="group_owner",
    )


def rule(**changes):
    return {
        "__template_key": "access_rule",
        "name": "咕咕群本人成绩",
        "enabled": True,
        "effect": "allow",
        "capabilities": ["grades"],
        "chat_types": ["group"],
        "subjects": "specified_users",
        "user_ids": ["123456789"],
        "group_ids": ["692905367"],
        **changes,
    }


@pytest.mark.parametrize("default", [False, True])
def test_existing_install_without_rules_inherits_its_current_default(default):
    result = decide({}, event(), "unbind", default=default)
    assert result.allowed is default
    assert result.reason == ("default_allow" if default else "default_deny")


@pytest.mark.parametrize("sender,group,platform,action,expected", [
    ("123456789", "692905367", "snowluma", "grades", True),
    ("987654321", "692905367", "snowluma", "grades", False),
    ("123456789", "111111111", "snowluma", "grades", False),
    ("123456789", "692905367", "another-platform", "grades", False),
    ("123456789", "692905367", "snowluma", "erke", False),
    ("123456789", "", "snowluma", "grades", False),
])
def test_rule_matches_actual_actor_group_platform_and_capability(sender, group, platform, action, expected):
    result = decide({"owner_platform_id": "snowluma", "access_rules": [rule()]}, event(sender, group, platform), action)
    assert result.allowed is expected
    if expected:
        assert result.reason == "explicit_allow" and result.rule_name == "咕咕群本人成绩"
        assert "本人授权" in result.reason_text


@pytest.mark.parametrize("reverse", [False, True])
def test_explicit_deny_wins_even_for_native_admin_and_default_allow(reverse):
    rules = [rule(), rule(name="暂停此人查询", effect="deny")]
    if reverse:
        rules.reverse()
    result = decide({"access_rules": rules}, event(), "grades", is_admin=True, default=True)
    assert not result.allowed and result.reason == "explicit_deny"
    assert result.rule_name == "暂停此人查询"


@pytest.mark.parametrize("native_admin,expected", [(True, True), (False, False), ("true", False), (1, False)])
def test_legacy_owner_and_group_owner_are_not_plugin_administrators(native_admin, expected):
    config = {"owner_sender_id": "123456789", "access_rules": [rule(subjects="admins", user_ids=[])]}
    assert decide(config, event(), "grades", is_admin=native_admin).allowed is expected


def test_user_list_additionally_restricts_everyone_and_native_admin_roles():
    for role in ("everyone", "admins"):
        config = {"access_rules": [rule(subjects=role)]}
        assert not decide(config, event(sender="987654321"), "grades", is_admin=True).allowed


def test_private_rule_is_supported_but_a_group_filter_does_not_match_private_chat():
    config = {"access_rules": [rule(chat_types=["private"], group_ids=[])]}
    assert decide(config, event(group=""), "grades").allowed
    assert not decide(config, event(), "grades").allowed
    config["access_rules"][0]["group_ids"] = ["692905367"]
    assert not decide(config, event(group=""), "grades").allowed


def test_disabled_incomplete_rule_is_ignored_and_unmatched_rule_does_not_cancel_existing_default():
    config = {"access_rules": [{"enabled": False, "capabilities": "unfinished"}, rule(group_ids=["other-group"])]}
    assert decide(config, event(), "grades", default=True).allowed
    assert not decide(config, event(), "grades", default=False).allowed


@pytest.mark.parametrize("bad", [
    None, "allow-all", {}, [None], [{"enabled": "false"}], [{}],
    [rule(effect="approve")], [rule(capabilities=["read_any_user"])],
    [rule(capabilities=[])], [rule(chat_types=[])], [rule(chat_types=["private", "broadcast"])],
    [rule(subjects="group_owner")], [rule(user_ids=[])], [rule(user_ids=[123456789])],
    [rule(group_ids="692905367")], [rule(group_ids=[""])], [rule(name=None)],
])
def test_invalid_active_policy_never_falls_back_to_allow(bad):
    result = decide({"access_rules": bad}, event(), "grades", is_admin=True, default=True)
    assert not result.allowed and result.reason == "invalid_policy"


def test_bad_rule_after_a_matching_allow_is_still_rejected():
    result = decide({"access_rules": [rule(), {"effect": "allow"}]}, event(), "grades", default=True)
    assert not result.allowed and result.reason == "invalid_policy"


def test_strict_allowlist_rejects_unmatched_users_even_with_existing_private_default_allow():
    allow = rule(chat_types=["private"], group_ids=[])
    config = {"access_default": "deny", "access_rules": [allow]}
    assert decide(config, event(group=""), "grades", default=True).allowed
    unmatched = event(sender="987654321", group="")
    assert not decide(config, unmatched, "grades", default=True).allowed
    config["access_default"] = "inherit"
    assert decide(config, unmatched, "grades", default=True).allowed


def test_strict_allowlist_applies_to_every_capability_and_both_chat_types_without_admin_bypass():
    config = {"access_default": "deny", "access_rules": [rule()]}
    assert decide(config, event(), "grades", default=True).allowed
    for source in (event(group=""), event(group="111111111")):
        assert not decide(config, source, "grades", is_admin=True, default=True).allowed
    for action in ("public_read", "bind", "status", "unbind", "checkin", "erke"):
        assert not decide(config, event(), action, is_admin=True, default=True).allowed
    config["access_rules"].append(rule(effect="deny"))
    result = decide(config, event(), "grades", default=True)
    assert not result.allowed and result.reason == "explicit_deny"


def test_unknown_unmatched_mode_fails_closed_even_when_an_allow_rule_matches():
    for value in (None, "allow", "DENY", True, 1, [], {}):
        result = decide({"access_default": value, "access_rules": [rule()]}, event(), "grades", default=True)
        assert not result.allowed and result.reason == "invalid_policy"


def test_strict_allowlist_option_is_explicit_and_accepted_by_native_config_validator():
    from astrbot.dashboard.services.config_service import validate_config

    schema = json.loads((Path(__file__).resolve().parents[1] / "_conf_schema.json").read_text(encoding="utf-8"))
    option = schema["access_default"]
    assert option["default"] == "inherit" and option["options"] == ["inherit", "deny"]
    assert "私聊和群聊" in option["hint"] and "解绑" in option["hint"]
    data = {key: copy.deepcopy(field["default"]) for key, field in schema.items()}
    data.update(access_default="deny", access_rules=[rule()])
    errors, _ = validate_config(data, schema, is_core=False)
    assert errors == [] and decide(data, event(), "grades", default=True).allowed
    assert not decide(data, event(sender="987654321"), "grades", default=True).allowed


@pytest.mark.parametrize("source", [
    event(sender=""), event(sender=None), event(platform=""),
    event(group="692905367", private=True), event(group="", private=False),
])
def test_missing_or_conflicting_real_context_fails_closed(source):
    result = decide({"access_rules": [rule(subjects="everyone", user_ids=[], group_ids=[])]}, source, "grades", default=True)
    assert not result.allowed and result.reason == "invalid_context"


def test_empty_platform_selector_accepts_context_for_callers_native_qq_selection():
    assert decide({"owner_platform_id": "", "access_rules": [rule()]}, event(), "grades").allowed
    assert not decide({}, event(), "unknown_capability", default=True).allowed


def test_native_schema_explains_each_capability_and_keeps_private_features_opt_in():
    schema = json.loads((Path(__file__).resolve().parents[1] / "_conf_schema.json").read_text(encoding="utf-8"))
    fields = schema["access_rules"]["templates"]["access_rule"]["items"]
    assert set(fields["capabilities"]["options"]) == set(CAPABILITY_LABELS)
    assert len(fields["capabilities"]["labels"]) == len(fields["capabilities"]["subtitles"]) == len(CAPABILITY_LABELS)
    assert schema["group_personal_delivery"]["default"] == "confirm"
    assert schema["binding_link_delivery"]["default"] == "auto"
    assert schema["allow_multi_user"]["default"] is True
    for key in ("allow_group_binding", "allow_personal_queries", "allow_proposals", "allow_private_review", "allow_checkin"):
        assert schema[key]["default"] is False
    assert "非管理员" in schema["owner_sender_id"]["description"]
    assert "AstrBot 后台" in schema["access_rules"]["hint"]
    assert all(field.get("description") and field.get("hint") for field in fields.values())
    assert "_special" not in fields["user_ids"], "fixed 4.29.3 frontend does not implement the newer user picker"


def test_schema_defaults_and_real_rule_pass_astrbot_native_configuration_validator():
    from astrbot.dashboard.services.config_service import validate_config

    schema = json.loads((Path(__file__).resolve().parents[1] / "_conf_schema.json").read_text(encoding="utf-8"))
    data = {key: copy.deepcopy(field["default"]) for key, field in schema.items()}
    data["access_rules"] = [rule()]
    errors, _ = validate_config(data, schema, is_core=False)
    assert errors == []
    assert decide(data, event(), "grades").allowed
