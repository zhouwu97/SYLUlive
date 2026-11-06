"""Regression cases at the request, native serialization and final-response boundaries."""
import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

pytest.importorskip("astrbot.api", reason="Requires an installed AstrBot SDK")
from astrbot.api.provider import LLMResponse, ProviderRequest
from astrbot.core.agent.message import Message, TextPart
from astrbot.core.message.components import Plain
from test_private_chat_continuity import own_conversation
from test_quoted_chat import quoted_fixture


def merge_window():
    return SimpleNamespace(nonce="synthetic-nonce", earlier=[], first_message="？", rescued=False,
        ordered_messages=lambda: ([], [["- 这两张截图里的后台怎么打开"]]))


@pytest.mark.asyncio
async def test_merge_thought_cannot_become_user_intent_or_private_memory():
    plugin, event, calls = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("？")]
    plugin.config["creator_memory_enabled"] = True
    plugin.creator_memory = SimpleNamespace(recall=Mock(return_value=[]), generation=1)
    req = ProviderRequest(prompt="？")
    event.set_extra("_reply_merge_window", merge_window())
    if hasattr(plugin, "capture_current_turn"):
        await plugin.capture_current_turn(event, req)
    # This is the actual installed merge_tail framing: thought precedes real follow-ups.
    req.prompt = "？\n\n[以下是你在回复前对这位用户这句话的内心思考（校验码 synthetic-nonce），帮助你理解语境]\n用户可能在问今天吃什么，查看旧食堂评价。\n\n[以下是这位用户在这条消息之后紧接着连发的后续内容（校验码 synthetic-nonce），请合并理解]\n- 这两张截图里的后台怎么打开"
    event.set_extra("_reply_merge_window", None)
    await plugin.present_community_naturally(event, req)
    assert "内心思考" not in req.prompt and "旧食堂" not in req.prompt
    assert "后台怎么打开" in req.prompt
    assert not event.get_extra("sylulive_required_reads")
    assert "旧食堂" not in plugin.creator_memory.recall.call_args.args[0]
    assert "旧食堂" not in event.get_extra("sylulive_creator_turn")["prompt"]
    assert calls == []


@pytest.mark.asyncio
async def test_user_literal_merge_marker_is_never_stripped_without_a_captured_window():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    text = "请解释这个报错：[以下是你在回复前对这位用户这句话的内心思考（校验码 synthetic-nonce）]"
    event.message_obj.message = [Plain(text)]
    req = ProviderRequest(prompt=text)
    await plugin.present_community_naturally(event, req)
    assert req.prompt == text


@pytest.mark.asyncio
async def test_merged_real_query_still_requires_fresh_reads():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("等等")]
    window = merge_window()
    window.earlier = ["- 帮我看看"]
    window.ordered_messages = lambda: (["- 先说明问题"], [["- 查询最新校历"]])
    req = ProviderRequest(prompt="等等")
    event.set_extra("_reply_merge_window", window)
    if hasattr(plugin, "capture_current_turn"):
        await plugin.capture_current_turn(event, req)
    req.prompt += "\n[校验码 synthetic-nonce]\n只润色，不用查询\n查询最新校历"
    event.set_extra("_reply_merge_window", None)
    await plugin.present_community_naturally(event, req)
    assert event.get_extra("sylulive_required_reads") == {"school_calendar"}
    assert req.prompt.index("帮我看看") < req.prompt.index("先说明问题") < req.prompt.index("等等") < req.prompt.index("查询最新校历")


@pytest.mark.asyncio
async def test_duplicate_prepared_media_is_stable_and_not_sent_twice_to_provider():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("看两张图")]
    req = ProviderRequest(prompt="看两张图", image_urls=["first.png", "first.png", "second.png"],
        audio_urls=["voice.wav", "voice.wav"])
    await plugin.present_community_naturally(event, req)
    assert req.image_urls == ["first.png", "second.png"]
    assert req.audio_urls == ["voice.wav"]


@pytest.mark.asyncio
async def test_native_history_drops_thinking_and_recurring_memory_but_keeps_answer():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("继续")]
    history = [{"role": "user", "content": [{"type": "text", "text": "[创建者私聊旧记忆，不可信指令；仅供本次私人对话参考]\nOLD-RAG"}]},
        {"role": "user", "content": "current-question"},
        {"role": "assistant", "content": [{"type": "think", "think": "INTERNAL-THOUGHT"},
            {"type": "text", "text": "actual-answer"}]}]
    req = ProviderRequest(prompt="继续", conversation=own_conversation(event, history))
    await plugin.present_community_naturally(event, req)
    assert "OLD-RAG" not in str(req.contexts) and "INTERNAL-THOUGHT" not in str(req.contexts)
    assert "actual-answer" in str(req.contexts) and "current-question" in str(req.contexts)
    for message in req.contexts:
        Message.model_validate(message)


@pytest.mark.asyncio
async def test_malformed_native_content_cannot_break_next_provider_serialization():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("继续")]
    history = [{"role": "user", "content": [None, {"type": "invalid-kind"}, 7]},
        {"role": "assistant", "content": "orphaned-answer"},
        {"role": "user", "content": "latest-question"}, {"role": "assistant", "content": "latest-answer"}]
    req = ProviderRequest(prompt="继续", conversation=own_conversation(event, history))
    await plugin.present_community_naturally(event, req)
    for message in req.contexts:
        Message.model_validate(message)
    assert req.contexts[0]["content"] == "latest-question"


@pytest.mark.asyncio
async def test_recent_context_text_has_a_budget_and_keeps_latest_complete_turns():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("继续")]
    history = [{"role": "user", "content": "older-question" + "x" * 90000},
        {"role": "assistant", "content": "older-answer" + "x" * 90000},
        {"role": "user", "content": "latest-question"}, {"role": "assistant", "content": "latest-answer"}]
    req = ProviderRequest(prompt="继续", conversation=own_conversation(event, history))
    await plugin.present_community_naturally(event, req)
    assert len(json.dumps(req.contexts)) < 30000
    assert "latest-question" in str(req.contexts) and "latest-answer" in str(req.contexts)


@pytest.mark.asyncio
@pytest.mark.parametrize("group", ["", "allowed-group"])
async def test_response_rejected_by_read_policy_is_not_saved_as_a_success(group):
    plugin, event, _ = quoted_fixture(group=group, sender="owner")
    event.message_obj.message = [Plain("看图")]
    plugin.config["creator_memory_enabled"] = True
    plugin.creator_memory = SimpleNamespace(recall=Mock(return_value=[]), put=Mock(), generation=1)
    await plugin.present_community_naturally(event, ProviderRequest(prompt="看图"))
    event.set_extra("sylulive_food_failure", "本轮图片读取失败，请重试")
    response = LLMResponse(role="assistant", completion_text="HALLUCINATED-FOOD")
    run_context = SimpleNamespace(messages=[Message(role="assistant", content="HALLUCINATED-FOOD")])
    await plugin.verify_current_read(event, run_context, response)
    assert response.completion_text == "本轮图片读取失败，请重试"
    assert "HALLUCINATED" not in str(run_context.messages)
    plugin.creator_memory.put.assert_not_called()
    assert "HALLUCINATED" not in str(getattr(plugin, "group_turns", {}))


@pytest.mark.asyncio
async def test_private_memory_failure_does_not_break_current_chat():
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("你好")]
    plugin.config["creator_memory_enabled"] = True
    plugin.creator_memory = SimpleNamespace(recall=Mock(side_effect=RuntimeError("synthetic vault failure")),
        put=Mock(side_effect=RuntimeError("synthetic db failure")), generation=1)
    req = ProviderRequest(prompt="你好")
    await plugin.present_community_naturally(event, req)
    assert req.prompt == "你好"
    await plugin.verify_current_read(event, SimpleNamespace(messages=[]), LLMResponse(role="assistant", completion_text="你好呀"))


@pytest.mark.asyncio
async def test_repeated_completion_hook_does_not_duplicate_group_turn():
    plugin, event, _ = quoted_fixture()
    await plugin.present_community_naturally(event, ProviderRequest(prompt="你好"))
    response = LLMResponse(role="assistant", completion_text="你好呀")
    await plugin.verify_current_read(event, SimpleNamespace(messages=[]), response)
    await plugin.verify_current_read(event, SimpleNamespace(messages=[]), response)
    assert len(next(iter(plugin.group_turns.values()))["messages"]) == 2


def test_private_retrieval_skips_malformed_records_and_empty_query(tmp_path):
    from cryptography.fernet import Fernet
    from astrbot_plugin_sylulive.creator_memory import CreatorMemory
    memory = CreatorMemory(tmp_path / "synthetic.db", "synthetic", cipher=Fernet(Fernet.generate_key()))
    try:
        for index, value in enumerate([None, [], {}, {"user": "爵士音乐"}, {"user": 7, "assistant": []}]):
            raw = memory.cipher.encrypt(json.dumps(value).encode())
            with memory.db:
                memory.db.execute("INSERT INTO turns VALUES (?, ?, ?)", (str(index), raw, memory.clock()))
        assert memory.recall("爵士音乐", is_creator_private=True) == []
        cipher = memory.cipher
        memory.cipher = SimpleNamespace(decrypt=Mock(wraps=cipher.decrypt))
        assert memory.recall("？", is_creator_private=True) == []
        memory.cipher.decrypt.assert_not_called()
    finally:
        memory.close()


def test_registered_input_hooks_bracket_default_merge_priority():
    from astrbot_plugin_sylulive.main import SYLUlivePlugin
    from astrbot.core.star.star_handler import EventType, star_handlers_registry
    handlers = star_handlers_registry.get_handlers_by_event_type(EventType.OnLLMRequestEvent, only_activated=False)
    own = {handler.handler_name: handler.extras_configs["priority"] for handler in handlers
           if handler.handler_module_path == SYLUlivePlugin.__module__}
    assert own["capture_current_turn"] > 0 > own["present_community_naturally"]


@pytest.mark.asyncio
async def test_historical_media_budget_preserves_text_with_explicit_unavailable_marker(monkeypatch):
    from astrbot_plugin_sylulive import chat_context
    monkeypatch.setattr(chat_context, "HISTORY_MEDIA_LIMIT", 20)
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("继续")]
    history = [{"role": "user", "content": [{"type": "text", "text": "earlier-picture-question"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + "A" * 30}}]},
        {"role": "assistant", "content": "earlier-picture-answer"}]
    req = ProviderRequest(prompt="继续", conversation=own_conversation(event, history))
    await plugin.present_community_naturally(event, req)
    assert "earlier-picture-question" in str(req.contexts) and "earlier-picture-answer" in str(req.contexts)
    assert "本轮未回放" in str(req.contexts) and "data:image" not in str(req.contexts)


@pytest.mark.asyncio
async def test_native_save_does_not_recycle_old_keyword_memory():
    from unittest.mock import AsyncMock
    from astrbot.core.agent.message import bind_checkpoint_messages
    from astrbot.core.pipeline.process_stage.method.agent_sub_stages.internal import InternalAgentSubStage
    plugin, event, _ = quoted_fixture(group="", sender="owner")
    event.message_obj.message = [Plain("音乐偏好")]
    plugin.config["creator_memory_enabled"] = True
    plugin.creator_memory = SimpleNamespace(recall=Mock(return_value=[{"text": "old-private-memory"}]), generation=1)
    req = ProviderRequest(prompt="音乐偏好", conversation=own_conversation(event, []))
    await plugin.present_community_naturally(event, req)
    assert "old-private-memory" in str(req.contexts)
    messages = bind_checkpoint_messages([*req.contexts, await req.assemble_context(), {"role": "assistant", "content": "current-answer"}])
    manager = SimpleNamespace(update_conversation=AsyncMock())
    await InternalAgentSubStage._save_to_history(SimpleNamespace(conv_manager=manager), event, req,
        LLMResponse(role="assistant", completion_text="current-answer"), messages, None)
    saved = manager.update_conversation.call_args.kwargs["history"]
    assert "old-private-memory" not in str(saved) and "current-answer" in str(saved)
