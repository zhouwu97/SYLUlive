import 'dart:typed_data';

/// 本机验证码识别候选。默认供人工核对；后台提交另由完整四位校准策略授权。
final class AcademicCaptchaRecognition {
  const AcademicCaptchaRecognition({
    required this.text,
    required this.confidence,
  });

  static const empty = AcademicCaptchaRecognition(text: '', confidence: 0);

  final String text;
  final double confidence;

  bool get hasFourDigitText => RegExp(r'^\d{4}$').hasMatch(text);

  /// 候选展示阈值不代表可自动提交；后台策略必须有独立的校准证据。
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
