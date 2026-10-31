"""推荐命令→下一轮原生 ProviderRequest；不发真实 QQ 消息。"""

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from astrbot.api.provider import LLMResponse, ProviderRequest
from astrbot.core.agent.run_context import ContextWrapper
from astrbot.core.agent.tool import FunctionTool, ToolSet
from test_group_public_read import fixture

from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.public_canteen import followup_intent


def meal_fixture():
    plugin, event, _ = fixture()
    manager = SimpleNamespace(
        get_curr_conversation_id=AsyncMock(return_value="meal-conversation"),
        new_conversation=AsyncMock(return_value="meal-conversation"),
    )
    plugin.context = SimpleNamespace(conversation_manager=manager)
    rank = {
        "id": 119,
        "name": "饮品",
        "location_area": "二食堂",
        "location_floor": "一楼",
        "rank": 73,
    }
    detail = {
        "canteen": {
            **rank,
            "image": "/uploads/store.jpg",
            "verified": True,
            "operating_status": "active",
            "created_by": 123,
        },
        "rating_count": 2,
        "average_star": 4.5,
        "display_reviews": [
            {
                "id": 7,
                "review_source": "v2",
                "comment": "味道清爽",
                "overall_score": 4.5,
                "created_at": "2026-10-31T10:00:00+08:00",
                "user_id": 123,
                "user_student_id": "secret-student",
                "user_name": "同学甲",
                "images": '["/uploads/review.jpg"]',
            },
        ],
        "my_latest_review": {"secret": "must-not-leak"},
    }

    async def read(path, **kwargs):
        return {"items": [rank]} if path.endswith("rankings") else detail

    plugin.client = SimpleNamespace(public_call=AsyncMock(side_effect=read))
    return plugin, event, manager


@pytest.mark.asyncio
async def test_random_command_shows_location_and_real_review_without_rank_noise():
    plugin, event, _ = meal_fixture()
    results = [r async for r in plugin.eat_command(event)]
    text = "\n".join(
        part.text
        for result in results
        for part in result.chain
        if hasattr(part, "text")
    )
    assert "二食堂" in text and "一楼" in text and "味道清爽" in text
    assert "73" not in text and "家店中随机" not in text


@pytest.mark.asyncio
async def test_food_photo_followup_carries_target_instead_of_old_map_history():
    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    _, follow, _ = fixture()
    request = ProviderRequest(
        prompt="有图片吗？给我看看",
        system_prompt="原有人格",
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=follow.unified_msg_origin
        ),
        contexts=[{"role": "assistant", "content": "之前为你看过校园地图"}],
    )
    # 图片发送由原生工具负责；此处截住投递，不能给真实群发测试。
    plugin.public_image = AsyncMock(return_value='{"error":"image_not_found"}')
    await plugin.present_community_naturally(follow, request)
    assert follow.get_extra("sylulive_food_target") == 119
    assert "饮品" in json.dumps(request.contexts, ensure_ascii=False)
    plugin.public_image.assert_awaited_once_with(
        follow, "canteen", 119, send_to_chat=True
    )
    assert request.system_prompt.startswith("原有人格")


@pytest.mark.asyncio
async def test_public_canteen_tool_sanitizes_optional_personal_fields():
    plugin, event, _ = meal_fixture()
    raw = await plugin.canteen(event, 119)
    data = json.loads(raw)
    assert data["reviews"][0]["comment"] == "味道清爽"
    assert data["images"][1]["kind"] == "review"
    assert all(
        s not in raw
        for s in ("user_id", "student", "created_by", "my_latest_review", "secret")
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["actor", "group", "cid", "expired", "topic"])
async def test_recent_meal_does_not_cross_actor_group_reset_ttl_or_topic(change):
    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    _, follow, _ = fixture(sender="someone-else" if change == "actor" else "member")
    if change == "group":
        follow.unified_msg_origin = "configured-platform:GroupMessage:another-group"
    if change == "expired":
        next(iter(plugin.recent_canteens.values()))["read_at"] -= 1801
    cid = "new-conversation" if change == "cid" else "meal-conversation"

    def req(prompt):
        return ProviderRequest(
            prompt=prompt,
            conversation=SimpleNamespace(cid=cid, user_id=follow.unified_msg_origin),
        )

    if change == "topic":
        await plugin.present_community_naturally(follow, req("看校园地图"))
    plugin.client.public_call.reset_mock()
    await plugin.present_community_naturally(follow, req("有图片吗？给我看看"))
    assert follow.get_extra("sylulive_food_target") is None
    plugin.client.public_call.assert_not_called()


@pytest.mark.parametrize(
    "prompt",
    [
        "看看麻辣香锅图片",
        "另一家的图片呢",
        "校园地图图片",
        "《另一家店》评价",
        "照片中的帖子",
        "帮我查私人聊天记录",
    ],
)
def test_explicit_other_topic_is_not_treated_as_recent_food(prompt):
    assert followup_intent(prompt) is None


@pytest.mark.asyncio
async def test_first_meal_creates_native_conversation_without_writing_fake_history():
    plugin, event, manager = meal_fixture()
    manager.get_curr_conversation_id.return_value = None
    await plugin.eat_what(event)
    manager.new_conversation.assert_awaited_once_with(event.unified_msg_origin)
    assert next(iter(plugin.recent_canteens))[2] == "meal-conversation"


@pytest.mark.asyncio
async def test_followup_filters_map_and_cannot_call_different_food_source():
    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    req = ProviderRequest(
        prompt="这家评价怎么样",
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=event.unified_msg_origin
        ),
        func_tool=ToolSet(
            [
                FunctionTool(name=n, description="synthetic", parameters={})
                for n in (
                    "sylulive_canteen",
                    "sylulive_public_image",
                    "sylulive_campus_map",
                    "send_message_to_user",
                )
            ]
        ),
    )
    await plugin.present_community_naturally(event, req)
    assert {t.name for t in req.func_tool.tools} == {
        "sylulive_canteen",
        "sylulive_public_image",
    }
    assert (
        json.loads(await plugin.public_image(event, "map", 1, send_to_chat=True))[
            "error"
        ]
        == "different_food_target"
    )
    assert (
        json.loads(await plugin.canteen(event, 888))["error"] == "different_food_target"
    )
    assert (
        json.loads(await plugin.dishes(event, 888))["error"] == "different_food_target"
    )


@pytest.mark.asyncio
async def test_photo_followup_reads_real_bytes_sends_current_chat_once_and_gives_model_image():
    import io

    from PIL import Image

    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    raw = io.BytesIO()
    Image.new("RGB", (80, 60), "red").save(raw, format="PNG")
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    _, follow, _ = fixture()
    follow.send = AsyncMock()
    req = ProviderRequest(
        prompt="有图片吗？给我看看",
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=follow.unified_msg_origin
        ),
    )
    await plugin.present_community_naturally(follow, req)
    assert follow.send.await_count == 1 and len(req.image_urls) == 1
    assert req.image_urls[0].startswith("data:image/jpeg;base64,")
    plugin.client.public_image.assert_awaited_once_with("/uploads/store.jpg")
    assert follow.get_extra("sylulive_required_reads").issubset(
        follow.get_extra("sylulive_completed_reads")
    )
    await plugin.public_image(follow, "canteen", 119, send_to_chat=True)
    assert follow.send.await_count == 1
    await plugin.present_community_naturally(follow, req)
    assert follow.send.await_count == 1
    malformed = LLMResponse(
        role="assistant",
        completion_text="<tool_call><function=sylulive_public_image>fake</function></tool_call>",
    )
    await plugin.verify_current_read(
        follow, ContextWrapper(context=None, messages=[]), malformed
    )
    assert (
        "<tool_call>" not in malformed.completion_text
        and "已发来" in malformed.completion_text
    )
    assert "味道清爽" in malformed.completion_text


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["empty", "network", "removed", "delivery"])
async def test_missing_changed_or_uncertain_food_photo_cannot_claim_success(failure):
    import io

    from PIL import Image

    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    original = plugin.client.public_call.side_effect
    reads = 0

    async def read(path, **kwargs):
        nonlocal reads
        data = await original(path, **kwargs)
        if not path.endswith("rankings"):
            reads += 1
            if failure == "empty" or (failure == "removed" and reads >= 3):
                data = {
                    **data,
                    "canteen": {**data["canteen"], "image": ""},
                    "display_reviews": [],
                }
            if failure == "network":
                raise IntegrationProblem("network_unavailable")
        return data

    plugin.client.public_call.side_effect = read
    raw = io.BytesIO()
    Image.new("RGB", (4, 4)).save(raw, format="PNG")
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    _, follow, _ = fixture()
    follow.send = AsyncMock(
        side_effect=RuntimeError("synthetic transport failure")
        if failure == "delivery"
        else None
    )
    req = ProviderRequest(
        prompt="有图片吗？给我看看",
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=follow.unified_msg_origin
        ),
    )
    await plugin.present_community_naturally(follow, req)
    response = LLMResponse(role="assistant", completion_text="假装已发给你这家的照片！")
    await plugin.verify_current_read(
        follow, ContextWrapper(context=None, messages=[]), response
    )
    assert "假装" not in response.completion_text
    assert "canteen_image" not in follow.get_extra("sylulive_completed_reads", set())
    assert follow.send.await_count == (1 if failure == "delivery" else 0)
    if failure == "delivery":
        await plugin.public_image(follow, "canteen", 119, send_to_chat=True)
        assert follow.send.await_count == 1


@pytest.mark.asyncio
async def test_legacy_and_current_review_images_page_without_personal_fields():
    plugin, event, _ = meal_fixture()
    source = plugin.client.public_call.side_effect
    body = await source("/api/canteens/119")
    body["display_reviews"].extend(
        [
            {
                "review_id": 7,
                "review_source": "legacy",
                "comment": "老评价",
                "images": '["/uploads/old.jpg"]',
            },
            {
                "review_id": 8,
                "review_source": "v2",
                "comment": "新评价",
                "images": "malformed",
                "dish_photos": [
                    {"image": "/uploads/approved.jpg", "status": "approved"},
                    {"image": "/uploads/pending.jpg", "status": "pending"},
                ],
            },
        ]
    )
    plugin.client.public_call = AsyncMock(return_value=body)
    page = json.loads(await plugin.canteen(event, 119, limit=1))
    assert page["review_total"] == 3 and page["next_offset"] == 1
    assert {i["kind"] for i in page["images"]} == {"storefront", "review", "dish_photo"}
    assert "pending.jpg" not in json.dumps(page)
    next_page = json.loads(await plugin.canteen(event, 119, offset=1, limit=1))
    assert next_page["reviews"][0]["review_source"] == "legacy"
    assert await plugin.image_reference(event, "canteen", 119, 0, 3) == (
        "/uploads/old.jpg",
        4,
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "options",
    [
        {"group": "other-group"},
        {"group": "", "sender": "other"},
        {"platform": "other-platform"},
    ],
)
async def test_new_canteen_tool_does_not_expand_session_permissions(options):
    plugin, event, _ = fixture(**options)
    plugin.client = SimpleNamespace(public_call=AsyncMock())
    assert (
        json.loads(await plugin.canteen(event, 119))["error"]
        == "public_session_required"
    )
    plugin.client.public_call.assert_not_called()


@pytest.mark.asyncio
async def test_meal_reference_survives_real_native_sqlite_conversation_creation(
    tmp_path, monkeypatch
):
    import astrbot.core.conversation_mgr as manager_module
    from astrbot.core.conversation_mgr import ConversationManager
    from astrbot.core.db.sqlite import SQLiteDatabase

    db = SQLiteDatabase(str(tmp_path / "synthetic-meal.db"))
    await db.initialize()
    monkeypatch.setattr(
        manager_module,
        "sp",
        SimpleNamespace(
            session_get=AsyncMock(return_value=None), session_put=AsyncMock()
        ),
    )
    manager = ConversationManager(db)
    plugin, event, _ = meal_fixture()
    plugin.context.conversation_manager = manager
    try:
        await plugin.eat_what(event)
        cid = await manager.get_curr_conversation_id(event.unified_msg_origin)
        conversation = await manager.get_conversation(event.unified_msg_origin, cid)
        assert (
            conversation.user_id == event.unified_msg_origin
            and conversation.history == "[]"
        )
        req = ProviderRequest(prompt="这家评价怎么样", conversation=conversation)
        await plugin.present_community_naturally(event, req)
        assert event.get_extra("sylulive_food_target") == 119
        new_cid = await manager.new_conversation(event.unified_msg_origin)
        _, new_event, _ = fixture()
        new_req = ProviderRequest(
            prompt="有图片吗",
            conversation=await manager.get_conversation(
                new_event.unified_msg_origin, new_cid
            ),
        )
        await plugin.present_community_naturally(new_event, new_req)
        assert new_event.get_extra("sylulive_food_target") is None
    finally:
        await db.engine.dispose()


@pytest.mark.asyncio
async def test_direct_map_command_clears_recent_food_reference():
    plugin, event, _ = meal_fixture()
    await plugin.eat_what(event)
    plugin.campus_map = AsyncMock(return_value='{"error":"synthetic"}')
    assert [r async for r in plugin.map_command(event)]
    _, follow, _ = fixture()
    req = ProviderRequest(
        prompt="有图片吗",
        conversation=SimpleNamespace(
            cid="meal-conversation", user_id=follow.unified_msg_origin
        ),
    )
    await plugin.present_community_naturally(follow, req)
    assert follow.get_extra("sylulive_food_target") is None
