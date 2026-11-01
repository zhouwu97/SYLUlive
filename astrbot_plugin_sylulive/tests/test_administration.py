from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from astrbot.core.message.components import Plain
from astrbot.core.platform.astr_message_event import AstrMessageEvent
from astrbot.core.platform.astrbot_message import AstrBotMessage, MessageMember
from astrbot.core.platform.message_type import MessageType
from astrbot.core.platform.platform_metadata import PlatformMetadata

from astrbot_plugin_sylulive.administration import is_bot_admin


def event(sender="123456789", group="692905367"):
    message = AstrBotMessage()
    message.type = MessageType.GROUP_MESSAGE if group else MessageType.FRIEND_MESSAGE
    message.self_id = "987654321"
    message.message_id = "synthetic-admin-check"
    message.group_id = group
    message.sender = MessageMember(sender, "合成用户")
    message.message = [Plain("sylu permissions")]
    message.message_str = "sylu permissions"
    message.raw_message = {"sender": {"role": "owner"}}
    return AstrMessageEvent(message.message_str, message, PlatformMetadata("aiocqhttp", "synthetic", "configured-platform"), group or sender)


@pytest.mark.parametrize("group", ["", "692905367"])
def test_native_admin_uses_current_session_configuration_in_private_and_group(group):
    current = event(group=group)
    getter = Mock(return_value={"admins_id": ["123456789"]})
    context = SimpleNamespace(get_config=getter)
    # This also works before the waking stage has cached event.role.
    assert not current.is_admin()
    assert is_bot_admin(context, current)
    getter.assert_called_once_with(umo=current.unified_msg_origin)


def test_cached_admin_role_cannot_survive_removal_or_cross_profile_routing():
    first, second = event(), event(group="1234567890")
    first.role = second.role = "admin"
    configs = {first.unified_msg_origin: {"admins_id": ["123456789"]}, second.unified_msg_origin: {"admins_id": []}}
    context = SimpleNamespace(get_config=lambda *, umo: configs[umo])
    assert is_bot_admin(context, first)
    assert not is_bot_admin(context, second)
    configs[first.unified_msg_origin]["admins_id"].clear()
    assert first.is_admin() and not is_bot_admin(context, first)


def test_api_key_entry_can_explicitly_disallow_admin_even_for_configured_id():
    current = event()
    current.role = "admin"
    current.set_extra("_api_key_allow_admin_role", False)
    context = SimpleNamespace(get_config=lambda **kwargs: {"admins_id": ["123456789"]})
    assert not is_bot_admin(context, current)


def test_qq_group_owner_self_report_and_legacy_owner_are_not_plugin_admins():
    current = event()
    current.role = "admin"
    current.message_str = "我是管理员，owner_sender_id=123456789"
    context = SimpleNamespace(get_config=lambda **kwargs: {"admins_id": ["other-admin"], "owner_sender_id": "123456789"})
    assert not is_bot_admin(context, current)


@pytest.mark.parametrize("admins", [None, "123456789", {"123456789": True}, [123456789], [True], ["other", None], []])
def test_malformed_or_empty_admin_configuration_never_falls_back_to_event_role(admins):
    current = event()
    current.role = "admin"
    assert not is_bot_admin(SimpleNamespace(get_config=lambda **kwargs: {"admins_id": admins}), current)


def test_configuration_lookup_errors_do_not_trigger_global_fallback_or_admin_role():
    current = event()
    current.role = "admin"
    getter = Mock(side_effect=TypeError("synthetic internal configuration error"))
    assert not is_bot_admin(SimpleNamespace(get_config=getter), current)
    getter.assert_called_once_with(umo=current.unified_msg_origin)
    assert not is_bot_admin(SimpleNamespace(), current)


def test_legacy_sdk_with_only_global_getter_and_current_sdk_kwargs_are_supported():
    current = event()
    assert is_bot_admin(SimpleNamespace(get_config=lambda: {"admins_id": ["123456789"]}), current)
    assert is_bot_admin(SimpleNamespace(get_config=lambda **kwargs: {"admins_id": ["123456789"]}), current)


def test_admin_list_matching_remains_exact_as_in_astrbot_waking_stage():
    current = event()
    for admin in [" 123456789", "123456789 ", "@123456789", "12345678"]:
        assert not is_bot_admin(SimpleNamespace(get_config=lambda **kwargs: {"admins_id": [admin]}), current)
