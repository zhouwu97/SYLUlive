"""将已核验日程合并到完整 Catalog 2.2；不会请求写接口或从公开 DTO 重建治理字段。"""

from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import date, datetime
import json
from pathlib import Path
from urllib.parse import urlparse

from _catalog_v2 import build_document, validate_document, normalize_record
from registration_info import apply_registration

DATE_FIELDS = ('registration_start', 'registration_end', 'event_start', 'event_end')
TIME_FIELDS = (*DATE_FIELDS, 'registration_time_text', 'event_time_text',
               'time_status', 'time_precision', 'time_note', 'sort_month')
SCOPES = {'national': '全国赛事', 'liaoning': '辽宁赛区', 'sylu': '沈阳理工大学校内'}


def validate_schedules(schedules: dict, *, today: date | None = None) -> None:
    today = today or date.today()
    if schedules.get('schema_version') != 'sylulive-competition-schedules/1':
        raise ValueError('日程文件版本不兼容')
    checked = date.fromisoformat(schedules['verified_on'])
    if checked > today:
        raise ValueError('核验日期不能在未来')
    if not schedules.get('items'):
        raise ValueError('日程清单不能为空')
    sources = schedules['sources']
    for source in sources.values():
        url = urlparse(source['url'])
        if url.scheme not in {'http', 'https'} or not url.hostname or url.username or url.password:
            raise ValueError('证据链接必须是无凭据的 HTTP(S) URL')
        if not source.get('publisher') or not source.get('title'):
            raise ValueError('证据必须注明发布单位和通知标题')
        window = source.get('registration_window')
        if window is not None:
            start, end = (datetime.fromisoformat(window[key].replace('Z', '+00:00'))
                          for key in ('start', 'end'))
            if start.tzinfo is None or end.tzinfo is None or end < start:
                raise ValueError('平台报名窗口必须有时区且结束不早于开始')
    seen = set()
    for item in schedules['items']:
        key = item['competition_id']
        item_checked = date.fromisoformat(item.get('verified_on', schedules['verified_on']))
        if item_checked > today:
            raise ValueError(f'{key}: 单条核验日期不能在未来')
        if key in seen:
            raise ValueError(f'{key}: 重复日程，请先解决来源冲突')
        seen.add(key)
        if not item.get('expected_title') or item.get('scope') not in SCOPES:
            raise ValueError(f'{key}: 缺少准确标题或适用范围')
        if key.startswith('PROV-') and item['scope'] == 'national':
            raise ValueError(f'{key}: 全国截止不能直接用作省赛截止')
        if not item.get('source_ids') or any(s not in sources for s in item['source_ids']):
            raise ValueError(f'{key}: 缺少可追溯来源')
        for source_id in item['source_ids']:
            window = sources[source_id].get('registration_window')
            if window and any(datetime.fromisoformat(value.replace('Z', '+00:00')).year
                              not in {item['season_year'], item['season_year'] + 1}
                              for value in window.values()):
                raise ValueError(f'{key}: 平台来源届次不一致')
        fields = item['fields']
        if set(fields) - set(TIME_FIELDS):
            raise ValueError(f'{key}: 日程补录不能修改评级、权限或其他治理字段')
        if fields.get('time_status') not in {'confirmed', 'historical', 'estimated', 'pending'}:
            raise ValueError(f'{key}: 时间状态无效')
        if fields['time_status'] == 'historical' and item['season_year'] >= checked.year:
            raise ValueError(f'{key}: 往年参考必须注明早于核验年份的真实届次')
        if not fields.get('registration_time_text', '').strip():
            raise ValueError(f'{key}: 必须说明报名安排或未确认原因')
        parsed = {}
        for field in DATE_FIELDS:
            value = fields.get(field)
            if not value:
                continue
            parsed[field] = datetime.fromisoformat(value.replace('Z', '+00:00'))
            if len(value) > 10 and parsed[field].tzinfo is None:
                raise ValueError(f'{key}: 具体时刻必须包含时区')
            if parsed[field].year not in {item['season_year'], item['season_year'] + 1}:
                raise ValueError(f'{key}: 日期与届次不一致')
            if fields['time_status'] != 'confirmed':
                raise ValueError(f'{key}: 参考日期只放在说明中，不写入截止提醒字段')
        for start, end in [('registration_start', 'registration_end'), ('event_start', 'event_end')]:
            if start in parsed and end in parsed:
                # 比较日期时按同一时区归一；只给日期的字段仅比较自然日。
                a, b = parsed[start], parsed[end]
                if a.tzinfo is None or b.tzinfo is None:
                    reversed_range = b.date() < a.date()
                else:
                    reversed_range = b < a
                if reversed_range:
                    raise ValueError(f'{key}: 结束时间早于开始时间')
        if fields['time_status'] == 'confirmed' and item['season_year'] < checked.year:
            raise ValueError(f'{key}: 旧届日程应标为 historical，不能当成当届')


def add_historical_fallbacks(current: dict, historical: dict) -> dict:
    """仅补缺失或更旧的参考；当届安排和当届冲突证据优先于往年记录。"""
    validate_schedules(current)
    validate_schedules(historical)
    result = deepcopy(current)
    by_id = {item['competition_id']: item for item in result['items']}
    for item in historical['items']:
        key = item['competition_id']
        if item['fields']['time_status'] != 'historical':
            raise ValueError(f'{key}: 此补缺操作只接受注明真实年份的往年参考')
        existing = by_id.get(key)
        if existing:
            if existing['expected_title'] != item['expected_title']:
                raise ValueError(f'{key}: 赛事标题不一致')
            if (existing['fields']['time_status'] != 'historical'
                    or existing['season_year'] >= item['season_year']):
                continue
            result['items'].remove(existing)
        for source_id in item['source_ids']:
            source = historical['sources'][source_id]
            if source_id in result['sources'] and result['sources'][source_id] != source:
                raise ValueError(f'{source_id}: 同名证据冲突')
            result['sources'][source_id] = deepcopy(source)
        copied = deepcopy(item)
        result['items'].append(copied)
        by_id[key] = copied
    result['verified_on'] = max(current['verified_on'], historical['verified_on'])
    result['items'].sort(key=lambda item: item['competition_id'])
    validate_schedules(result)
    return result


def merge_schedules(catalog: dict, schedules: dict, dataset_version: str,
                    registration: dict | None = None) -> dict:
    errors = validate_document(catalog)
    if errors:
        raise ValueError('需要管理员导出的完整有效目录包：' + '; '.join(errors))
    validate_schedules(schedules)
    if not dataset_version.strip() or dataset_version == catalog['dataset_version']:
        raise ValueError('补录必须使用新的 dataset_version')
    rows = deepcopy(catalog['items'])
    by_id = {r['competition_id']: r for r in rows}
    for item in schedules['items']:
        key = item['competition_id']
        if key not in by_id or by_id[key]['title'] != item['expected_title']:
            raise ValueError(f'{key}: 目录主键或标题不匹配，需人工复核')
        record = by_id[key]
        fields = item['fields']
        if fields['time_status'] == 'historical' and record.get('time_status') != 'historical':
            if (record.get('time_status') == 'confirmed'
                    or any(str(record.get(field) or '').strip()
                           for field in ('registration_time_text', 'event_time_text'))):
                raise ValueError(f'{key}: 往年参考不能覆盖已有当届安排或冲突说明')
        normalized_fields = normalize_record(fields)
        # 不覆盖后来核实的截止时间；来源变更必须先人工解决冲突。
        for field in DATE_FIELDS:
            old, new = record.get(field), normalized_fields.get(field)
            if old and old != new:
                raise ValueError(f'{key}: {field} 与已有日期冲突')
        for field in TIME_FIELDS:
            record.pop(field, None)
        record.update(fields)
        record.setdefault('time_precision', 'exact' if any(fields.get(f) for f in DATE_FIELDS) else 'unknown')
        source = schedules['sources'][item['source_ids'][0]]
        source_urls = '；'.join(schedules['sources'][key]['url'] for key in item['source_ids'])
        note = fields.get('time_note', '')
        scope = SCOPES[item['scope']]
        checked = item.get('verified_on', schedules['verified_on'])
        record['time_note'] = f"{item['season_year']}届；{scope}；核验 {checked}。{note} 来源：{source_urls}"
        if len(record['time_note']) > 500:
            raise ValueError(f'{key}: 时间说明超过数据库长度限制')
        # 通知入口属于本次核验；不改变来源可信等级、推荐权限或赛事实体关系。
        record['notice_url'] = source['url']
    if registration is not None:
        rows = apply_registration(rows, registration)
    document = build_document(
        rows, dataset_version=dataset_version,
        publish_status=catalog['publish_status'],
        production_load_allowed=catalog['production_load_allowed'],
        source_filename='verified-schedules.json',
    )
    errors = validate_document(document)
    if errors:
        raise ValueError('; '.join(errors))
    return document


def audit_coverage(snapshot: dict, schedules: dict, registration: dict | None = None) -> dict:
    validate_schedules(schedules)
    items = snapshot['items']
    expected = snapshot.get('total', snapshot.get('item_count'))
    if expected != len(items) or len({x['competition_id'] for x in items}) != expected:
        raise ValueError('目录快照不完整或有重复，请先完成分页核验')
    by_id = {x['competition_id']: x for x in items}
    for patch in schedules['items']:
        if by_id.get(patch['competition_id'], {}).get('title') != patch['expected_title']:
            raise ValueError(f"{patch['competition_id']}: 赛事身份不匹配")
    patched = {x['competition_id'] for x in schedules['items']}
    remaining = [
        {'competition_id': x['competition_id'], 'title': x['title'],
         'official_url': x.get('official_url', ''), 'reason': '尚未完成当届官方日程核验'}
        for x in items if x['competition_id'] not in patched
    ]
    historical_count = sum(x['fields']['time_status'] == 'historical' for x in schedules['items'])
    result = {'total': expected, 'reviewed': len(patched), 'historical_reference_count': historical_count,
            'confirmed_count': sum(x['fields']['time_status'] == 'confirmed' for x in schedules['items']),
            'pending_count': sum(x['fields']['time_status'] == 'pending' for x in schedules['items']),
            'event_date_count': sum(bool(x['fields'].get('event_start') or x['fields'].get('event_end'))
                                    for x in schedules['items']),
            'event_text_count': sum(bool(x['fields'].get('event_time_text')) for x in schedules['items']),
            'remaining': remaining,
            'verified_on': max([schedules['verified_on']] +
                               [x.get('verified_on', schedules['verified_on']) for x in schedules['items']]),
            'note': 'reviewed 表示有来源记录，不等于时间齐全或仍可报名；event_text_count 包含待确认说明。仅为本地补录覆盖统计，不代表线上数据。'}
    if registration is not None:
        # 复用真实合并的身份和格式检查，但审计不输出可激活的目录包。
        apply_registration(items, registration)
        registered = {x['competition_id'] for x in registration['items']}
        result['registration_guide_count'] = len(registered)
        result['registration_entry_only_count'] = sum(x['status'] == 'entry_only' for x in registration['items'])
        result['registration_historical_count'] = sum(x['status'] == 'historical' for x in registration['items'])
        result['verified_on'] = max(result['verified_on'], registration['verified_on'])
        result['registration_remaining'] = [
            {'competition_id': x['competition_id'], 'title': x['title']}
            for x in items if x['competition_id'] not in registered
        ]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['merge', 'audit', 'fallback'])
    parser.add_argument('catalog', type=Path)
    parser.add_argument('schedules', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--dataset-version')
    parser.add_argument('--registration', type=Path, help='可选：已核验报名入口和步骤补录')
    args = parser.parse_args()
    inputs = {args.catalog.resolve(), args.schedules.resolve()}
    if args.registration:
        inputs.add(args.registration.resolve())
    if args.output.resolve() in inputs:
        parser.error('输出不能覆盖输入事实源')
    if args.registration and args.mode == 'fallback':
        parser.error('fallback 不接受报名补录')
    try:
        catalog = json.loads(args.catalog.read_text(encoding='utf-8-sig'))
        schedules = json.loads(args.schedules.read_text(encoding='utf-8-sig'))
        registration = (json.loads(args.registration.read_text(encoding='utf-8-sig'))
                        if args.registration else None)
        if args.mode == 'merge':
            if not args.dataset_version:
                parser.error('merge 需要 --dataset-version')
            output = merge_schedules(catalog, schedules, args.dataset_version, registration)
        elif args.mode == 'fallback':
            output = add_historical_fallbacks(catalog, schedules)
        else:
            output = audit_coverage(catalog, schedules, registration)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    except (ValueError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    print(f'已生成 {args.output}；未写入线上数据')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
