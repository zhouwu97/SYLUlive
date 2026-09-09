"""校验报名补录，并以现有目录字段承载报名入口及步骤，避免改变发布权限。"""

from copy import deepcopy
from datetime import date
from urllib.parse import urlparse

SCOPES = {'national': '全国赛事', 'liaoning': '辽宁赛区', 'sylu': '沈阳理工大学校内'}
START = '【报名指引补录】'
END = '【报名指引补录结束】'


def valid_url(value):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        return False
    try:
        parsed = urlparse(value)
        host = parsed.hostname
        parsed.port
    except ValueError:
        return False
    return (parsed.scheme in {'http', 'https'} and bool(host)
            and not parsed.username and not parsed.password)


def validate_registration(document, *, today=None):
    today = today or date.today()
    if document.get('schema_version') != 'sylulive-competition-registration/1':
        raise ValueError('报名补录版本不兼容')
    checked = date.fromisoformat(document['verified_on'])
    if checked > today:
        raise ValueError('报名核验日期不能在未来')
    sources = document['sources']
    for source in sources.values():
        if not source.get('title') or not source.get('publisher') or not valid_url(source['url']):
            raise ValueError('报名来源必须包含标题、发布方和有效 HTTP(S) 链接')
    seen = set()
    for item in document['items']:
        key = item['competition_id']
        if set(item) - {'competition_id', 'expected_title', 'season_year', 'scope', 'status',
                        'entry_url', 'scope_note', 'source_ids', 'steps', 'materials', 'contacts'}:
            raise ValueError(f'{key}: 报名补录不能包含其他目录或治理字段')
        if key in seen:
            raise ValueError(f'{key}: 重复报名记录')
        seen.add(key)
        if not item.get('expected_title') or item.get('scope') not in SCOPES:
            raise ValueError(f'{key}: 缺少赛事身份或适用范围')
        if key.startswith('PROV-') and item['scope'] == 'national':
            raise ValueError(f'{key}: 省级条目不能直接使用全国报名流程')
        if item.get('status') not in {'verified', 'entry_only', 'historical'}:
            raise ValueError(f'{key}: 报名核验状态无效')
        if item.get('season_year') != checked.year and item['status'] != 'historical':
            raise ValueError(f'{key}: 旧届报名方式须标为往年参考')
        if item['status'] == 'historical' and item['season_year'] >= checked.year:
            raise ValueError(f'{key}: 往年参考届次无效')
        if not item.get('source_ids') or any(s not in sources for s in item['source_ids']):
            raise ValueError(f'{key}: 报名方式缺少证据')
        if item.get('entry_url') and not valid_url(item['entry_url']):
            raise ValueError(f'{key}: 报名入口必须为 HTTP(S) 链接')
        if item['status'] == 'verified' and not item.get('steps'):
            raise ValueError(f'{key}: 已核验报名记录必须有具体步骤')
        if item['status'] == 'entry_only' and not item.get('entry_url'):
            raise ValueError(f'{key}: 入口核验记录必须有报名入口')
        if not item.get('scope_note'):
            raise ValueError(f'{key}: 必须说明校内、赛道或阶段边界')
        for field in ('steps', 'materials', 'contacts'):
            values = item.get(field, [])
            if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() for v in values):
                raise ValueError(f'{key}: {field} 必须是非空文本列表')


def apply_registration(rows, document):
    validate_registration(document)
    result = deepcopy(rows)
    by_id = {r['competition_id']: r for r in result}
    for item in document['items']:
        key = item['competition_id']
        record = by_id.get(key)
        if record is None or record['title'] != item['expected_title']:
            raise ValueError(f'{key}: 报名补录与目录主键或标题不一致')
        state = {'verified': '报名方式已核验', 'entry_only': '入口已核验，具体步骤待补充',
                 'historical': '往年报名方式，仅供参考'}[item['status']]
        parts = [START, f"{item['season_year']}届 · {SCOPES[item['scope']]} · {state}", item['scope_note']]
        if item.get('entry_url'):
            parts.append('报名入口：' + item['entry_url'])
        parts.extend(f'{i}. {step}' for i, step in enumerate(item.get('steps', []), 1))
        for label, field in [('材料', 'materials'), ('联系', 'contacts')]:
            parts.extend(f'{label}：{value}' for value in item.get(field, []))
        parts.extend('来源：' + document['sources'][s]['url'] for s in item['source_ids'])
        parts.extend(['核验日期：' + document['verified_on'], END])
        block = '\n'.join(parts)
        original = record.get('description', '') or ''
        # 仅替换本工具管理的区段，不覆盖人工说明，也不重复追加报名流程。
        if START in original or END in original:
            if original.count(START) != 1 or original.count(END) != 1 or original.index(END) < original.index(START):
                raise ValueError(f'{key}: 现有报名区段边界异常，需人工复核')
            before, rest = original.split(START, 1)
            managed, after = rest.split(END, 1)
            if item['status'] == 'historical' and '往年报名方式，仅供参考' not in managed:
                raise ValueError(f'{key}: 往年报名指引不能覆盖已核验的当届指引')
            record['description'] = before + block + after
        else:
            record['description'] = (block + '\n\n' + original).strip()
        # 已有官网及校内通知优先保留；入口同时写入指引，避免改掉原有有效来源。
        if item['status'] != 'historical' and not record.get('official_url') and item.get('entry_url'):
            record['official_url'] = item['entry_url']
        if not record.get('notice_url'):
            record['notice_url'] = document['sources'][item['source_ids'][0]]['url']
    return result
