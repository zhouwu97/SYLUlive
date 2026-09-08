import unittest
from calibrate_graduate_captcha import calibrate


class CalibrationTest(unittest.TestCase):
    def rows(self, count=4000):
        return [dict(sample_id=f'{split}-{i}', split=split, truth='1234',
                     prediction='1234', confidence=.99)
                for split in ('calibration', 'evaluation') for i in range(count)]

    def test_small_perfect_sample_cannot_enable_background_submission(self):
        self.assertFalse(calibrate(self.rows(20), 'fixture')['eligible'])

    def test_independent_evaluation_rejects_overfit_threshold(self):
        rows = self.rows()
        rows[-1]['prediction'] = '9999'
        self.assertFalse(calibrate(rows, 'fixture')['eligible'])

    def test_full_code_calibration_and_duplicate_rejection(self):
        rows = self.rows()
        result = calibrate(rows, 'fixture')
        self.assertTrue(result['eligible'])
        self.assertEqual(result['evaluation']['manual_fallback_rate'], 0)
        with self.assertRaises(ValueError):
            calibrate(rows + [rows[0]], 'fixture')


if __name__ == '__main__':
    unittest.main()
