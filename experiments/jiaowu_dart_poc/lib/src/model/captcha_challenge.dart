import 'dart:typed_data';

/// 一次性验证码图片，仅保存在当前内存会话中。
final class CaptchaChallenge {
  CaptchaChallenge({required Uint8List imageBytes})
      : imageBytes = Uint8List.fromList(imageBytes);

  final Uint8List imageBytes;
}
