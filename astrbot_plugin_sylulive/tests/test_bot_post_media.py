import hashlib
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from test_public_agent import config, post

from astrbot_plugin_sylulive.approved_media import ApprovedMedia
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.community_publisher import CommunityPublisher
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory


def library(tmp_path):
    root = tmp_path / "approved"
    root.mkdir()
    import io

    from PIL import Image

    output = io.BytesIO()
    Image.new("RGB", (8, 8), "red").save(output, format="PNG")
    data = output.getvalue()
    digest = hashlib.sha256(data).hexdigest()
    (root / "happy.png").write_bytes(data)
    row = {
        "id": digest[:16],
        "filename": "happy.png",
        "sha256": digest,
        "caption": "开心",
        "license": "Apache-2.0",
        "source_url": "https://example.org/public/happy",
        "approved": True,
        "public": True,
    }
    (root / "manifest.json").write_text(json.dumps({"version": 1, "images": [row]}))
    return root, row, data


def test_approved_catalog_never_reads_unreviewed_private_or_changed_files(tmp_path):
    root, row, data = library(tmp_path)
    media = ApprovedMedia(root)
    assert media.read(row["id"])["bytes"] == data
    assert (
        "filename" not in media.catalogue()[0] and "bytes" not in media.catalogue()[0]
    )
    (root / "happy.png").write_bytes(b"private-photo-substitution")
    with pytest.raises(IntegrationProblem, match="media_changed_or_invalid"):
        media.read(row["id"])
    row["filename"] = "../private.png"
    (root / "manifest.json").write_text(json.dumps({"version": 1, "images": [row]}))
    with pytest.raises(IntegrationProblem, match="invalid_media_catalog"):
        media.catalogue()


@pytest.mark.asyncio
async def test_post_upload_uses_only_approved_bytes_and_captured_transport(tmp_path):
    root, row, data = library(tmp_path)
    reader = AsyncMock(return_value={"data": post()})
    agent = PublicAgent(
        config(community_auto_post=True), reader, PublicMemory(tmp_path / "public.db")
    )
    client = SimpleNamespace(
        tokens={"scope": "community:bot_post"},
        call=AsyncMock(
            side_effect=[{"file_id": 71}, {"state": "published", "post_id": 99}]
        ),
    )
    publisher = CommunityPublisher(agent, client, media=ApprovedMedia(root))
    try:
        result = await publisher.publish_post(
            "校园讨论",
            "根据公开讨论整理的建议",
            "campus",
            {1: "v1"},
            [row["id"]],
            agent.stamp(),
        )
        assert result == {"state": "published", "post_id": 99, "image_count": 1}
        first, second = client.call.call_args_list
        assert (
            first.args == ("POST", "/bot/media")
            and first.kwargs["files"]["file"][1] == data
        )
        assert second.kwargs["payload"]["image_file_ids"] == [71]
        assert second.kwargs["payload"]["sources"] == [
            {"post_id": 1, "source_version": "v1"}
        ]
        assert "Apache-2.0" in second.kwargs["payload"]["content"]
        with pytest.raises(IntegrationProblem, match="bot_post_daily_quota"):
            await publisher.publish_post(
                "再发一篇", "内容", "campus", {1: "v1"}, [], agent.stamp()
            )
        assert client.call.await_count == 2
    finally:
        await agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "mode",
    ["no_scope", "private_image", "source_changed", "uncertain", "pause_after_upload"],
)
async def test_post_write_boundaries_and_unknown_outcomes_are_not_retried(
    tmp_path, mode
):
    root, row, _ = library(tmp_path)
    cfg = config(community_auto_post=True)
    agent = PublicAgent(
        cfg,
        AsyncMock(
            return_value={
                "data": post(source_version="v2" if mode == "source_changed" else "v1")
            }
        ),
        PublicMemory(tmp_path / "public.db"),
    )
    client = SimpleNamespace(
        tokens={"scope": "" if mode == "no_scope" else "community:bot_post"},
        call=AsyncMock(),
    )
    publisher = CommunityPublisher(agent, client, media=ApprovedMedia(root))
    image = row["id"]
    if mode == "private_image":
        row["public"] = False
        (root / "manifest.json").write_text(json.dumps({"version": 1, "images": [row]}))
    if mode == "uncertain":
        client.call.side_effect = IntegrationProblem("network_unavailable")
    if mode == "pause_after_upload":

        async def pause(*args, **kwargs):
            agent.pause()
            return {"file_id": 71}

        client.call.side_effect = pause
    try:
        with pytest.raises(IntegrationProblem):
            await publisher.publish_post(
                "标题", "正文", "campus", {1: "v1"}, [image], agent.stamp()
            )
        if mode in ("no_scope", "private_image", "source_changed"):
            client.call.assert_not_called()
        else:
            assert client.call.await_count == 1
            assert (
                publisher.db.execute("SELECT state FROM post_outbox").fetchone()[0]
                == "uncertain"
            )
    finally:
        await agent.close()


@pytest.mark.asyncio
async def test_comment_revalidation_refuses_changed_source_instead_of_signing_new_version(
    tmp_path,
):
    agent = PublicAgent(
        config(community_auto_comment=True),
        AsyncMock(return_value={"data": post(source_version="v2")}),
        PublicMemory(tmp_path / "public.db"),
    )
    client = SimpleNamespace(tokens={"scope": "community:bot_reply"}, call=AsyncMock())
    publisher = CommunityPublisher(agent, client)
    try:
        with pytest.raises(IntegrationProblem, match="source_changed"):
            await publisher.publish(
                1,
                "根据旧正文生成的评论",
                "",
                agent.stamp(),
                set(),
                expected_version="v1",
            )
        client.call.assert_not_called()
    finally:
        await agent.close()


@pytest.mark.asyncio
async def test_background_post_tool_is_read_first_and_never_gets_chat_meme_or_private_tools(
    tmp_path,
):
    root, row, _ = library(tmp_path)

    async def public(path, **kwargs):
        return (
            {"data": {"items": [post()]}}
            if path.endswith("/posts")
            else {"data": post()}
        )

    agent = PublicAgent(
        config(community_auto_post=True), public, PublicMemory(tmp_path / "public.db")
    )
    client = SimpleNamespace(
        tokens={"scope": "community:bot_post"},
        call=AsyncMock(
            side_effect=[
                {"auto_post": True, "media_upload": True},
                {"file_id": 71},
                {"state": "published", "post_id": 99},
            ]
        ),
    )
    agent.publisher = CommunityPublisher(agent, client, media=ApprovedMedia(root))

    async def run(**kwargs):
        tools = {t.name: t for t in kwargs["tools"].tools}
        assert set(tools) == {
            "read_public_post",
            "read_public_replies",
            "publish_public_post",
        }
        assert kwargs["contexts"] == [] and "私人" in kwargs["system_prompt"]
        publish = tools["publish_public_post"].handler
        before = await publish(None, "标题", "内容", "campus", [1], [row["id"]])
        assert json.loads(before)["error"] == "read_first_or_round_quota"
        await tools["read_public_post"].handler(None, 1)
        result = json.loads(
            await publish(None, "标题", "内容", "campus", [1], [row["id"]])
        )
        assert result["state"] == "published"
        assert (
            json.loads(await publish(None, "再次发布", "内容", "campus", [1], []))[
                "error"
            ]
            == "read_first_or_round_quota"
        )

    try:
        result = await agent.browse(SimpleNamespace(tool_loop_agent=run))
        assert result["state"] == "completed" and result["read_count"] == 1
        assert client.call.await_count == 3
    finally:
        await agent.close()


@pytest.mark.asyncio
async def test_old_or_closed_server_keeps_browsing_read_only_without_reserving_publish(
    tmp_path,
):
    async def public(path, **kwargs):
        return (
            {"data": {"items": [post()]}}
            if path.endswith("/posts")
            else {"data": post()}
        )

    agent = PublicAgent(
        config(community_auto_post=True), public, PublicMemory(tmp_path / "public.db")
    )
    client = SimpleNamespace(
        tokens={"scope": "community:bot_post"},
        call=AsyncMock(side_effect=IntegrationProblem("not_found")),
    )
    agent.publisher = CommunityPublisher(agent, client)

    async def run(**kwargs):
        assert [t.name for t in kwargs["tools"].tools] == [
            "read_public_post",
            "read_public_replies",
        ]
        await kwargs["tools"].tools[0].handler(None, 1)

    try:
        result = await agent.browse(SimpleNamespace(tool_loop_agent=run))
        assert result["state"] == "completed" and result["read_count"] == 1
        client.call.assert_awaited_once_with("GET", "/bot/capabilities")
        assert (
            agent.publisher.db.execute("SELECT count(*) FROM post_outbox").fetchone()[0]
            == 0
        )
    finally:
        await agent.close()
