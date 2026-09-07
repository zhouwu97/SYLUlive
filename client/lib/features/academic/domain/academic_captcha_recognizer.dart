import 'dart:typed_data';

/// 本机验证码识别的候选结果。候选只允许作为人工输入建议，不能绕过学校
/// 验证或自动提交；整串低于安全阈值时由 UI 保留人工输入。
final class AcademicCaptchaRecognition {
  const AcademicCaptchaRecognition({
    required this.text,
    required this.confidence,
  });

  static const empty = AcademicCaptchaRecognition(text: '', confidence: 0);

  final String text;
  final double confidence;

  bool get hasFourDigitText => RegExp(r'^\d{4}$').hasMatch(text);

  /// 仅作为本机候选填入，必须由用户核对后提交；阈值来自离线覆盖率审计，
  /// 不代表验证码已被校准为可自动提交。
  bool get isManualSuggestion =>
      hasFourDigitText && confidence.isFinite && confidence >= 0.70;
}

/// 验证码图片只交给设备本地实现，禁止实现通过网络上传图片识别。
///
/// 识别器必须显式声明 [isAvailable]；低置信度仍回到人工输入。
abstract interface class AcademicCaptchaRecognizer {
  bool get isAvailable;

  Future<AcademicCaptchaRecognition> recognize(Uint8List imageBytes);

  void close();
}

/// 模型不可用或未加载时的安全回退，保持现有人工验证码流程。
final class ManualAcademicCaptchaRecognizer
    implements AcademicCaptchaRecognizer {
  const ManualAcademicCaptchaRecognizer();

  @override
  bool get isAvailable => false;

  @override
  Future<AcademicCaptchaRecognition> recognize(Uint8List imageBytes) async =>
      AcademicCaptchaRecognition.empty;

  @override
  void close() {}
}
