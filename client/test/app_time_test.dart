import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_time.dart';

void main() {
  test('converts authoritative timestamp to Shanghai display time', () {
    final utc = DateTime.parse('2026-06-14T06:24:00Z');
    final shanghai = AppTime.toShanghai(utc);

    expect(shanghai.year, 2026);
    expect(shanghai.month, 6);
    expect(shanghai.day, 14);
    expect(shanghai.hour, 14);
    expect(shanghai.minute, 24);
  });
}
