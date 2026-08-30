import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/smart_text_selection.dart';

SmartSelectionResolution _resolveAt(String text, String value) {
  final offset = text.indexOf(value);
  expect(offset, greaterThanOrEqualTo(0));
  return SmartTextSelectionResolver.resolveSelection(
    text,
    TextSelection(
      baseOffset: offset,
      extentOffset: offset + 1,
    ),
  );
}

void main() {
  test('URL 中间长按扩展到完整 path/query/fragment', () {
    const text = '官网：https://sylulive.online/posts/123?id=456#reply，欢迎访问';
    final result = _resolveAt(text, 'online');

    expect(result.kind, SmartSelectionKind.url);
    expect(result.textInside(text),
        'https://sylulive.online/posts/123?id=456#reply');
  });

  test('URL 末尾中文标点不进入选区', () {
    const text = '打开 https://sylulive.online/，再看说明。';
    final result = _resolveAt(text, 'sylulive');

    expect(result.textInside(text), 'https://sylulive.online/');
    expect(SmartTextSelectionResolver.isUrl(result.textInside(text)), isTrue);
  });

  test('数字、号码、日期、时间、版本、IP 和小数保持完整', () {
    const cases = <String, SmartSelectionKind>{
      '3170305904': SmartSelectionKind.number,
      '210101010123': SmartSelectionKind.number,
      '13812345678': SmartSelectionKind.phone,
      '024-12345678': SmartSelectionKind.phone,
      '2026-08-26': SmartSelectionKind.date,
      '10:46:32': SmartSelectionKind.time,
      '1.5.22': SmartSelectionKind.version,
      '192.168.1.100': SmartSelectionKind.ip,
      '98.75': SmartSelectionKind.numericSequence,
    };

    for (final entry in cases.entries) {
      final result = _resolveAt('编号：${entry.key}。', entry.key);
      expect(result.kind, entry.value, reason: entry.key);
      expect(result.textInside('编号：${entry.key}。'), entry.key);
    }
  });

  test('英文单词、identifier、缩写和带连字符的版本保持完整', () {
    const text = 'Flutter SYLUlive don\'t user_id API_URL gpt-5';
    for (final value in <String>[
      'Flutter',
      'SYLUlive',
      "don't",
      'user_id',
      'API_URL',
      'gpt-5',
    ]) {
      final result = _resolveAt(text, value);
      expect(result.textInside(text), value, reason: value);
    }
  });

  test('连续中文不整体选中，回退至少给出可用词语', () {
    const text = '最近发现很多人老是出现注册的问题';
    final result = _resolveAt(text, '注册');

    expect(result.kind, SmartSelectionKind.cjkWord);
    expect(result.textInside(text), '注册');
    expect(result.textInside(text), isNot(text));
  });

  test('Android ICU 边界优先于 Dart 中文回退', () {
    const text = '这是一个注册问题';
    final offset = text.indexOf('注');
    final result = SmartTextSelectionResolver.resolveSelection(
      text,
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
      cjkWordBoundary: TextRange(start: offset, end: offset + 2),
    );

    expect(result.kind, SmartSelectionKind.cjkWord);
    expect(result.textInside(text), '注册');
  });

  test('不把数字和中文逗号之间的两个数字串联', () {
    const text = '123，今天456';
    final first = _resolveAt(text, '123');
    final second = _resolveAt(text, '456');

    expect(first.textInside(text), '123');
    expect(second.textInside(text), '456');
  });
}
