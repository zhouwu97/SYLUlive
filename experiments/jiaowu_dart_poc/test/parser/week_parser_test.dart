import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('周次解析保留原文并支持离散周', () {
    final parsed = WeekParser.parse('1-8周,10-12周');

    expect(parsed.raw, '1-8周,10-12周');
    expect(parsed.weeks, {1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12});
  });

  test('解析连续周', () {
    final parsed = WeekParser.parse('1-16周');

    expect(parsed.weeks.length, 16);
    expect(parsed.weeks.first, 1);
    expect(parsed.weeks.last, 16);
  });

  test('解析单周和双周', () {
    expect(WeekParser.parse('1-16周(单)').weeks, {1, 3, 5, 7, 9, 11, 13, 15});
    expect(WeekParser.parse('1-16周(双)').weeks, {2, 4, 6, 8, 10, 12, 14, 16});
  });

  test('解析显式离散周和中文前缀', () {
    expect(WeekParser.parse('1,3,5,7周').weeks, {1, 3, 5, 7});
    expect(WeekParser.parse('第1-4周,7周,9-13周').weeks,
        {1, 2, 3, 4, 7, 9, 10, 11, 12, 13});
  });

  test('空周次得到合法空集合', () {
    final parsed = WeekParser.parse('');

    expect(parsed.raw, isEmpty);
    expect(parsed.weeks, isEmpty);
  });
}
