"""Current screenshots and creator-private follow-ups survive foreground isolation."""
import json
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")
from astrbot.api.provider import ProviderRequest
from astrbot.core.message.components import Image, Plain
from test_quoted_chat import quoted_fixture


def own_conversation(event, history, **kwargs):
    return SimpleNamespace(user_id=event.unified_msg_origin, cid="current-private",
        history=json.dumps(history), updated_at=int(time.time()), **kwargs)


@pytest.mark.asyncio
async def test_merged_screenshots_survive_a_text_leader(tmp_path):
    from PIL import Image as PillowImage
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("看这两张截图")]
    paths = [tmp_path / f"screen-{i}.png" for i in range(2)]
    for path in paths:
        PillowImage.new("RGB", (24, 24), "orange").save(path)
    # Reply merge donates later events' images to this request, not the leader's components.
    req = ProviderRequest(prompt="看这两张截图", image_urls=[str(path) for path in paths])
    await plugin.present_community_naturally(event, req)
    payload = await req.assemble_context()
    assert isinstance(payload["content"], list), "merged screenshots were removed before serialization"
    assert len([part for part in payload["content"] if part["type"] == "image_url"]) == 2


@pytest.mark.asyncio
async def test_current_screenshot_never_prefetches_old_food_or_post():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("这图呢"), Image(file="synthetic-current.png")]
    plugin.prefetch_canteen_followup = AsyncMock()
    plugin.get_post = AsyncMock()
    plugin.recent_posts = {(event.unified_msg_origin, "", "owner"):
        {"post_id": 811, "read_at": time.monotonic()}}
    req = ProviderRequest(prompt="这家评价怎么样，刚才那篇帖子有图片吗", image_urls=["synthetic-current.png"])
    await plugin.present_community_naturally(event, req)
    plugin.prefetch_canteen_followup.assert_not_awaited()
    plugin.get_post.assert_not_awaited()


@pytest.mark.asyncio
async def test_private_image_then_question_mark_has_current_image_context(tmp_path):
    from PIL import Image as PillowImage
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    path = tmp_path / "current.png"
    PillowImage.new("RGB", (24, 24), "orange").save(path)
    event.message_obj.message = [Plain("这个后台怎么打开"), Image.fromFileSystem(str(path))]
    conv = own_conversation(event, [])
    req = ProviderRequest(prompt="这个后台怎么打开", image_urls=[str(path)], conversation=conv,
        contexts=[{"role": "user", "content": "UNTRUSTED-KB-PRELOAD"}], session_id=event.unified_msg_origin)
    await plugin.present_community_naturally(event, req)
    assert req.conversation is conv, "clearing this disables native history persistence"
    assert req.session_id == event.unified_msg_origin
    assert req.contexts == []
    # Exercise the native save gate too: conversation=None used to skip this.
    from astrbot.api.provider import LLMResponse
    from astrbot.core.agent.message import Message
    from astrbot.core.pipeline.process_stage.method.agent_sub_stages.internal import InternalAgentSubStage
    manager = SimpleNamespace(update_conversation=AsyncMock())
    await InternalAgentSubStage._save_to_history(SimpleNamespace(conv_manager=manager), event, req,
        LLMResponse(role="assistant", completion_text="这是插件后台"),
        [Message.model_validate(await req.assemble_context()), Message(role="assistant", content="这是插件后台")], None)
    manager.update_conversation.assert_awaited_once()
    assert manager.update_conversation.call_args.args == (event.unified_msg_origin, conv.cid)
    conv.history = json.dumps(manager.update_conversation.call_args.kwargs["history"])
    event.message_obj.message = [Plain("？")]
    follow = ProviderRequest(prompt="？", conversation=conv,
        contexts=[{"role": "user", "content": "UNTRUSTED-KB-PRELOAD"}])
    await plugin.present_community_naturally(event, follow)
    assert "data:image/" in str(follow.contexts) and "这个后台怎么打开" in str(follow.contexts)
    assert "UNTRUSTED" not in str(follow.contexts)
    assert follow.conversation is conv


@pytest.mark.asyncio
@pytest.mark.parametrize("scope", ["other-private", "group-owner", "foreign-conversation"])
async def test_native_private_context_never_reaches_another_scope(scope):
    plugin, event, _ = quoted_fixture(group="allowed-group" if scope == "group-owner" else "",
        sender="member" if scope == "other-private" else "owner")
    event.message_obj.message = [Plain("？")]
    conv = own_conversation(event, [{"role": "user", "content": "PRIVATE-SCREENSHOT"}])
    if scope == "foreign-conversation":
        conv.user_id = "foreign"
    req = ProviderRequest(prompt="？", conversation=conv, session_id="private-session")
    await plugin.present_community_naturally(event, req)
    assert req.conversation is None and not req.session_id
    assert "PRIVATE-SCREENSHOT" not in str(req.contexts)


@pytest.mark.asyncio
@pytest.mark.parametrize("history,age", [("not-json", 0), ("{}", 0), ("[]", 0),
    ('[{"role":"user","content":"STALE-FOOD"}]', 1801)])
async def test_invalid_or_expired_native_history_is_not_replayed(history, age):
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("？")]
    conv = own_conversation(event, [])
    conv.history, conv.updated_at = history, int(time.time()) - age
    req = ProviderRequest(prompt="？", conversation=conv)
    await plugin.present_community_naturally(event, req)
    assert req.contexts == []
    # Keep the validated native conversation so the next real turn can be saved.
    assert req.conversation is conv


@pytest.mark.asyncio
async def test_private_recent_context_is_bounded_and_drops_system_and_tool_injections():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("继续")]
    history = [{"role": "system", "content": "OLD-SYSTEM-INJECTION"}]
    for i in range(10):
        history.extend([{"role": "user", "content": f"question-{i}"},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "old-tool"}]},
            {"role": "tool", "content": "OLD-TOOL-RESULT", "tool_call_id": "old-tool"},
            {"role": "assistant", "content": f"answer-{i}"}])
    req = ProviderRequest(prompt="继续", conversation=own_conversation(event, history))
    await plugin.present_community_naturally(event, req)
    assert len(req.contexts) == 12
    assert req.contexts[0]["content"] == "question-4"
    assert req.contexts[-1]["content"] == "answer-9"
    assert "OLD-" not in str(req.contexts) and "tool_calls" not in str(req.contexts)


@pytest.mark.asyncio
async def test_creator_long_memory_does_not_replace_recent_chat():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("这个呢")]
    plugin.config["creator_memory_enabled"] = True
    plugin.creator_memory = SimpleNamespace(recall=lambda *a, **k: [{"text": "old-private-memory"}], generation=1)
    req = ProviderRequest(prompt="这个呢", conversation=own_conversation(event,
        [{"role": "user", "content": "current-screen-description"}, {"role": "assistant", "content": "current-answer"}]))
    await plugin.present_community_naturally(event, req)
    assert "current-screen-description" in str(req.contexts)
    assert "old-private-memory" in str(req.contexts)
