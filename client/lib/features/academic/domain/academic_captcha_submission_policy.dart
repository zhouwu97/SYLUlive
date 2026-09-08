import 'dart:convert';

/// 自动提交使用完整四位验证码的校准结果，不能把单字符 softmax 当成成功概率。
final class AcademicCaptchaSubmissionPolicy {
  const AcademicCaptchaSubmissionPolicy({
    this.suggestionThreshold = .70,
    this.autoFillThreshold = .70,
    this.backgroundSubmitThreshold = 1,
    this.calibrated = false,
    this.maxBackgroundAttempts = 1,
  });

  final double suggestionThreshold;
  final double autoFillThreshold;
  final double backgroundSubmitThreshold;
  final bool calibrated;
  final int maxBackgroundAttempts;
  static const bundledModelSha256 =
      '0eb1505ee8d9058e83f6afb692449ff7601dc4626dbf5a5c6eebfbff2e154c84';

  factory AcademicCaptchaSubmissionPolicy.fromBuildCalibration() {
    const raw = String.fromEnvironment('GRADUATE_CAPTCHA_CALIBRATION');
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['model_sha256'] != bundledModelSha256 ||
          data['schema_version'] != 1 ||
          data['eligible'] != true ||
          (data['evaluation_submitted'] as num) < 1000 ||
          (data['false_submit_upper_95'] as num) > .001) {
        return const AcademicCaptchaSubmissionPolicy();
      }
      return AcademicCaptchaSubmissionPolicy(
          calibrated: true,
          backgroundSubmitThreshold: (data['threshold'] as num).toDouble());
    } catch (_) {
      return const AcademicCaptchaSubmissionPolicy();
    }
  }

  bool allows(String? code, double? confidence, int attempts) =>
      calibrated &&
      maxBackgroundAttempts > 0 &&
      maxBackgroundAttempts <= 2 &&
      attempts >= 0 &&
      attempts < maxBackgroundAttempts &&
      suggestionThreshold.isFinite &&
      suggestionThreshold >= 0 &&
      autoFillThreshold >= suggestionThreshold &&
      backgroundSubmitThreshold.isFinite &&
      backgroundSubmitThreshold >= autoFillThreshold &&
      backgroundSubmitThreshold <= 1 &&
      confidence != null &&
      confidence.isFinite &&
      confidence <= 1 &&
      confidence >= backgroundSubmitThreshold &&
      code != null &&
      RegExp(r'^\d{4}$').hasMatch(code);
}
