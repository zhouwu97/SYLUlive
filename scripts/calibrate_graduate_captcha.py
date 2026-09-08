"""用分离的校准集和验收集评估四位 exact-match；输出只含汇总，不含图片与验证码。"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def upper95(errors, count):
    if not count:
        return 1.0
    z = 1.959963984540054
    p = errors / count
    return (p + z*z/(2*count) + z*math.sqrt(p*(1-p)/count + z*z/(4*count*count))) / (1+z*z/count)


def metrics(rows, threshold):
    chosen = [r for r in rows if r['confidence'] >= threshold]
    errors = sum(r['prediction'] != r['truth'] for r in chosen)
    return {'count': len(rows), 'submitted': len(chosen), 'errors': errors,
            'full_code_exact_accuracy': sum(r['prediction'] == r['truth'] for r in rows)/len(rows),
            'coverage': len(chosen)/len(rows), 'manual_fallback_rate': 1-len(chosen)/len(rows),
            'false_submit_rate': errors/len(chosen) if chosen else 0,
            'false_submit_upper_95': upper95(errors, len(chosen))}


def calibrate(rows, model_sha256):
    groups = {'calibration': [], 'evaluation': []}
    ids = set()
    for row in rows:
        if row.get('split') not in groups or not row.get('sample_id') or row['sample_id'] in ids:
            raise ValueError('样本必须有唯一 sample_id，并明确划分 calibration/evaluation')
        ids.add(row['sample_id'])
        if any(not re.fullmatch(r'[0-9]{4}', str(row.get(k, ''))) for k in ('prediction', 'truth')):
            raise ValueError('prediction/truth 必须为完整四位数字字符串')
        confidence = row.get('confidence')
        if not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
            raise ValueError('confidence 必须为 0 到 1 的有限数值')
        groups[row['split']].append(row)
    if any(not group for group in groups.values()):
        raise ValueError('校准集和验收集均不能为空')
    candidates = sorted({r['confidence'] for r in groups['calibration'] if r['confidence'] >= .70})
    threshold = next((t for t in candidates if metrics(groups['calibration'], t)['false_submit_upper_95'] <= .001), 1.0)
    calibration = metrics(groups['calibration'], threshold)
    evaluation = metrics(groups['evaluation'], threshold)
    return {'schema_version': 1, 'model_sha256': model_sha256, 'threshold': threshold,
            'eligible': calibration['false_submit_upper_95'] <= .001 and evaluation['false_submit_upper_95'] <= .001 and evaluation['submitted'] >= 1000,
            'evaluation_submitted': evaluation['submitted'],
            'false_submit_upper_95': evaluation['false_submit_upper_95'],
            'calibration': calibration, 'evaluation': evaluation}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=Path, required=True, help='本地 JSONL，每行含 sample_id/split/prediction/truth/confidence')
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='可直接用于 --dart-define-from-file 的构建配置')
    args = parser.parse_args()
    report = calibrate([json.loads(line) for line in args.samples.read_text(encoding='utf-8').splitlines() if line.strip()], hashlib.sha256(args.model.read_bytes()).hexdigest())
    args.output.write_text(json.dumps({'GRADUATE_CAPTCHA_CALIBRATION': json.dumps(report)}, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))
