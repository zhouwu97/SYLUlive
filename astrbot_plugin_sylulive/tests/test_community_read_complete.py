"""Exercise the actual isolated-chat dispatch, not just its tool registry."""

import io
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from astrbot.api.provider import ProviderRequest
from PIL import Image
from test_group_public_read import fixture

from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.community_view import presentation
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory


def source(**changes):
    return {
        "post_id": 811,
        "post_type": "campus",
        "status": "normal",
        "title": "合成公开讨论",
        "content": "真实测试正文",
        "source_version": "post-v1",
        "revision": 2,
        "created_at": "2026-11-02T00:00:00Z",
        "like_count": 8,
        "reply_count": 3,
        "author": {"nickname": "公开昵称", "student_id": "PRIVATE-STUDENT"},
        "images": [
            {
                "index": 1,
                "url": "/uploads/synthetic.png",
                "mime_type": "image/png",
                "width": 8,
                "height": 8,
                "file_id": "PRIVATE-FILE",
            }
        ],
        "contact": "PRIVATE-CONTACT",
        **changes,
    }


def reply(ident=2013, **changes):
    return {
        "reply_id": ident,
        "post_id": 811,
        "status": "normal",
        "content": "评论原文",
        "source_version": "reply-v1",
        "parent_reply_id": 2012,
        "reply_to_reply_id": 2011,
        "sticker_id": "builtin-happy",
        "author": {"nickname": "评论昵称", "email": "PRIVATE-EMAIL"},
        "like_count": 2,
        "images": [],
        **changes,
    }


def setup(tmp_path):
    plugin, event, _ = fixture()
    plugin.config.update(
        community_agent_enabled=True, community_allowed_sections=["campus"]
    )
    p, r = source(), reply()

    async def read(path, **kwargs):
        if path.endswith("/stickers"):
            return {
                "data": {
                    "items": [
                        {
                            "sticker_id": "builtin-happy",
                            "label": "开心",
                            "secret": "PRIVATE-STICKER",
                        }
                    ],
                    "next_after_sticker_id": "builtin-happy",
                }
            }
        if path.endswith("/context"):
            return {
                "data": {
                    "post": p,
                    "reply": r,
                    "root_reply": reply(
                        2012, status="deleted", content="PRIVATE-DELETED"
                    ),
                    "target_reply": reply(2011),
                }
            }
        if path.endswith("/replies"):
            return {"data": {"items": [r], "next_after_id": 2013}}
        if path.endswith("/posts"):
            return {
                "data": {
                    "items": [p],
                    "next_after_id": 0,
                    "next_cursor": "next-public-cursor",
                }
            }
        return {"data": p}

    plugin.client.public_call = AsyncMock(side_effect=read)
    plugin.public_agent = PublicAgent(
        plugin.config,
        plugin.client.public_call,
        PublicMemory(tmp_path / "public.sqlite3"),
    )
    return plugin, event, p, r


@pytest.mark.parametrize("change", [{"content": {"password": "PRIVATE"}}, {"title": ["PRIVATE"]}, {"source_version": None}, {"images": [{"url": "https://private.invalid/image"}]}])
def test_malformed_public_dto_is_not_stringified_or_forwarded(change):
    with pytest.raises(IntegrationProblem):
        presentation(source(**change))


def test_existing_public_upload_without_dimension_metadata_remains_readable():
    result = presentation(source(images=[{"url": "/uploads/legacy.png", "index": 1, "width": 0, "height": 0, "mime_type": "image/png"}]))
    assert result["images"][0]["width"] == 0


@pytest.mark.asyncio
@pytest.mark.parametrize("result", [{"data": None}, {"data": []}])
async def test_malformed_public_wrapper_returns_error_instead_of_hanging_model_tool(tmp_path, result):
    plugin, event, _, _ = setup(tmp_path)
    plugin.client.public_call.side_effect = None
    plugin.client.public_call.return_value = result
    try:
        assert "error" in json.loads(await plugin.get_post(event, 811))
        assert "error" in json.loads(await plugin.stickers(event))
        assert "error" in json.loads(await plugin.posts(event))
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_full_public_post_fields_survive_actual_isolated_dispatch_without_private_cache(
    tmp_path,
):
    plugin, event, _, _ = setup(tmp_path)
    try:
        result = json.loads(await plugin.get_post(event, 811))["data"]
        assert result["author"] == {"nickname": "公开昵称"}
        assert result["images"][0]["url"] == "/uploads/synthetic.png"
        assert result["like_count"] == 8 and result["reply_count"] == 3
        assert "PRIVATE" not in json.dumps(result)
        cached = plugin.public_agent.memory.db.execute(
            "SELECT body FROM posts"
        ).fetchone()[0]
        assert "author" not in cached and "images" not in cached
        assert plugin.recent_posts
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_reply_thread_catalog_and_pagination_work_through_actual_tools(tmp_path):
    plugin, event, _, _ = setup(tmp_path)
    try:
        page = json.loads(await plugin.replies(event, 811))["data"]
        assert page["next_after_id"] == 2013
        assert page["items"][0]["author"]["nickname"] == "评论昵称"
        assert page["items"][0]["reply_to_reply_id"] == 2011
        thread = json.loads(await plugin.reply_context(event, 2013))["data"]
        assert (
            thread["root_reply"]["status"] == "deleted"
            and "content" not in thread["root_reply"]
        )
        assert thread["target_reply"]["reply_id"] == 2011
        assert "PRIVATE" not in json.dumps(thread)
        catalog = json.loads(await plugin.stickers(event, "开心"))["data"]
        assert catalog["items"] == [{"sticker_id": "builtin-happy", "label": "开心"}]
        assert catalog["next_after_sticker_id"] == "builtin-happy"
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_public_post_image_reaches_native_multimodal_and_current_chat_once(
    tmp_path,
):
    plugin, event, _, _ = setup(tmp_path)
    output = io.BytesIO()
    Image.new("RGB", (8, 8), "red").save(output, format="PNG")
    plugin.client.public_image = AsyncMock(return_value=output.getvalue())
    event.send = AsyncMock()
    try:
        result = await plugin.public_image(event, "post", 811, send_to_chat=True)
        assert any(block.type == "image" for block in result.content)
        event.send.assert_awaited_once()
        again = json.loads(
            await plugin.public_image(event, "post", 811, send_to_chat=True)
        )
        assert again["delivery_state"] == "sent"
        event.send.assert_awaited_once()
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_actual_followup_rereads_last_post_and_comments_instead_of_inventing_history(
    tmp_path,
):
    plugin, event, p, _ = setup(tmp_path)
    try:
        await plugin.present_community_naturally(
            event, ProviderRequest(prompt="读取帖子811")
        )
        await plugin.get_post(event, 811)
        p["content"], p["source_version"] = "第二轮更新后的正文", "post-v2"
        _, follow, _ = fixture()
        request = ProviderRequest(prompt="把刚才那篇讨论再自然总结一下")
        await plugin.present_community_naturally(follow, request)
        assert "第二轮更新后的正文" in json.dumps(request.contexts, ensure_ascii=False)
        assert {"post", "replies"} <= follow.get_extra(
            "sylulive_completed_reads", set()
        )
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "mode", ["cross_post", "hidden", "changed_during_read", "revoked_during_read"]
)
async def test_discussion_read_cannot_cross_visibility_or_running_policy(
    tmp_path, mode
):
    plugin, event, p, r = setup(tmp_path)

    async def read(path, **kwargs):
        if path.endswith("/replies"):
            if mode == "cross_post":
                r["post_id"] = 999
            elif mode == "hidden":
                p["status"] = "hidden"
            elif mode == "changed_during_read":
                p["source_version"] = "edited-in-flight"
            else:
                plugin.public_agent.pause()
            return {"data": {"items": [r], "next_after_id": 0}}
        return {"data": dict(p)}

    plugin.client.public_call.side_effect = read
    try:
        result = json.loads(await plugin.replies(event, 811))
        assert "error" in result and "评论原文" not in json.dumps(
            result, ensure_ascii=False
        )
        assert event.get_extra("sylulive_completed_reads") == {"post"}
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_image_unknown_delivery_is_not_sent_twice_and_changed_source_is_not_used(
    tmp_path,
):
    plugin, event, p, _ = setup(tmp_path)
    output = io.BytesIO()
    Image.new("RGB", (8, 8), "blue").save(output, format="PNG")
    plugin.client.public_image = AsyncMock(return_value=output.getvalue())
    event.send = AsyncMock(side_effect=TimeoutError("uncertain network"))
    try:
        first = json.loads(
            await plugin.public_image(event, "post", 811, send_to_chat=True)
        )
        second = json.loads(
            await plugin.public_image(event, "post", 811, send_to_chat=True)
        )
        assert first["delivery_state"] == second["delivery_state"] == "unknown"
        event.send.assert_awaited_once()
        _, fresh_event, _ = fixture()

        async def download(path):
            p["status"] = "hidden"
            return output.getvalue()

        plugin.client.public_image.side_effect = download
        result = await plugin.public_image(fresh_event, "post", 811)
        assert isinstance(result, str) and "error" in json.loads(result)
    finally:
        await plugin.public_agent.close()


@pytest.mark.asyncio
async def test_real_astrbot_loop_reads_thread_and_pixels_before_community_sticker_comment(
    tmp_path,
):
    from astrbot.api.provider import LLMResponse
    from astrbot.api.star import Context
    from astrbot.core.provider.provider import Provider
    from test_public_agent import config

    from astrbot_plugin_sylulive.community_publisher import CommunityPublisher

    p = source()
    paths = []

    async def public(path, **kwargs):
        paths.append(path)
        if path.endswith("/posts"):
            return {"data": {"items": [p]}}
        if path.endswith("/replies"):
            return {"data": {"items": [reply()], "next_after_id": 0}}
        if path.endswith("/stickers"):
            return {"data": {"items": [{"sticker_id": "builtin-happy"}]}}
        return {"data": p}

    output = io.BytesIO()
    Image.new("RGB", (8, 8), "green").save(output, format="PNG")
    image_reader = AsyncMock(return_value=output.getvalue())
    agent = PublicAgent(
        config(community_auto_comment=True),
        public,
        PublicMemory(tmp_path / "public.db"),
        image_reader=image_reader,
    )
    client = SimpleNamespace(
        tokens={"scope": "community:bot_reply"},
        call=AsyncMock(return_value={"state": "published", "reply_id": 55}),
    )
    agent.publisher = CommunityPublisher(agent, client)

    class Model(Provider):
        def get_current_key(self):
            return "synthetic"

        def set_key(self, key):
            pass

        async def get_models(self):
            return ["synthetic"]

        async def text_chat(self, **kwargs):
            self.calls.append(kwargs)
            assert {t.name for t in kwargs["func_tool"].tools} == {
                "read_public_post",
                "read_public_replies",
                "read_public_image",
                "comment_public_post",
            }
            assert "PRIVATE" not in str(kwargs["contexts"])
            chain = [
                ("read_public_post", {"post_id": 811}),
                ("read_public_replies", {"post_id": 811}),
                ("read_public_image", {"post_id": 811}),
                (
                    "comment_public_post",
                    {
                        "post_id": 811,
                        "content": "感谢公开分享",
                        "sticker_id": "builtin-happy",
                    },
                ),
            ]
            step = len(self.calls) - 1
            if step == 1:
                assert "公开昵称" in str(kwargs["contexts"])
            if step == 2:
                assert "评论原文" in str(kwargs["contexts"])
            if step == 3:
                # Native tool runner forwards actual multimodal data to the model.
                assert "image/jpeg" in str(kwargs) or "data:image/" in str(kwargs)
            if step < len(chain):
                name, args = chain[step]
                return LLMResponse(
                    role="assistant",
                    tools_call_name=[name],
                    tools_call_args=[args],
                    tools_call_ids=[f"synthetic-{step}"],
                )
            assert "published" in str(kwargs["contexts"])
            return LLMResponse(role="assistant", completion_text="已完成合成测试")

    model = Model({"id": "synthetic-provider", "type": "synthetic"}, {})
    model.calls = []
    context = Context.__new__(Context)
    context.provider_manager = SimpleNamespace(
        get_provider_by_id=AsyncMock(return_value=model)
    )
    try:
        result = await agent.browse(context)
        assert result["state"] == "completed" and len(model.calls) == 5
        image_reader.assert_awaited_once_with("/uploads/synthetic.png")
        client.call.assert_awaited_once()
        assert client.call.call_args.kwargs["payload"]["source_version"] == "post-v1"
        assert paths.count("/api/integrations/v1/public/community/posts/811") >= 4
    finally:
        await agent.close()
