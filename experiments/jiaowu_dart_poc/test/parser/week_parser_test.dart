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

  test('单双周只作用于所在的周次片段', () {
    expect(WeekParser.parse('1-8周(单),10-12周').weeks, {1, 3, 5, 7, 10, 11, 12});
    expect(
        WeekParser.parse('1-8周(双),9-12周').weeks, {2, 4, 6, 8, 9, 10, 11, 12});
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

  test('反向验证 2026/3 线上课表中的周次表达式', () {
    expect(WeekParser.parse('1-6周,8-13周').weeks,
        {1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13});
    expect(WeekParser.parse('8-17周').weeks,
        {8, 9, 10, 11, 12, 13, 14, 15, 16, 17});
    expect(WeekParser.parse('1-5周,7-13周').weeks,
        {1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13});
  });
}
