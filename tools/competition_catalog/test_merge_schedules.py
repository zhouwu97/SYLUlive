"""验证日程补录不会改变目录治理信息或混用年份、地区和截止时间。"""
from copy import deepcopy
from datetime import date
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _catalog_v2 import build_document, validate_document
from merge_schedules import merge_schedules, validate_schedules, audit_coverage, TIME_FIELDS


def fixture():
    schedules = json.loads((Path(__file__).parent / 'data/verified_schedules_2026.json').read_text(encoding='utf-8'))
    schedules['items'] = [next(x for x in schedules['items'] if x['competition_id'] == 'NAT-066')]
    item = schedules['items'][0]
    record = {'competition_id': item['competition_id'], 'title': item['expected_title'],
              'time_status': 'pending', 'time_precision': 'unknown', 'status': 'published',
              'recommendation_permission_level': 'blocked', 'ai_mode': 'catalog_only',
              'search_display_allowed': True, 'candidate_pool_allowed': False,
              'blocker_codes': ['needs_review'], 'competition_rating': 'B+',
              'registration_time_text': '', 'notice_url': ''}
    catalog = build_document([record], dataset_version='base', publish_status='draft',
                             production_load_allowed=False, source_filename='base.json')
    return catalog, schedules


class ScheduleMergeTest(unittest.TestCase):
    def test_only_schedule_and_notice_change_and_gates_are_preserved(self):
        catalog, schedules = fixture()
        original = deepcopy(catalog)
        merged = merge_schedules(catalog, schedules, 'base-schedule-20260908')
        self.assertEqual(catalog, original)
        self.assertFalse(merged['production_load_allowed'])
        self.assertEqual(merged['publish_status'], 'draft')
        self.assertEqual(validate_document(merged), [])
        for key, value in catalog['items'][0].items():
            if key not in {*TIME_FIELDS, 'notice_url', 'record_hash'}:
                self.assertEqual(merged['items'][0][key], value, key)
        self.assertIn('核验 2026-09-08', merged['items'][0]['time_note'])
        self.assertEqual(merged['items'][0]['registration_end'], '2026-09-19T09:00:00Z')

    def test_rejects_missing_sources_wrong_year_range_scope_and_permission_changes(self):
        for mutate in [
            lambda x: x.update(source_ids=[]),
            lambda x: x.update(season_year=2024),
            lambda x: x['fields'].update(registration_end='2026-01-01'),
            lambda x: x.update(competition_id='PROV-066', scope='national'),
            lambda x: x['fields'].update(candidate_pool_allowed=True),
            lambda x: x['fields'].update(time_status='historical'),
            lambda x: x['fields'].update(registration_end='2026-09-19T17:00:00'),
        ]:
            _, schedules = fixture()
            mutate(schedules['items'][0])
            with self.assertRaises(ValueError):
                validate_schedules(schedules, today=date(2026, 9, 8))

    def test_refuses_public_dto_instead_of_complete_catalog(self):
        catalog, schedules = fixture()
        with self.assertRaises(ValueError):
            merge_schedules({'items': catalog['items']}, schedules, 'new')

    def test_reapplying_identical_instants_accepts_utc_normalization(self):
        catalog, schedules = fixture()
        once = merge_schedules(catalog, schedules, 'new')
        twice = merge_schedules(once, schedules, 'newer')
        self.assertEqual(once['items'], twice['items'])

    def test_conflicting_existing_date_and_wrong_title_require_review(self):
        for change in [{'title': '其他赛事'}, {'registration_end': '2026-09-18'}]:
            catalog, schedules = fixture()
            catalog['items'][0].update(change)
            catalog = build_document(catalog['items'], dataset_version='base', publish_status='draft',
                                     production_load_allowed=False, source_filename='base.json')
            with self.assertRaises(ValueError):
                merge_schedules(catalog, schedules, 'new')

    def test_audit_cannot_claim_full_coverage_for_incomplete_pages(self):
        catalog, schedules = fixture()
        snapshot = {'total': 2, 'items': catalog['items']}
        with self.assertRaises(ValueError):
            audit_coverage(snapshot, schedules)
        snapshot['total'] = 1
        self.assertEqual(audit_coverage(snapshot, schedules)['reviewed'], 1)

    def test_shipped_evidence_is_valid_and_unique(self):
        schedules = json.loads((Path(__file__).parent / 'data/verified_schedules_2026.json').read_text(encoding='utf-8'))
        validate_schedules(schedules, today=date(2026, 9, 8))
        # 全量补录也要经过真实目录规范化，覆盖说明长度和哈希校验。
        template = fixture()[0]['items'][0]
        records = [{**template, 'competition_id': item['competition_id'],
                    'title': item['expected_title']} for item in schedules['items']]
        catalog = build_document(records, dataset_version='test-base', publish_status='draft',
                                 production_load_allowed=False, source_filename='test.json')
        merged = merge_schedules(catalog, schedules, 'test-schedules')
        self.assertEqual(validate_document(merged), [])
        self.assertEqual(len(merged['items']), len(schedules['items']))

    def test_platform_window_does_not_replace_earlier_school_deadline(self):
        schedules = json.loads((Path(__file__).parent / 'data/verified_schedules_2026.json').read_text(encoding='utf-8'))
        items = {item['competition_id']: item for item in schedules['items']}
        self.assertEqual(items['PROV-001']['fields']['registration_end'], '2026-08-15')
        self.assertEqual(items['PROV-149']['fields']['registration_end'], '2026-06-18T08:00:00+08:00')
        self.assertIn('2026-06-18 20:00:00', items['PROV-149']['fields']['registration_time_text'])
        for key in ('PROV-139', 'PROV-019'):
            fields = items[key]['fields']
            self.assertEqual(fields['time_status'], 'pending')
            self.assertNotIn('registration_end', fields)
            self.assertNotIn('registration_start', fields)
        self.assertNotIn('registration_end', items['PROV-035']['fields'])

    def test_platform_evidence_rejects_invalid_window_and_season(self):
        for start, end in [('2026-06-01T00:00:00', '2026-09-19T17:00:00+08:00'),
                           ('2026-10-01T00:00:00+08:00', '2026-09-19T17:00:00+08:00'),
                           ('2025-06-01T00:00:00+08:00', '2025-09-19T17:00:00+08:00')]:
            _, schedules = fixture()
            source = schedules['sources'][schedules['items'][0]['source_ids'][0]]
            source['registration_window'] = {'start': start, 'end': end}
            with self.assertRaises(ValueError):
                validate_schedules(schedules, today=date(2026, 9, 8))


if __name__ == '__main__':
    unittest.main()
