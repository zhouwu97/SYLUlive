"""公开能力与群隐私边界，使用真实 AstrBot SDK，不连接 QQ 或付费模型。"""

import base64
import io
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

pytest.importorskip("astrbot.api")
from astrbot.api.provider import ProviderRequest
from astrbot.core.agent.tool import FunctionTool, ToolSet
from astrbot.core.agent.run_context import ContextWrapper
from astrbot.core.tools.message_tools import GetGroupMessageHistoryTool
from mcp.types import ImageContent
from PIL import Image

from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem
from test_group_public_read import fixture
from test_client import Store


@pytest.mark.asyncio
async def test_public_group_gets_request_local_tool_allowlist_even_for_admin():
    plugin, event, _ = fixture(sender="owner")
    tools = ToolSet(
        [
            FunctionTool(name=name, description="synthetic", parameters={})
            for name in (
                "sylulive_posts",
                "sylulive_canteens",
                "sylulive_public_image",
                "sylulive_my_public_posts",
                "send_message_to_user",
                "run_shell_command",
                "private_memory_search",
            )
        ]
    )
    req = ProviderRequest(
        prompt="看公开帖子",
        func_tool=tools,
        conversation=SimpleNamespace(user_id=event.unified_msg_origin),
    )
    await plugin.present_community_naturally(event, req)
    assert [t.name for t in req.func_tool.tools] == [
        "sylulive_posts",
        "sylulive_canteens",
        "sylulive_public_image",
    ]
    assert len(tools.tools) == 7  # 不改变其他会话和注册表。
    assert req.func_tool.get_tool("send_message_to_user") is None


@pytest.mark.asyncio
async def test_foreign_conversation_blocked_before_provider_and_safe_reply():
    plugin, event, _ = fixture()
    event.send = AsyncMock()
    req = ProviderRequest(
        prompt="读取别人的聊天",
        contexts=[{"role": "user", "content": "private-secret"}],
        conversation=SimpleNamespace(user_id="other-platform:FriendMessage:other-user"),
    )
    await plugin.present_community_naturally(event, req)
    assert event.is_stopped() and not req.contexts and req.conversation is None
    assert req.prompt == "" and req.func_tool.empty()
    event.send.assert_awaited_once()
    assert "private-secret" not in str(event.send.call_args)


@pytest.mark.asyncio
async def test_native_group_history_ignores_spoofed_session_and_group():
    _, event, _ = fixture()
    history = AsyncMock(return_value=[])
    ctx = SimpleNamespace(
        event=event,
        context=SimpleNamespace(
            get_config=lambda **kw: {
                "provider_ltm_settings": {"group_message_history_enable": True}
            },
            message_history_manager=SimpleNamespace(get=history),
        ),
    )
    await GetGroupMessageHistoryTool().call(
        ContextWrapper(context=ctx),
        group_id="other-group",
        session="other:FriendMessage:owner",
    )
    assert history.call_args.kwargs["user_id"] == event.unified_msg_origin
    assert history.call_args.kwargs["platform_id"] == event.get_platform_id()


@pytest.mark.asyncio
async def test_food_is_canonical_anonymous_api_and_list_works_without_grant():
    calls = []

    def respond(req):
        calls.append(req)
        if req.url.path.endswith("/dishes"):
            return httpx.Response(200, json=[{"id": 2, "name": "合成菜"}])
        return httpx.Response(
            200,
            json={
                "items": [{"rank": 1, "id": 1, "name": "合成店", "ranking_score": 80}],
                "meta": {"algorithm": "bayesian", "total": 1},
            },
        )

    client = BusinessClient(
        "https://fixture.invalid", Store(), transport=httpx.MockTransport(respond)
    )
    plugin, event, _ = fixture()
    plugin.client = client
    try:
        result = json.loads(await plugin.canteens(event))
        assert result["meta"]["algorithm"] == "bayesian"
        assert json.loads(await plugin.dishes(event, 1))["items"][0]["name"] == "合成菜"
        assert all(
            "Authorization" not in r.headers and "Cookie" not in r.headers
            for r in calls
        )
        assert [r.url.path for r in calls] == [
            "/api/canteens/rankings",
            "/api/canteens/1/dishes",
        ]
        with pytest.raises(IntegrationProblem):
            await client.public_call("/api/users/1")
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "path",
    [
        "https://evil.invalid/a.jpg",
        "/uploads/../private.jpg",
        "/uploads/x%2Fy.png",
        "/api/private/x",
        "//internal/x",
    ],
)
async def test_image_refuses_arbitrary_download_and_traversal(path):
    client = BusinessClient(
        "https://fixture.invalid",
        Store(),
        transport=httpx.MockTransport(lambda r: pytest.fail("must not send")),
    )
    try:
        with pytest.raises(IntegrationProblem):
            await client.public_image(path)
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_actual_image_payload_fresh_visibility_and_fixed_chat_delivery():
    plugin, event, _ = fixture()
    img = Image.new("RGB", (20, 10), "green")
    raw = io.BytesIO()
    img.save(raw, format="PNG")
    plugin.client = SimpleNamespace(public_image=AsyncMock(return_value=raw.getvalue()))
    plugin.image_reference = AsyncMock(return_value=("/uploads/public.png", 2))
    event.send = AsyncMock()
    result = await plugin.public_image(event, "post", 811, send_to_chat=True)
    images = [c for c in result.content if isinstance(c, ImageContent)]
    assert len(images) == 1 and base64.b64decode(images[0].data).startswith(b"\xff\xd8")
    assert plugin.image_reference.await_count == 2 and event.send.await_count == 1
    assert "session" not in event.send.call_args.kwargs
    await plugin.public_image(event, "post", 811)
    assert (
        json.loads(await plugin.public_image(event, "post", 811))["error"]
        == "image_turn_limit"
    )


@pytest.mark.asyncio
async def test_native_executor_keeps_multimodal_result_instead_of_stringifying():
    from astrbot.core.astr_agent_tool_exec import FunctionToolExecutor

    plugin, event, _ = fixture()
    raw = io.BytesIO()
    Image.new("RGB", (2, 2), "blue").save(raw, format="PNG")
    plugin.client = SimpleNamespace(public_image=AsyncMock(return_value=raw.getvalue()))
    plugin.image_reference = AsyncMock(return_value=("/uploads/public.png", 1))
    tool = FunctionTool(
        name="sylulive_public_image",
        description="synthetic",
        parameters={},
        handler=plugin.public_image,
    )
    outputs = [
        r
        async for r in FunctionToolExecutor._execute_local(
            tool,
            ContextWrapper(context=SimpleNamespace(event=event)),
            source="post",
            source_id=811,
        )
    ]
    assert len(outputs) == 1 and any(
        isinstance(c, ImageContent) for c in outputs[0].content
    )


@pytest.mark.asyncio
async def test_group_disables_global_private_kb_before_native_retrieval(monkeypatch):
    from astrbot.api import sp
    from astrbot.core.tools.knowledge_base_tools import retrieve_knowledge_base

    plugin, event, _ = fixture()
    state = {}

    async def get(umo, key, default=None):
        return state.get((umo, key), default)

    async def put(umo, key, value):
        state[(umo, key)] = value

    monkeypatch.setattr(sp, "session_get", get)
    monkeypatch.setattr(sp, "session_put", put)
    await plugin.isolate_public_group_knowledge(event)
    ctx = SimpleNamespace(
        kb_manager=SimpleNamespace(),
        get_config=lambda **kw: {"kb_names": ["private-kb"]},
    )
    assert (
        await retrieve_knowledge_base("private search", event.unified_msg_origin, ctx)
        is None
    )
    assert state == {(event.unified_msg_origin, "kb_config"): {"kb_ids": []}}


@pytest.mark.asyncio
async def test_removed_image_not_sent_or_exposed_to_model_after_download():
    plugin, event, _ = fixture()
    raw = io.BytesIO()
    Image.new("RGB", (2, 2), "red").save(raw, format="PNG")
    plugin.client = SimpleNamespace(public_image=AsyncMock(return_value=raw.getvalue()))
    plugin.image_reference = AsyncMock(
        side_effect=[("/uploads/public.png", 1), IntegrationProblem("not_found")]
    )
    event.send = AsyncMock()
    result = json.loads(
        await plugin.public_image(event, "post", 811, send_to_chat=True)
    )
    assert result["error"] == "not_found" and event.send.await_count == 0
