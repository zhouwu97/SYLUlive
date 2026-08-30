import 'package:flutter/services.dart';

/// 平台中文词边界能力。
///
/// 平台实现不可用、低于 API 24 或调用失败时返回 null，由
/// [SmartTextSelectionResolver] 使用确定性的 Dart 规则回退。
abstract interface class TextBoundaryResolver {
  Future<TextRange?> resolveWordBoundary({
    required String text,
    required int offset,
  });
}

/// Android ICU 中文词边界的 MethodChannel 实现。
class MethodChannelTextBoundaryResolver implements TextBoundaryResolver {
  static const channelName = 'shenliyuan/text_selection';
  static const MethodChannel _channel = MethodChannel(channelName);

  const MethodChannelTextBoundaryResolver();

  @override
  Future<TextRange?> resolveWordBoundary({
    required String text,
    required int offset,
  }) async {
    if (text.isEmpty || offset < 0 || offset > text.length) return null;
    try {
      final result = await _channel.invokeMethod<Object?>(
        'resolveWordBoundary',
        <String, Object?>{
          'text': text,
          'offset': offset,
        },
      );
      if (result is! Map) return null;
      final start = (result['start'] as num?)?.toInt();
      final end = (result['end'] as num?)?.toInt();
      if (start == null ||
          end == null ||
          start < 0 ||
          start >= end ||
          end > text.length) {
        return null;
      }
      return TextRange(start: start, end: end);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// 正文选择使用的默认平台实现，可在测试中替换为 fake。
abstract final class SmartWordBoundaryPlatform {
  static TextBoundaryResolver resolver =
      const MethodChannelTextBoundaryResolver();

  static Future<TextRange?> resolve({
    required String text,
    required int offset,
  }) {
    return resolver.resolveWordBoundary(text: text, offset: offset);
  }
}
