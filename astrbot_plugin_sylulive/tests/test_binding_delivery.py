"""临时链接投递按真实消息主体，网络不确定时仅按管理员模式回当前事件。"""

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from astrbot_plugin_sylulive.binding_delivery import deliver_binding_link
from astrbot_plugin_sylulive.client import IntegrationProblem


ORIGIN = "https://fixture.invalid"
LINK = {"user_code": "ABCD-1234", "verification_uri": ORIGIN + "/web/connected-apps?user_code=ABCD-1234"}


def event(actor="123456789", group="692905367", bot="2170194804"):
    return SimpleNamespace(
        get_sender_id=lambda: actor,
        get_group_id=lambda: group,
        is_private_chat=lambda: not group,
        message_obj=SimpleNamespace(self_id=bot),
        message_str="/sylu-connect @987654321",
    )


@pytest.mark.asyncio
async def test_group_delivery_returns_current_reply_without_any_other_send():
    incoming = event()
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock())
    fallback = AsyncMock()
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery="group", send_private=fallback)
    assert LINK["verification_uri"] in result.group_text
    assert "QQ 123456789" in result.group_text and "987654321" not in result.group_text
    assert not result.private_confirmed and not result.used_fallback
    incoming.bot.send_private_msg.assert_not_awaited()
    fallback.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize("delivery", ["private", "auto", "group"])
async def test_private_request_replies_in_place_and_does_not_send_again(delivery):
    incoming = event(group="")
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock())
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery=delivery)
    assert LINK["verification_uri"] in result.group_text and "QQ 123456789" in result.group_text
    incoming.bot.send_private_msg.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize("response", [{"message_id": 321}, {"message_id": -321}, {"message_id": "321"}])
async def test_native_success_uses_real_sender_group_and_bot_but_does_not_disclose_link_to_group(response):
    incoming = event()
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value=response))
    fallback = AsyncMock()
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery="auto", send_private=fallback)
    assert result.private_confirmed and not result.used_fallback
    assert LINK["user_code"] not in result.group_text and "https://" not in result.group_text
    params = incoming.bot.send_private_msg.await_args.kwargs
    assert params["user_id"] == 123456789 and params["group_id"] == 692905367
    assert params["self_id"] == "2170194804"
    assert LINK["verification_uri"] in params["message"][0]["data"]["text"]
    incoming.bot.send_private_msg.assert_awaited_once()
    fallback.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize("response", [None, False, True, {}, {"message_id": 0}, {"message_id": True}, {"message_id": 123, "status": "failed"}, {"message_id": 123, "retcode": 1}])
async def test_native_ambiguous_or_failed_result_uses_only_configured_group_fallback(response):
    incoming = event()
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value=response))
    fallback = AsyncMock()
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery="auto", send_private=fallback)
    assert not result.private_confirmed and result.used_fallback
    assert "按管理员设置" in result.group_text and LINK["verification_uri"] in result.group_text
    assert "尚未绑定" not in result.group_text
    incoming.bot.send_private_msg.assert_awaited_once()
    fallback.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize("delivery", ["private", "auto"])
async def test_timeout_is_not_retried_or_echoed_and_does_not_claim_request_never_existed(delivery):
    incoming = event()
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock(side_effect=TimeoutError("sd_must-never-leak")))
    fallback = AsyncMock()
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery=delivery, send_private=fallback)
    assert "sd_must-never-leak" not in result.group_text and "尚未绑定" not in result.group_text
    assert (LINK["verification_uri"] in result.group_text) is (delivery == "auto")
    assert result.used_fallback is (delivery == "auto")
    incoming.bot.send_private_msg.assert_awaited_once()
    fallback.assert_not_awaited()


@pytest.mark.asyncio
async def test_sdk_fallback_receives_same_event_without_a_model_selected_recipient():
    incoming = event()
    fallback = AsyncMock(return_value=True)
    result = await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery="private", send_private=fallback)
    assert result.private_confirmed
    args = fallback.await_args.args
    assert args[0] is incoming and LINK["verification_uri"] in args[1]
    fallback.assert_awaited_once()


@pytest.mark.asyncio
async def test_distinct_group_events_are_never_routed_to_previous_group_or_actor():
    first, second = event(), event(actor="987654321", group="123456789", bot="1234512345")
    for incoming in (first, second):
        incoming.bot = SimpleNamespace(send_private_msg=AsyncMock(return_value={"message_id": 1}))
        await deliver_binding_link(incoming, LINK, origin=ORIGIN, delivery="private")
        params = incoming.bot.send_private_msg.await_args.kwargs
        assert params["user_id"] == int(incoming.get_sender_id())
        assert params["group_id"] == int(incoming.get_group_id())
        assert params["self_id"] == incoming.message_obj.self_id


@pytest.mark.asyncio
@pytest.mark.parametrize("uri", [
    "https://other.invalid/web/connected-apps?user_code=ABCD-1234",
    ORIGIN + "/web/connected-apps?user_code=ABCD-1234&device_code=sd_secret",
    ORIGIN + "/web/connected-apps?user_code=ABCD-1234&qq=987654321",
    ORIGIN + "/web/connected-apps?user_code=ABCD-1234&user_code=ABCD-1234",
    ORIGIN + "/web/connected-apps?user_code=ABCD-1234#sa_secret",
    ORIGIN + "/web/connected-apps?user_code=ABCD-5678",
    ORIGIN + "/other?user_code=ABCD-1234",
    "https://sa_secret@fixture.invalid/web/connected-apps?user_code=ABCD-1234",
])
async def test_rejects_redirects_credentials_or_target_changes_before_any_send(uri):
    incoming = event()
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock())
    with pytest.raises(IntegrationProblem, match="invalid_binding_link"):
        await deliver_binding_link(incoming, {**LINK, "verification_uri": uri}, origin=ORIGIN)
    incoming.bot.send_private_msg.assert_not_awaited()


@pytest.mark.asyncio
async def test_only_safe_link_fields_are_projected_and_raw_secret_cannot_be_a_code():
    result = await deliver_binding_link(event(), {**LINK, "device_code": "sd_private", "access_token": "sa_private", "refresh_token": "sr_private", "message": "secret additional text"}, origin=ORIGIN, delivery="group")
    assert all(secret not in result.group_text for secret in ("sd_private", "sa_private", "sr_private", "secret additional text"))
    for secret in ("sd_private", "sa_private", "sr_private"):
        with pytest.raises(IntegrationProblem, match="invalid_binding_link"):
            await deliver_binding_link(event(), {**LINK, "user_code": secret}, origin=ORIGIN)


@pytest.mark.asyncio
@pytest.mark.parametrize("incoming", [event(actor=""), event(bot=""), event(actor="123:FriendMessage:987"), event(group="1\n2")])
async def test_rejects_invalid_event_identity_before_transport(incoming):
    incoming.bot = SimpleNamespace(send_private_msg=AsyncMock())
    with pytest.raises(IntegrationProblem, match="invalid_message_context"):
        await deliver_binding_link(incoming, LINK, origin=ORIGIN)
    incoming.bot.send_private_msg.assert_not_awaited()
