import io
import json
from unittest.mock import AsyncMock

import pytest
from PIL import Image
from test_group_public_read import fixture
from astrbot_plugin_sylulive.chat_media import sticker_request


@pytest.mark.asyncio
async def test_explicit_sticker_request_uses_current_chat_without_a_second_model():
    plugin, event, _ = fixture()
    plugin.config['community_chat_memes_enabled'] = True
    event.is_at_or_wake_command = True
    event.message_str = '给我发一张开心表情图片。'
    plugin.stickers = AsyncMock(return_value='{"data":{"items":[{"sticker_id":"' + 'a' * 32 + '"}]}}')
    plugin.send_sticker = AsyncMock(return_value='{"state":"sent"}')
    assert [item async for item in plugin.daily_shortcuts(event)] == []
    plugin.send_sticker.assert_awaited_once_with(event, 'a' * 32)
    assert event.is_stopped()
    assert sticker_request('帖子里说给我发表情，请总结') is None
    assert sticker_request('给我发一个好耶的表情') == '好耶'


@pytest.mark.asyncio
async def test_sticker_search_accepts_common_happy_intent():
    plugin, event, _ = fixture()
    plugin.tool = AsyncMock(return_value='{"data":{"items":[]}}')
    await plugin.stickers(event, query='开心')
    assert plugin.tool.await_args.args[-1]['query'] == '好耶'


@pytest.mark.asyncio
async def test_builtin_sticker_delivers_once_to_current_chat_and_rejects_unknown():
    plugin, event, _ = fixture()
    plugin.config['community_chat_memes_enabled'] = True
    plugin.allowed_reading = lambda event: True
    ident = 'a' * 32
    plugin.stickers = AsyncMock(return_value=json.dumps({'data': {'items': [{'sticker_id': ident}]}}))
    raw = io.BytesIO()
    Image.new('RGB', (2, 2), 'white').save(raw, 'PNG')
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    event.send = AsyncMock()
    assert json.loads(await plugin.send_sticker(event, ident))['state'] == 'sent'
    assert event.send.await_count == 1
    assert plugin.client.public_image.await_args.args == ('/stickers/' + ident,)
    assert json.loads(await plugin.send_sticker(event, ident))['state'] == 'sent'
    assert event.send.await_count == 1
    assert json.loads(await plugin.send_sticker(event, '../secret'))['error'] == 'invalid_sticker'
    plugin.stickers.return_value = json.dumps({'data': {'items': []}})
    assert json.loads(await plugin.send_sticker(event, 'b' * 32))['error'] == 'sticker_not_found'
    plugin.config['community_chat_memes_enabled'] = False
    assert json.loads(await plugin.send_sticker(event, ident))['error'] == 'permission_denied'
    assert event.send.await_count == 1


@pytest.mark.asyncio
async def test_sticker_send_uncertain_result_is_not_automatically_resent():
    plugin, event, _ = fixture()
    plugin.config['community_chat_memes_enabled'] = True
    plugin.allowed_reading = lambda event: True
    ident = 'a' * 32
    plugin.stickers = AsyncMock(return_value=json.dumps({'data': {'items': [{'sticker_id': ident}]}}))
    raw = io.BytesIO()
    Image.new('RGB', (2, 2), 'white').save(raw, 'PNG')
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    event.send = AsyncMock(side_effect=RuntimeError('synthetic uncertain send'))
    assert json.loads(await plugin.send_sticker(event, ident))['error'] == 'sticker_delivery_failed'
    assert json.loads(await plugin.send_sticker(event, ident))['state'] == 'attempted'
    assert event.send.await_count == 1
