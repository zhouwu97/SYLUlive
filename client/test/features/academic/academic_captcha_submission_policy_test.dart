import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_submission_policy.dart';

void main() {
  test('无校准证据不自动提交，包括看似满置信度的结果', () {
    expect(const AcademicCaptchaSubmissionPolicy().allows('1234', 1, 0), false);
    expect(AcademicCaptchaSubmissionPolicy.fromBuildCalibration().calibrated,
        false);
  });
  test('完整四位、置信度范围和提交次数均须满足', () {
    const policy = AcademicCaptchaSubmissionPolicy(
        calibrated: true, backgroundSubmitThreshold: .99);
    expect(policy.allows('1234', .99, 0), true);
    expect(policy.allows('1234', .98, 0), false);
    expect(policy.allows('123', 1, 0), false);
    expect(policy.allows('12345', 1, 0), false);
    expect(policy.allows('1234', double.nan, 0), false);
    expect(policy.allows('1234', 1.01, 0), false);
    expect(policy.allows('1234', 1, 1), false);
    expect(
        const AcademicCaptchaSubmissionPolicy(
                calibrated: true, backgroundSubmitThreshold: .5)
            .allows('1234', 1, 0),
        false);
  });
  test('校准绑定当前模型，替换模型必须重新校准', () {
    final bytes =
        File('assets/models/graduate_captcha_digit.tflite').readAsBytesSync();
    expect(sha256.convert(bytes).toString(),
        AcademicCaptchaSubmissionPolicy.bundledModelSha256);
  });
}
