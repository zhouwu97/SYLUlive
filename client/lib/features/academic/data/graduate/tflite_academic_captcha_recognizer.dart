import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../domain/academic_captcha_recognizer.dart';

/// 使用研究生 POC 已验证的四个固定窗口数字模型。
///
/// 模型只在本机运行，图片不会离开进程；模型未加载或图片尺寸变化时由
/// 上层丢弃候选并继续人工输入。该模型没有经过整串验证码校准，禁止自动提交。
final class TfliteAcademicCaptchaRecognizer
    implements AcademicCaptchaRecognizer {
  static const modelAssetPath = 'assets/models/graduate_captcha_digit.tflite';
  static const _digitCenters = [17, 42, 67, 92];
  static const _cropWidth = 32;
  static const _imageWidth = 102;
  static const _imageHeight = 46;

  TfliteAcademicCaptchaRecognizer._(this._interpreter);

  final Interpreter _interpreter;

  static Future<TfliteAcademicCaptchaRecognizer> load({
    String modelAssetPath = TfliteAcademicCaptchaRecognizer.modelAssetPath,
  }) async {
    final interpreter = await Interpreter.fromAsset(modelAssetPath);
    interpreter.allocateTensors();
    return TfliteAcademicCaptchaRecognizer._(interpreter);
  }

  @override
  bool get isAvailable => true;

  @override
  Future<AcademicCaptchaRecognition> recognize(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null ||
        decoded.width != _imageWidth ||
        decoded.height != _imageHeight) {
      return AcademicCaptchaRecognition.empty;
    }

    final text = StringBuffer();
    final confidences = <double>[];
    for (final center in _digitCenters) {
      final output = [List<double>.filled(10, 0.0)];
      _interpreter.run(_buildInput(decoded, center), output);
      final probabilities = output.first;
      var digit = 0;
      var confidence = probabilities.first;
      for (var index = 1; index < probabilities.length; index++) {
        if (probabilities[index] > confidence) {
          digit = index;
          confidence = probabilities[index];
        }
      }
      text.write(digit);
      confidences.add(confidence);
    }

    // 即使模型给出四位数字，也不会自动提交；调用方继续要求人工核对。
    final confidence =
        confidences.reduce((left, right) => left < right ? left : right);
    return AcademicCaptchaRecognition(
      text: text.toString(),
      confidence: confidence,
    );
  }

  @override
  void close() => _interpreter.close();

  List<List<List<List<double>>>> _buildInput(img.Image image, int center) {
    final left = center - (_cropWidth ~/ 2);
    return [
      List.generate(
        _imageHeight,
        (y) => List.generate(_cropWidth, (offset) {
          final x = left + offset;
          if (x < 0 || x >= image.width) return [1.0];
          final pixel = image.getPixel(x, y);
          final gray =
              (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b) / 255.0;
          return [gray.toDouble()];
        }),
      ),
    ];
  }
}

/// 默认懒加载包装器，模型缺失或平台不支持时自动交给人工输入。
final class LazyTfliteAcademicCaptchaRecognizer
    implements AcademicCaptchaRecognizer {
  LazyTfliteAcademicCaptchaRecognizer({
    Future<TfliteAcademicCaptchaRecognizer> Function()? loader,
  }) : _loader = loader ?? TfliteAcademicCaptchaRecognizer.load;

  final Future<TfliteAcademicCaptchaRecognizer> Function() _loader;
  Future<TfliteAcademicCaptchaRecognizer>? _loading;
  TfliteAcademicCaptchaRecognizer? _delegate;
  bool _closed = false;

  @override
  bool get isAvailable => !_closed;

  @override
  Future<AcademicCaptchaRecognition> recognize(Uint8List imageBytes) async {
    if (_closed) return AcademicCaptchaRecognition.empty;
    try {
      final delegate = _delegate ??= await (_loading ??= _loader());
      return await delegate.recognize(imageBytes);
    } catch (_) {
      // 模型加载、解释器或图片解码异常不能阻断登录，调用方保留人工输入。
      return AcademicCaptchaRecognition.empty;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _delegate?.close();
  }
}
