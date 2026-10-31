"""首次吃什么请求必须完成随机、真实评价和同店图片；投递截获，不发 QQ。"""

import asyncio
import io
import json
from unittest.mock import AsyncMock

import pytest
from PIL import Image

from test_meal_followup import meal_fixture
from astrbot_plugin_sylulive.client import IntegrationProblem


def bundle_fixture(*, dish=True, review=True, cover=True):
    plugin, event, _ = meal_fixture()
    read = plugin.client.public_call.side_effect

    async def respond(path, **kwargs):
        if path.endswith('/dishes'):
            return {'items': [{'id': 8, 'name': '鸡腿饭', 'canteen_id': 119,
                               'photo_count': 1}] if dish else []}
        if path.endswith('/dishes/8'):
            return {'dish': {'id': 8, 'name': '鸡腿饭', 'canteen_id': 119},
                    'photos': [{'image': '/uploads/dish.jpg'}]}
        data = await read(path, **kwargs)
        if 'canteen' in data:
            data = {**data, 'canteen': {**data['canteen']}}
            if not cover:
                data['canteen']['image'] = ''
            if not review:
                data['display_reviews'] = []
        return data

    plugin.client.public_call = AsyncMock(side_effect=respond)
    raw = io.BytesIO()
    Image.new('RGB', (8, 6), 'red').save(raw, format='PNG')
    plugin.client.public_image = AsyncMock(return_value=raw.getvalue())
    event.message_str = '今天吃什么'
    event.send = AsyncMock()
    return plugin, event


@pytest.mark.asyncio
async def test_first_meal_command_sends_cover_dish_and_named_review_without_followup():
    plugin, event = bundle_fixture()
    replies = [r async for r in plugin.eat_command(event)]
    text = '\n'.join(p.text for r in replies for p in r.chain if hasattr(p, 'text'))
    assert event.send.await_count == 2
    assert plugin.client.public_image.await_args_list[0].args == ('/uploads/store.jpg',)
    assert plugin.client.public_image.await_args_list[1].args == ('/uploads/dish.jpg',)
    assert '同学甲（2026-10-31）' in text and '味道清爽' in text
    assert '门面' in text and '实拍' in text and '已附' in text
    assert '想看可以说' not in text and '73' not in text
    labels = '\n'.join(p.text for call in event.send.await_args_list
                       for p in call.args[0].chain if hasattr(p, 'text'))
    assert '饮品' in labels and '鸡腿饭' in labels
    assert event.is_stopped()


@pytest.mark.asyncio
async def test_llm_meal_tool_bundles_once_and_does_not_reroll_or_resend():
    plugin, event = bundle_fixture()
    first = json.loads(await plugin.eat_what(event))
    second = json.loads(await plugin.eat_what(event))
    assert first == second and event.send.await_count == 2
    assert first['detail']['reviews'][0]['user_name'] == '同学甲'
    assert all(row['state'] == 'sent' for row in first['image_delivery'])
    assert sum(c.args[0].endswith('/rankings')
               for c in plugin.client.public_call.await_args_list) == 1


@pytest.mark.asyncio
async def test_parallel_tool_calls_share_one_selection_and_delivery():
    plugin, event = bundle_fixture()
    first, second = await asyncio.gather(plugin.eat_what(event), plugin.eat_what(event))
    assert first == second and event.send.await_count == 2
    assert sum(c.args[0].endswith('/rankings')
               for c in plugin.client.public_call.await_args_list) == 1


@pytest.mark.asyncio
async def test_cached_recommendation_does_not_bypass_removed_read_permission():
    plugin, event = bundle_fixture()
    await plugin.eat_what(event)
    plugin.config['public_read_group_ids'] = []
    result = json.loads(await plugin.eat_what(event))
    assert result['error'] == 'public_session_required'
    assert event.send.await_count == 2


@pytest.mark.asyncio
async def test_next_turn_switches_random_selection_and_keeps_all_photos_on_same_store():
    plugin, event = bundle_fixture()
    read = plugin.client.public_call.side_effect

    async def two_stores(path, **kwargs):
        data = await read(path, **kwargs)
        if path.endswith('/rankings'):
            return {'items': [{'id': n, 'name': f'档口{n}'} for n in (119, 120)]}
        if path.endswith('/dishes'):
            return {'items': []}
        if '/canteens/' in path and '/dishes/' not in path:
            ident = int(path.split('/')[-1])
            data = {**data, 'canteen': {**data['canteen'], 'id': ident,
                                       'name': f'档口{ident}'}}
        return data

    plugin.client.public_call.side_effect = two_stores
    first = json.loads(await plugin.eat_what(event))
    _, next_event = bundle_fixture()
    next_event.message_str = '换一家'
    second = json.loads(await plugin.eat_what(next_event))
    assert first['selection']['id'] != second['selection']['id']
    assert next_event.send.await_count == 2
    labels = '\n'.join(p.text for call in next_event.send.await_args_list
                       for p in call.args[0].chain if hasattr(p, 'text'))
    assert f"档口{second['selection']['id']}" in labels
    assert f"档口{first['selection']['id']}" not in labels


@pytest.mark.asyncio
async def test_review_photo_is_labelled_as_review_not_dish_when_no_approved_dish():
    plugin, event = bundle_fixture(dish=False)
    result = json.loads(await plugin.eat_what(event))
    assert [r['kind'] for r in result['image_delivery']] == ['storefront', 'review']
    assert plugin.client.public_image.await_args_list[1].args == ('/uploads/review.jpg',)
    assert '菜品实拍' in result['presentation'] and '暂未' in result['presentation']


@pytest.mark.asyncio
@pytest.mark.parametrize('prompt', ['今天吃什么，不要发图', '今天吃什么，只给你看',
                                  '今天吃什么，图片私聊发我'])
async def test_meal_respects_no_send_and_different_chat_target(prompt):
    plugin, event = bundle_fixture()
    event.message_str = prompt
    result = json.loads(await plugin.eat_what(event))
    event.send.assert_not_awaited()
    assert result['image_delivery'] == []
    assert '未发送图片' in result['presentation']


@pytest.mark.asyncio
async def test_no_photos_no_reviews_still_recommends_without_inventing():
    plugin, event = bundle_fixture(dish=False, review=False, cover=False)
    result = json.loads(await plugin.eat_what(event))
    event.send.assert_not_awaited()
    assert '没有公开评价' in result['presentation']
    assert '没有可用' in result['presentation']


@pytest.mark.asyncio
async def test_dish_gallery_network_failure_is_not_reported_as_no_photo():
    plugin, event = bundle_fixture(review=False, cover=False)
    read = plugin.client.public_call.side_effect

    async def unavailable(path, **kwargs):
        if path.endswith('/dishes'):
            raise IntegrationProblem('network_unavailable')
        return await read(path, **kwargs)

    plugin.client.public_call.side_effect = unavailable
    result = json.loads(await plugin.eat_what(event))
    event.send.assert_not_awaited()
    assert '读取失败' in result['presentation']
    assert '没有可用的公开图片' not in result['presentation']


@pytest.mark.asyncio
async def test_uncertain_first_photo_stops_batch_and_does_not_retry():
    plugin, event = bundle_fixture()
    event.send.side_effect = RuntimeError('synthetic delivery timeout')
    first = json.loads(await plugin.eat_what(event))
    await plugin.eat_what(event)
    assert event.send.await_count == 1
    assert first['image_delivery'][0]['state'] == 'uncertain'
    assert '不确定' in first['presentation'] and '已附' not in first['presentation']


@pytest.mark.asyncio
async def test_removed_dish_photo_never_delivers_old_bytes():
    plugin, event = bundle_fixture(cover=False)
    read = plugin.client.public_call.side_effect
    calls = 0

    async def removed(path, **kwargs):
        nonlocal calls
        data = await read(path, **kwargs)
        if path.endswith('/dishes/8'):
            calls += 1
            if calls > 1:
                return {**data, 'photos': []}
        return data

    plugin.client.public_call.side_effect = removed
    result = json.loads(await plugin.eat_what(event))
    event.send.assert_not_awaited()
    assert result['image_delivery'][0]['state'] == 'failed'
    assert '已附' not in result['presentation']
