"""验证报名指引进入现有详情字段，并保留原文及目录发布门禁。"""

from copy import deepcopy
from datetime import date
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _catalog_v2 import build_document, validate_document
from merge_schedules import audit_coverage, merge_schedules, TIME_FIELDS
from registration_info import apply_registration, validate_registration, START, END
from test_merge_schedules import fixture

ROOT = Path(__file__).parent


def registration_fixture():
    data = json.loads((ROOT / 'data/verified_registration_2026.json').read_text(encoding='utf-8'))
    data['items'] = [x for x in data['items'] if x['competition_id'] == 'NAT-066']
    return data


class RegistrationInfoTest(unittest.TestCase):
    def test_merge_retains_description_sources_gates_and_is_idempotent(self):
        catalog, schedules = fixture()
        row = {**catalog['items'][0], 'description': '原有人工介绍\n第二段',
               'official_url': 'https://example.org/original'}
        catalog = build_document([row], dataset_version='base', publish_status='draft',
                                 production_load_allowed=False, source_filename='test.json')
        original = deepcopy(catalog)
        registration = registration_fixture()
        merged = merge_schedules(catalog, schedules, 'new', registration)
        result = merged['items'][0]
        self.assertIn('原有人工介绍\n第二段', result['description'])
        self.assertIn('由队长创建3人队伍', result['description'])
        self.assertIn('https://cpipc.acge.org.cn/cw/hp/4', result['description'])
        self.assertEqual(result['official_url'], row['official_url'])
        self.assertEqual(result['description'].count(START), 1)
        self.assertFalse(merged['production_load_allowed'])
        self.assertEqual(merged['publish_status'], 'draft')
        for key, value in catalog['items'][0].items():
            if key not in {*TIME_FIELDS, 'description', 'official_url', 'notice_url', 'record_hash'}:
                self.assertEqual(result[key], value, key)
        self.assertEqual(catalog, original)
        self.assertEqual(validate_document(merged), [])
        self.assertEqual(merge_schedules(merged, schedules, 'newer', registration)['items'], merged['items'])

    def test_updates_managed_block_only_and_retains_existing_notice(self):
        catalog, _ = fixture()
        rows = deepcopy(catalog['items'])
        rows[0].update(description=f'前言\n{START}\n旧指引\n{END}\n后记',
                       notice_url='https://example.org/school')
        result = apply_registration(rows, registration_fixture())[0]
        self.assertTrue(result['description'].startswith('前言\n'))
        self.assertTrue(result['description'].endswith('\n后记'))
        self.assertNotIn('旧指引', result['description'])
        self.assertEqual(result['notice_url'], rows[0]['notice_url'])
        self.assertEqual(result['official_url'], 'https://cpipc.acge.org.cn/cw/hp/4')

    def test_rejects_identity_mismatch_and_broken_managed_blocks(self):
        for change in [{'title': '错误赛事'}, {'competition_id': 'NAT-999'},
                       {'description': START}, {'description': END + START},
                       {'description': START + END + START + END}]:
            catalog, _ = fixture()
            rows = deepcopy(catalog['items'])
            rows[0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                apply_registration(rows, registration_fixture())

    def test_rejects_unsupported_or_unverified_registration_data(self):
        changes = [{'source_ids': []}, {'season_year': 2025}, {'steps': []},
                   {'competition_id': 'PROV-066', 'scope': 'national'},
                   {'entry_url': 'javascript:alert(1)'}, {'entry_url': 'https://a b.test/'},
                   {'entry_url': 'https://example.org:wrong/'},
                   {'candidate_pool_allowed': True}, {'steps': ['']},
                   {'status': 'entry_only', 'entry_url': ''}]
        for change in changes:
            data = registration_fixture()
            data['items'][0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_registration(data, today=date(2026, 9, 9))
        data = registration_fixture()
        data['items'].append(deepcopy(data['items'][0]))
        with self.assertRaises(ValueError):
            validate_registration(data)

    def test_all_shipped_patches_pass_complete_catalog_merge_without_enabling_publish(self):
        schedules = json.loads((ROOT / 'data/verified_schedules_2026.json').read_text(encoding='utf-8'))
        registration = json.loads((ROOT / 'data/verified_registration_2026.json').read_text(encoding='utf-8'))
        template = fixture()[0]['items'][0]
        identities = {x['competition_id']: x['expected_title']
                      for x in schedules['items'] + registration['items']}
        rows = [{**template, 'competition_id': key, 'title': title} for key, title in identities.items()]
        catalog = build_document(rows, dataset_version='test-base', publish_status='draft',
                                 production_load_allowed=False, source_filename='synthetic-test-only.json')
        merged = merge_schedules(catalog, schedules, 'test-combined', registration)
        self.assertEqual(validate_document(merged), [])
        self.assertFalse(merged['production_load_allowed'])
        self.assertEqual(sum(START in x.get('description', '') for x in merged['items']), len(registration['items']))
        audit = audit_coverage({'total': len(rows), 'items': rows}, schedules, registration)
        self.assertEqual(audit['registration_guide_count'], len(registration['items']))
        self.assertEqual(audit['verified_on'], '2026-09-09')
        self.assertGreater(audit['pending_count'], 0)
        self.assertNotIn('schema_version', audit)

    def test_cli_refuses_overwriting_registration_input(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'registration.json'
            original = json.dumps(registration_fixture(), ensure_ascii=False)
            path.write_text(original, encoding='utf-8')
            result = subprocess.run([sys.executable, str(ROOT / 'merge_schedules.py'),
                                     'merge', 'not-read.json', 'not-read-either.json', str(path),
                                     '--registration', str(path), '--dataset-version', 'new'],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(encoding='utf-8'), original)

    def test_historical_guides_keep_year_and_cannot_downgrade_current_guide(self):
        catalog, _ = fixture()
        data = registration_fixture()
        current = apply_registration(catalog['items'], data)
        data['items'][0].update(status='historical', season_year=2025)
        with self.assertRaises(ValueError):
            apply_registration(current, data)
        result = apply_registration(catalog['items'], data)[0]
        self.assertIn('2025届', result['description'])
        self.assertIn('往年报名方式，仅供参考', result['description'])
        self.assertFalse(result.get('official_url'))
        self.assertEqual(result['time_status'], 'pending')
        self.assertFalse(result.get('registration_end'))


if __name__ == '__main__':
    unittest.main()
