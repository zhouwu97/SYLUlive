import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';

/// 加载测试 fixture HTML
String _loadFixture(String name) {
  final file = File('test/features/campus_data/erke/$name');
  return file.readAsStringSync();
}

void main() {
  // ====================================================================
  //  毕业要求正常解析
  // ====================================================================
  group('parseGraduationSummary', () {
    test('正常解析毕业要求页面', () {
      final html = _loadFixture('fixture_graduation.html');
      final result = ErkeParser.parseGraduationSummary(html);

      // 总分
      expect(result.requiredTotal, 40.0);
      expect(result.earnedTotal, 38.7);
      expect(result.totalGap, closeTo(1.3, 0.01)); // 浮点: 38.7 < 40.0 → 1.3
      expect(result.unmetCount, 2);
      expect(result.percentage, closeTo(96.75, 0.1));

      // 官方结论原样
      expect(result.officialConclusion, 'B得分不足、总分不足');

      // 分类
      expect(result.categories.length, 5);
      expect(result.categories[0].code, 'A');
      expect(result.categories[0].name, '思想成长');
      expect(result.categories[0].required, 10.0);
      expect(result.categories[0].earned, 13.0);
      expect(result.categories[0].meetsNumerically, true);
      expect(result.categories[0].gap, 0);

      expect(result.categories[1].code, 'B');
      expect(result.categories[1].name, '实践实习');
      expect(result.categories[1].earned, 0.0);
      expect(result.categories[1].meetsNumerically, false);
      expect(result.categories[1].gap, 10.0);

      expect(result.categories[2].code, 'C');
      expect(result.categories[2].earned, 5.5);
      expect(result.categories[2].meetsNumerically, true);

      expect(result.categories[4].code, 'E');
      expect(result.categories[4].earned, 4.2);
      expect(result.categories[4].meetsNumerically, false);
      expect(result.categories[4].gap, closeTo(0.8, 0.01));
    });

    test('toJson/fromJson 往返一致', () {
      final html = _loadFixture('fixture_graduation.html');
      final original = ErkeParser.parseGraduationSummary(html);
      final json = original.toJson();
      final restored = ErkeGraduationSummary.fromJson(json);

      expect(restored.requiredTotal, original.requiredTotal);
      expect(restored.earnedTotal, original.earnedTotal);
      expect(restored.totalGap, original.totalGap);
      expect(restored.unmetCount, original.unmetCount);
      expect(restored.officialConclusion, original.officialConclusion);
      expect(restored.categories.length, original.categories.length);
      for (int i = 0; i < original.categories.length; i++) {
        expect(restored.categories[i].code, original.categories[i].code);
        expect(restored.categories[i].earned, original.categories[i].earned);
      }
    });
  });

  // ====================================================================
  //  学年要求正常解析
  // ====================================================================
  group('parseYearlySummary', () {
    test('正常解析学年要求页面', () {
      final html = _loadFixture('fixture_yearly.html');
      final result = ErkeParser.parseYearlySummary(html);

      // 学年信息
      expect(result.year, '2025-2026');
      expect(result.availableYears, ['2025-2026', '2024-2025', '2023-2024']);

      // 学年要求分 (不同! A=8, B=7, C=2, D=6, E=2 vs 毕业的 10/10/5/10/5)
      expect(result.requiredTotal, 25.0);
      expect(result.yearEarnedTotal, 8.95);
      expect(result.cumulativeTotal, 38.7);
      expect(result.yearGap, closeTo(16.05, 0.01));
      expect(result.percentage, closeTo(35.8, 0.1));

      expect(result.officialConclusion, 'B得分不足');

      // 分类
      expect(result.categories.length, 5);

      // A: 学年0.0, 要求8.0, 累计13.0
      expect(result.categories[0].code, 'A');
      expect(result.categories[0].required, 8.0);
      expect(result.categories[0].yearEarned, 0.0);
      expect(result.categories[0].cumulative, 13.0);
      expect(result.categories[0].meetsNumerically, false);
      expect(result.categories[0].gap, 8.0);

      // C: 学年4.0, 要求2.0, 累计5.5 → meets
      expect(result.categories[2].code, 'C');
      expect(result.categories[2].required, 2.0);
      expect(result.categories[2].yearEarned, 4.0);
      expect(result.categories[2].cumulative, 5.5);
      expect(result.categories[2].meetsNumerically, true);
    });

    test('学年页 hidden inputs 提取', () {
      final html = _loadFixture('fixture_yearly.html');
      final inputs = ErkeParser.extractYearlyHiddenInputs(html);

      expect(inputs['__VIEWSTATE'], isNotEmpty);
      expect(inputs['__VIEWSTATEGENERATOR'], '1C63C549');
      expect(inputs['__EVENTVALIDATION'], isNotEmpty);
      expect(inputs['__EVENTTARGET'], '');
    });

    test('toJson/fromJson 往返一致', () {
      final html = _loadFixture('fixture_yearly.html');
      final original = ErkeParser.parseYearlySummary(html);
      final json = original.toJson();
      final restored = ErkeYearlySummary.fromJson(json);

      expect(restored.year, original.year);
      expect(restored.availableYears, original.availableYears);
      expect(restored.requiredTotal, original.requiredTotal);
      expect(restored.yearEarnedTotal, original.yearEarnedTotal);
      expect(restored.cumulativeTotal, original.cumulativeTotal);
      expect(restored.officialConclusion, original.officialConclusion);
      for (int i = 0; i < original.categories.length; i++) {
        expect(restored.categories[i].yearEarned,
            original.categories[i].yearEarned);
        expect(restored.categories[i].cumulative,
            original.categories[i].cumulative);
      }
    });
  });

  // ====================================================================
  //  异常 case
  // ====================================================================
  group('Error cases', () {
    test('缺失必需 span → ErkePageChangedException', () {
      final html = _loadFixture('fixture_missing_span.html');
      expect(
        () => ErkeParser.parseGraduationSummary(html),
        throwsA(isA<ErkePageChangedException>()
            .having((e) => e.missingElementId, 'missingElementId', 'CountA1')),
      );
    });

    test('非数字 span 值 → ErkePageChangedException', () {
      final html = _loadFixture('fixture_bad_number.html');
      expect(
        () => ErkeParser.parseGraduationSummary(html),
        throwsA(isA<ErkePageChangedException>()),
      );
    });

    test('非总分页面 (如 VPN 登录页) → 抛异常', () {
      const vpnHtml =
          '<!DOCTYPE html><html><head><title>沈阳理工大学资源访问控制系统</title></head>'
          '<body><form id="form"><input name="_csrf"/></form></body></html>';
      expect(
        () => ErkeParser.parseGraduationSummary(vpnHtml),
        throwsA(isA<ErkePageChangedException>()),
      );
    });

    test('GB18030 中文不破坏解析', () {
      // 学年 fixture 包含 GBK 编码的 __VIEWSTATE 值
      final html = _loadFixture('fixture_yearly.html');
      // 不应抛出异常
      final result = ErkeParser.parseYearlySummary(html);
      expect(result.year, '2025-2026');
    });
  });

  // ====================================================================
  //  旧缓存兼容
  // ====================================================================
  group('Legacy cache migration', () {
    test('fromLegacyCache 正确迁移旧 scores/summary', () {
      final snapshot = ErkeSnapshot.fromLegacyCache(
        scores: [
          {'item': '测试活动', 'score': '1.00', 'date': '2025-01-01', 'category': '思想成长'},
        ],
        summary: [
          {'category': '思想成长', 'score': '13.0', 'required': '10.0'},
        ],
      );

      expect(snapshot.hasActivities, true);
      expect(snapshot.activities.length, 1);
      expect(snapshot.activities[0].item, '测试活动');
      expect(snapshot.activities[0].category, '思想成长');

      // 旧缓存没有 graduation/yearly
      expect(snapshot.hasGraduationData, false);
      expect(snapshot.hasYearlyData, false);
    });

    test('fromLegacyCache 空缓存不崩溃', () {
      final snapshot = ErkeSnapshot.fromLegacyCache(scores: null, summary: null);
      expect(snapshot.activities, isEmpty);
      expect(snapshot.hasGraduationData, false);
    });

    test('ErkeSnapshot toJson/fromJson 往返', () {
      final original = ErkeSnapshot(
        graduation: null,
        yearly: null,
        activities: [
          ErkeActivity(item: '测试', score: '1.0', date: '2025-01-01', category: '思想成长'),
        ],
        fetchedAt: DateTime(2025, 6, 23),
      );

      final json = original.toJson();
      final restored = ErkeSnapshot.fromJson(json);

      expect(restored.activities.length, 1);
      expect(restored.activities[0].item, '测试');
      expect(restored.fetchedAt, DateTime(2025, 6, 23));
    });
  });
}
