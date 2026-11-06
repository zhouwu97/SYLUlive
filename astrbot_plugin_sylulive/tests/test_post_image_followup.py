"""Public post picture follow-ups through real SDK hooks, with captured delivery."""
import io
import json
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from PIL import Image
from astrbot.api.provider import LLMResponse, ProviderRequest

from test_community_read_complete import setup, source
from test_group_public_read import fixture


def image_bytes():
    output = io.BytesIO()
    Image.new("RGB", (80, 60), "red").save(output, format="PNG")
    return output.getvalue()


async def remembered(tmp_path, *, images=1):
    plugin, event, post, _ = setup(tmp_path)
    post["images"] = [dict(source()["images"][0], index=i + 1, url=f"/uploads/test-{i}.png") for i in range(images)]
    request = ProviderRequest(prompt="读取帖子811", conversation=SimpleNamespace(cid="post-thread", user_id=event.unified_msg_origin))
    await plugin.present_community_naturally(event, request)
    await plugin.get_post(event, 811)
    plugin.client.public_image = AsyncMock(return_value=image_bytes())
    return plugin, event, post


def followup(prompt="有图片原文吗", *, cid="post-thread", sender="member"):
    _, event, _ = fixture(sender=sender)
    event.message_str = prompt
    event.send = AsyncMock()
    req = ProviderRequest(prompt=prompt, conversation=SimpleNamespace(cid=cid, user_id=event.unified_msg_origin))
    return event, req


@pytest.mark.asyncio
async def test_short_image_original_followup_freshly_reads_post_and_actual_image(tmp_path):
    plugin, _, _ = await remembered(tmp_path)
    event, req = followup()
    try:
        before = plugin.client.public_call.await_count
        await plugin.present_community_naturally(event, req)
        assert plugin.client.public_call.await_count > before
        plugin.client.public_image.assert_awaited_once_with("/uploads/test-0.png")
        assert len(req.image_urls) == 1 and req.image_urls[0].startswith("data:image/jpeg;base64,")
        assert event.get_extra("sylulive_prefetched_post") == 811
        assert event.get_extra("sylulive_required_reads").issubset(event.get_extra("sylulive_completed_reads"))
        event.send.assert_not_awaited()
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_send_requested_post_pictures_current_chat_only_with_two_image_limit(tmp_path):
    plugin, _, _ = await remembered(tmp_path, images=6)
    event, req = followup("把刚才那篇帖子的图片发到群里看看")
    try:
        await plugin.present_community_naturally(event, req)
        assert event.send.await_count == 2 and len(req.image_urls) == 2
        assert plugin.client.public_image.await_count == 2
        assert "6" in req.contexts[-1]["content"] and "2" in req.contexts[-1]["content"]
        await plugin.public_image(event, "post", 811, send_to_chat=True)
        assert event.send.await_count == 2
        other = json.loads(await plugin.public_image(event, "map", 1, send_to_chat=True))
        assert other["error"] == "different_post_target"
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_post_picture_read_only_request_overrides_send_request(tmp_path):
    plugin, _, _ = await remembered(tmp_path)
    event, req = followup("看看刚才帖子的图片原文，只读取，不要发到群里")
    try:
        await plugin.present_community_naturally(event, req)
        assert len(req.image_urls) == 1
        event.send.assert_not_awaited()
        assert json.loads(await plugin.public_image(event, "post", 811, send_to_chat=True))["error"] == "image_send_not_allowed"
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["different_conversation", "different_member", "expired", "different_named_post"])
async def test_image_followup_never_reuses_another_target(tmp_path, case):
    plugin, _, _ = await remembered(tmp_path)
    if case == "expired":
        for row in plugin.recent_posts.values():
            row["read_at"] = time.monotonic() - 1801
    event, req = followup("查看帖子999的图片" if case == "different_named_post" else "有图片原文吗",
        cid="new-thread" if case == "different_conversation" else "post-thread",
        sender="someone-else" if case == "different_member" else "member")
    try:
        await plugin.present_community_naturally(event, req)
        plugin.client.public_image.assert_not_awaited()
        event.send.assert_not_awaited()
        assert not req.image_urls
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["empty", "deleted", "invalid_bytes", "delivery_unknown"])
async def test_picture_failure_cannot_claim_six_images_viewed_or_sent(tmp_path, failure):
    plugin, _, post = await remembered(tmp_path, images=0 if failure == "empty" else 1)
    event, req = followup("把刚才帖子的图片发给我看看")
    if failure == "deleted":
        plugin.client.public_call.side_effect = None
        plugin.client.public_call.return_value = {"data": source(status="deleted")}
    if failure == "invalid_bytes":
        plugin.client.public_image.return_value = b"not-an-image"
    if failure == "delivery_unknown":
        event.send.side_effect = RuntimeError("synthetic uncertain delivery")
    try:
        await plugin.present_community_naturally(event, req)
        response = LLMResponse(role="assistant", completion_text="已发出并看完6张图片，图片原文是编造的内容。")
        messages = [SimpleNamespace(role="assistant", content=[])]
        await plugin.verify_current_read(event, SimpleNamespace(messages=messages), response)
        assert "编造" not in response.completion_text and "看完6张" not in response.completion_text
        assert not req.image_urls
        assert messages[-1].content[0].text == response.completion_text
        if failure == "delivery_unknown":
            await plugin.public_image(event, "post", 811, send_to_chat=True)
            event.send.assert_awaited_once()
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("prompt,expected", [("查看第3张图片原文", [2]), ("查看第三张图片原文", [2]), ("继续看剩下图片原文", [2, 3])])
async def test_later_pictures_can_be_read_in_another_turn(tmp_path, prompt, expected):
    plugin, _, _ = await remembered(tmp_path, images=6)
    first, req = followup()
    try:
        await plugin.present_community_naturally(first, req)
        assert len(req.image_urls) == 2
        plugin.client.public_image.reset_mock()
        event, request = followup(prompt)
        await plugin.present_community_naturally(event, request)
        assert [call.args[0] for call in plugin.client.public_image.await_args_list] == [f"/uploads/test-{i}.png" for i in expected]
        assert len(request.image_urls) == len(expected)
        event.send.assert_not_awaited()
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("prompt", ["列出最近帖子列表里的图片", "查找最新帖子的图片", "发一张表情图片"])
async def test_new_feed_or_meme_request_does_not_send_previous_post_pictures(tmp_path, prompt):
    plugin, _, _ = await remembered(tmp_path)
    event, req = followup(prompt)
    try:
        await plugin.present_community_naturally(event, req)
        plugin.client.public_image.assert_not_awaited()
        event.send.assert_not_awaited()
        assert not req.image_urls
    finally:
        await plugin.public_agent.close()
