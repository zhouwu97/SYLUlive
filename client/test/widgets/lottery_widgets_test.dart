import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/lottery/lottery_widgets.dart';

void main() {
  test('快捷开奖时间按北京时间跨日和跨年', () {
    final cases = [
      (
        DateTime.utc(2026, 12, 31, 11, 30),
        [
          ('今晚 20:00', '2026-12-31T20:00:00+08:00'),
          ('明天 12:00', '2027-01-01T12:00:00+08:00'),
          ('3 天后', '2027-01-03T12:00:00+08:00'),
        ],
      ),
      (
        DateTime.utc(2026, 12, 31, 11, 30, 1),
        [
          ('明晚 20:00', '2027-01-01T20:00:00+08:00'),
          ('明天 12:00', '2027-01-01T12:00:00+08:00'),
          ('3 天后', '2027-01-03T12:00:00+08:00'),
        ],
      ),
      (
        DateTime.utc(2026, 12, 31, 16),
        [
          ('今晚 20:00', '2027-01-01T20:00:00+08:00'),
          ('明天 12:00', '2027-01-02T12:00:00+08:00'),
          ('3 天后', '2027-01-04T12:00:00+08:00'),
        ],
      ),
    ];
    for (final (instant, expected) in cases) {
      final options = lotteryQuickDrawTimes(instant);
      expect(
        [for (final (label, wall) in options)
          (label, formatLotteryBeijingRfc3339(wall))],
        expected,
        reason: instant.toIso8601String(),
      );
    }
  });

  test('活动说明按连续编号拆分条目', () {
    final cases = <(String, String, List<String>)>[
      (
        '温馨提示\n1.账号充值；\n2.下单后查看；\n 3.可兑换1杯；4.不同享。 5.因特殊性不退换。',
        '温馨提示',
        ['账号充值；', '下单后查看；', '可兑换1杯；', '不同享。', '因特殊性不退换。'],
      ),
      ('1、第一条 2、第二条', '', ['第一条', '第二条']),
      // 只有一条编号或编号不从 1 开始，整段原样保留。
      ('1.只有一条说明', '1.只有一条说明', []),
      ('价格 2.5 元，3.活动', '价格 2.5 元，3.活动', []),
      ('无编号的普通说明', '无编号的普通说明', []),
    ];
    for (final (raw, lead, items) in cases) {
      final parsed = parseLotteryDescription(raw);
      expect(parsed.lead, lead, reason: raw);
      expect(parsed.items, items, reason: raw);
    }
  });
}
