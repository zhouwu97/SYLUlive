"""真实 SDK 事件与原生偏好接口契约；所有发送均为隔离替身，不外发私有信息。"""

from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import AsyncMock
import json
import pytest

pytest.importorskip("astrbot.api")
from astrbot_plugin_sylulive.private_review import PrivateReview, ReviewProblem
from astrbot_plugin_sylulive.client import IntegrationProblem
from test_group_public_read import fixture


def setup(sender="owner", admin="owner"):
    plugin, event, _ = fixture(sender=sender)
    plugin.config["allow_private_review"] = True
    plugin.context = SimpleNamespace(
        get_config=lambda **k: {"admins_id": [admin]},
        conversation_manager=SimpleNamespace(
            get_curr_conversation_id=AsyncMock(return_value="synthetic-cid"),
            get_conversation=AsyncMock(
                return_value=SimpleNamespace(
                    user_id="configured-platform:FriendMessage:123456",
                    history=json.dumps(
                        [
                            {"role": "system", "content": "never-expose-system"},
                            {"role": "tool", "content": "never-expose-tool-secret"},
                            {
                                "role": "user",
                                "content": "synthetic-private-text Bearer secret-token",
                            },
                        ]
                    ),
                )
            ),
        ),
    )
    plugin.client = SimpleNamespace(
        call=AsyncMock(return_value={"account": {"nickname": "private-account"}})
    )
    state = {}

    async def get(umo, key, default=None):
        return deepcopy(state.get((umo, key), default))

    async def put(umo, key, val):
        state[(umo, key)] = deepcopy(val)

    send = AsyncMock(return_value=True)
    review = PrivateReview(
        plugin, SimpleNamespace(session_get=get, session_put=put), send
    )
    _, private, _ = fixture(group="", sender=sender)
    return plugin, event, private, review, state, send


@pytest.mark.asyncio
async def test_preview_only_private_then_exact_confirm_once_and_no_saved_body():
    plugin, event, private, review, state, send = setup()
    result = await review.request(event, "account")
    assert "private-account" not in result
    assert send.call_args.args[0] == "configured-platform:FriendMessage:owner"
    assert "private-account" in send.call_args.args[1]
    assert "private-account" not in str(state)
    record = (await review.records("owner"))[0]
    code = record["code"]
    assert await review.decide(private, code, True)
    assert (
        send.call_count == 2
        and send.call_args.args[0] == "configured-platform:GroupMessage:allowed-group"
    )
    with pytest.raises(ReviewProblem):
        await review.decide(private, code, True)
    assert send.call_count == 2


@pytest.mark.asyncio
async def test_member_and_disabled_feature_never_read_private_data():
    plugin, event, _, review, _, send = setup(sender="member")
    with pytest.raises(ReviewProblem):
        await review.request(event, "account")
    plugin.config["allow_private_review"] = False
    with pytest.raises(ReviewProblem):
        await review.request(event, "qq", "123456")
    plugin.client.call.assert_not_awaited()
    send.assert_not_awaited()


@pytest.mark.asyncio
async def test_admin_does_not_inherit_someone_else_campus_binding():
    plugin, event, _, review, _, send = setup(sender="admin", admin="admin")
    with pytest.raises(ReviewProblem):
        await review.request(event, "account")
    plugin.client.call.assert_not_awaited()
    send.assert_not_awaited()


@pytest.mark.asyncio
async def test_qq_review_admin_only_scoped_and_redacted():
    plugin, event, private, review, state, send = setup()
    result = await review.request(event, "qq", "123456")
    assert "synthetic-private-text" not in result
    text = send.call_args.args[1]
    assert "synthetic-private-text" in text and "secret-token" not in text
    assert "never-expose" not in text and "synthetic-private-text" not in str(state)
    manager = plugin.context.conversation_manager
    manager.get_conversation.assert_awaited_with(
        "configured-platform:FriendMessage:123456", "synthetic-cid"
    )
    manager.get_conversation.return_value.user_id = "other-session"
    code = (await review.records("owner"))[0]["code"]
    with pytest.raises(ReviewProblem):
        await review.decide(private, code, True)
    assert send.call_count == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "change",
    [
        "group_confirm",
        "other_sender",
        "source_changed",
        "revoked",
        "group_removed",
        "expired",
        "reload",
        "unicode_code",
    ],
)
async def test_invalid_or_changed_approval_never_forwards(change):
    plugin, event, private, review, state, send = setup()
    await review.request(event, "account")
    record = (await review.records("owner"))[0]
    code = record["code"]
    if change == "group_confirm":
        private = event
    if change == "other_sender":
        _, private, _ = fixture(group="", sender="member")
    if change == "source_changed":
        plugin.client.call.return_value = {"account": {"nickname": "changed"}}
    if change == "revoked":
        plugin.client.call.side_effect = IntegrationProblem("invalid_token")
    if change == "group_removed":
        plugin.config["public_read_group_ids"] = []
    if change == "expired":
        record["expires"] = 0
        await review.save("owner", [record])
    if change == "reload":
        review.epoch = "new-process"
    if change == "unicode_code":
        code = "错误代码"
    with pytest.raises((ReviewProblem, IntegrationProblem)):
        await review.decide(private, code, True)
    assert send.call_count == 1


@pytest.mark.asyncio
async def test_timeout_not_replayed_and_cancelled_item_never_sent():
    _, event, private, review, _, send = setup()
    await review.request(event, "account")
    code = (await review.records("owner"))[0]["code"]
    send.side_effect = TimeoutError()
    with pytest.raises(TimeoutError):
        await review.decide(private, code, True)
    with pytest.raises(ReviewProblem):
        await review.decide(private, code, True)
    assert send.call_count == 2
    send.side_effect = None
    await review.request(event, "account")
    new = [r for r in await review.records("owner") if r["state"] == "pending"][0][
        "code"
    ]
    await review.decide(private, new, False)
    with pytest.raises(ReviewProblem):
        await review.decide(private, new, True)
    assert send.call_count == 3
