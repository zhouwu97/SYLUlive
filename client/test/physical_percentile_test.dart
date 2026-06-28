import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/physical/physical_percentile_models.dart';
import 'package:shenliyuan/features/physical/physical_percentile_service.dart';

void main() {
  group('PhysicalMetricCatalog', () {
    test('归一化体测项目名称', () {
      expect(PhysicalMetricCatalog.normalizeMetricId('坐体前屈'), 'sit_reach');
      expect(PhysicalMetricCatalog.normalizeMetricId('坐位体前屈'), 'sit_reach');
      expect(PhysicalMetricCatalog.normalizeMetricId('50米跑'), 'run_50m');
      expect(PhysicalMetricCatalog.normalizeMetricId('1000'), 'run_1000m');
    });
  });

  group('PhysicalResultParser', () {
    test('解析常见跑步时间格式为秒', () {
      expect(
          PhysicalResultParser.parseComparableValue('run_800m', "4'14"), 254);
      expect(
          PhysicalResultParser.parseComparableValue('run_1000m', '4.23'), 263);
      expect(PhysicalResultParser.parseComparableValue('run_50m', '7.8'), 7.8);
    });

    test('解析普通数值并过滤不可比成绩', () {
      expect(
          PhysicalResultParser.parseComparableValue(
              'vital_capacity', '4171 mL'),
          4171);
      expect(PhysicalResultParser.parseComparableValue('standing_jump', '0'),
          isNull);
      expect(PhysicalResultParser.parseComparableValue('pull_up', '0'), 0);
      expect(PhysicalResultParser.parseComparableValue('sit_up', '-1'), isNull);
    });
  });

  group('PhysicalPercentileService', () {
    test('将身高体重合并成绩拆成两个可比项目', () {
      final results = PhysicalPercentileService.normalizeStudentResults(
        const [PhysicalRawScore(name: '身高体重', result: '178cm / 70kg')],
      );

      expect(results.map((result) => result.metricId), ['height', 'weight']);
      expect(results[0].value, 178);
      expect(results[1].value, 70);
    });
  });

  group('PhysicalPercentileService', () {
    final dataset = PhysicalPercentileDataset.fromJson({
      'version': 1,
      'generated_at': '2026-06-27T00:00:00',
      'metrics': {
        'standing_jump': {
          'label': '立定跳远',
          'unit': 'cm',
          'higher_is_better': true,
          'category': 'sport',
        },
        'run_1000m': {
          'label': '1000 米',
          'unit': '秒',
          'higher_is_better': false,
          'category': 'sport',
        },
      },
      'groups': {
        'male': {
          'standing_jump': [200, 220, 220, 260],
          'run_1000m': [230, 260, 260, 300],
        },
        'female': {
          'standing_jump': [150, 170, 190],
        },
        'all': {
          'standing_jump': [150, 170, 190, 200, 220, 220, 260],
          'run_1000m': [230, 260, 260, 300],
        },
      },
    });

    test('高值更好项目按低于人数加同分折半计算', () {
      final service = PhysicalPercentileService(dataset);
      final result = service.compare(
        metricId: 'standing_jump',
        value: 220,
        group: PhysicalCompareGroup.male,
      );

      expect(result.isComparable, true);
      expect(result.percentile, 50);
      expect(result.sampleSize, 4);
    });

    test('跑步项目按用时更长人数加同分折半计算', () {
      final service = PhysicalPercentileService(dataset);
      final result = service.compare(
        metricId: 'run_1000m',
        value: 260,
        group: PhysicalCompareGroup.male,
      );

      expect(result.isComparable, true);
      expect(result.percentile, 50);
      expect(result.sampleSize, 4);
    });

    test('缺少样本时返回不可比状态', () {
      final service = PhysicalPercentileService(dataset);
      final result = service.compare(
        metricId: 'run_1000m',
        value: 260,
        group: PhysicalCompareGroup.female,
      );

      expect(result.isComparable, false);
      expect(result.sampleSize, 0);
    });
  });
}
