import contextlib
import asyncio
import builtins
import importlib.util
import io
import json
import logging
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).parents[1] / 'benchmark_academic_access.py'
spec = importlib.util.spec_from_file_location('academic_benchmark', path)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class AcademicBenchmarkTests(unittest.TestCase):
    def test_missing_dependency_returns_safe_error_and_clears_credentials(self):
        original_import = builtins.__import__
        def unavailable(name, *args, **kwargs):
            if name == 'services.crawler':
                raise ModuleNotFoundError('fixture missing dependency')
            return original_import(name, *args, **kwargs)
        credentials = {'student_id':'2099000001','password':'fixture-only'}
        previous_logging = logging.root.manager.disable
        with patch('builtins.__import__', side_effect=unavailable):
            result = asyncio.run(benchmark.benchmark(credentials,year='2026',semester=1,samples=1))
        self.assertEqual(credentials, {})
        self.assertEqual(result['error_code'], 'ModuleNotFoundError')
        self.assertFalse(result['authenticated'])
        self.assertEqual(logging.root.manager.disable, previous_logging)

    def test_percentiles_include_small_sample_interpolation(self):
        self.assertEqual(benchmark.percentile([], .95), 0)
        self.assertEqual(benchmark.percentile([5], .95), 5)
        self.assertEqual(benchmark.percentile([1, 3, 2], .95), 2.9)

    def test_live_gate_does_not_read_credentials(self):
        with patch.object(sys, 'argv', ['benchmark', '--year', '2026', '--output', 'unused.json']), patch('getpass.getpass') as read, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                benchmark.main()
        self.assertEqual(raised.exception.code, 2)
        read.assert_not_called()

    def test_library_progress_never_reaches_console_or_report(self):
        async def run(credentials, **_):
            print('PRIVATE LIBRARY PAYLOAD')
            credentials.clear()
            return {'passed': True, 'authenticated': True, 'operations': []}

        with tempfile.TemporaryDirectory(prefix='academic-benchmark-test-') as directory:
            output = Path(directory) / 'report.json'
            stdout = io.StringIO()
            with patch.object(sys, 'argv', ['benchmark', '--live', '--credentials-stdin', '--year', '2026', '--output', str(output)]), patch.object(sys, 'stdin', io.StringIO('{"student_id":"2099000001","password":"fixture-only"}')), patch.object(benchmark, 'benchmark', run), contextlib.redirect_stdout(stdout):
                self.assertEqual(benchmark.main(), 0)
            report = output.read_text(encoding='utf8')
            for private in ('PRIVATE LIBRARY PAYLOAD', '2099000001', 'fixture-only'):
                self.assertNotIn(private, stdout.getvalue() + report)
            self.assertTrue(json.loads(report)['passed'])


if __name__ == '__main__':
    unittest.main()
