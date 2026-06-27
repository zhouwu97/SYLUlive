import 'dart:convert';
import 'package:flutter/services.dart';

import 'physical_percentile_models.dart';

class PhysicalResultParser {
  static double? parseComparableValue(String metricId, Object? rawValue) {
    if (rawValue == null) return null;
    final text = rawValue.toString().trim();
    if (text.isEmpty || text == '--' || text == 'null') return null;

    final value = _isRunMetric(metricId)
        ? _parseRunSeconds(metricId, text)
        : _parseNumber(text);
    if (value == null || value.isNaN || value.isInfinite) return null;
    if (value < 0) return null;
    if (value == 0 &&
        metricId != PhysicalMetricCatalog.pullUp &&
        metricId != PhysicalMetricCatalog.sitUp) {
      return null;
    }
    if (!_looksReasonable(metricId, value)) return null;
    return value;
  }

  static bool _isRunMetric(String metricId) {
    return metricId == PhysicalMetricCatalog.run50m ||
        metricId == PhysicalMetricCatalog.run800m ||
        metricId == PhysicalMetricCatalog.run1000m;
  }

  static double? _parseNumber(String text) {
    final normalized = text
        .replaceAll('′', "'")
        .replaceAll('″', '"')
        .replaceAll(RegExp(r'[，,]'), '.');
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(normalized);
    if (match == null) return null;
    return double.tryParse(match.group(0)!);
  }

  static double? _parseRunSeconds(String metricId, String text) {
    final normalized = text
        .trim()
        .replaceAll('′', "'")
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('″', '"')
        .replaceAll('”', '"')
        .replaceAll('“', '"')
        .replaceAll('分', "'")
        .replaceAll('秒', '')
        .replaceAll(RegExp(r'\s+'), '');

    final minuteMatch =
        RegExp(r'''^(\d+)[':](\d+(?:\.\d+)?)"?$''').firstMatch(normalized);
    if (minuteMatch != null) {
      final minutes = int.tryParse(minuteMatch.group(1)!);
      final seconds = double.tryParse(minuteMatch.group(2)!);
      if (minutes == null || seconds == null) return null;
      return minutes * 60 + seconds;
    }

    final numeric = double.tryParse(normalized.replaceAll(',', '.'));
    if (numeric == null) return _parseNumber(normalized);

    // 中长跑历史数据常把 4.23 表示为 4 分 23 秒，50 米则保留十进制秒。
    if (metricId != PhysicalMetricCatalog.run50m &&
        numeric >= 3 &&
        numeric < 20 &&
        normalized.contains('.')) {
      final parts = normalized.split('.');
      if (parts.length == 2 && parts[1].length <= 2) {
        final minutes = int.tryParse(parts[0]);
        final seconds = int.tryParse(parts[1].padRight(2, '0'));
        if (minutes != null && seconds != null && seconds < 60) {
          return minutes * 60 + seconds.toDouble();
        }
      }
    }

    return numeric;
  }

  static bool _looksReasonable(String metricId, double value) {
    switch (metricId) {
      case PhysicalMetricCatalog.height:
        return value >= 120 && value <= 230;
      case PhysicalMetricCatalog.weight:
        return value >= 30 && value <= 180;
      case PhysicalMetricCatalog.vitalCapacity:
        return value >= 500 && value <= 9999;
      case PhysicalMetricCatalog.run50m:
        return value >= 5 && value <= 20;
      case PhysicalMetricCatalog.sitReach:
        return value >= -30 && value <= 50;
      case PhysicalMetricCatalog.standingJump:
        return value >= 50 && value <= 400;
      case PhysicalMetricCatalog.pullUp:
        return value >= 0 && value <= 80;
      case PhysicalMetricCatalog.run1000m:
        return value >= 120 && value <= 600;
      case PhysicalMetricCatalog.sitUp:
        return value >= 0 && value <= 120;
      case PhysicalMetricCatalog.run800m:
        return value >= 100 && value <= 500;
      default:
        return true;
    }
  }
}

class PhysicalPercentileService {
  final PhysicalPercentileDataset dataset;

  const PhysicalPercentileService(this.dataset);

  static Future<PhysicalPercentileService> loadFromAsset({
    String assetPath = 'assets/data/physical_percentiles.json',
  }) async {
    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return PhysicalPercentileService(PhysicalPercentileDataset.fromJson(json));
  }

  PhysicalPercentileResult compare({
    required String metricId,
    required double value,
    required PhysicalCompareGroup group,
    PhysicalGender gender = PhysicalGender.unknown,
  }) {
    final groupKey = resolveGroupKey(group, gender);
    if (groupKey == null) {
      return PhysicalPercentileResult.unavailable(
        metricId: metricId,
        group: group,
      );
    }

    final values = dataset.valuesFor(groupKey, metricId);
    if (values.isEmpty) {
      return PhysicalPercentileResult.unavailable(
        metricId: metricId,
        group: group,
      );
    }

    final metric = PhysicalMetricCatalog.infoFor(metricId, dataset: dataset);
    final rawPercent = metric.higherIsBetter
        ? _percentHigherIsBetter(values, value)
        : _percentLowerIsBetter(values, value);
    return PhysicalPercentileResult(
      metricId: metricId,
      group: group,
      isComparable: true,
      percentile: rawPercent.round().clamp(0, 100),
      sampleSize: values.length,
    );
  }

  PhysicalReportSnapshot buildSnapshot({
    required List<PhysicalStudentMetricResult> studentResults,
    required PhysicalCompareGroup group,
    required PhysicalGender gender,
  }) {
    final metrics = <PhysicalReportMetric>[];
    for (final result in studentResults) {
      final info =
          PhysicalMetricCatalog.infoFor(result.metricId, dataset: dataset);
      metrics.add(
        PhysicalReportMetric(
          studentResult: result,
          metricInfo: info,
          comparison: compare(
            metricId: result.metricId,
            value: result.value,
            group: group,
            gender: gender,
          ),
        ),
      );
    }

    final body = metrics
        .where((metric) => metric.metricInfo.category == 'body')
        .toList(growable: false);
    final sport = metrics
        .where((metric) => metric.metricInfo.category != 'body')
        .toList(growable: false);
    final comparableSport =
        sport.where((metric) => metric.comparison.isComparable).toList();

    final average = comparableSport.isEmpty
        ? 0
        : (comparableSport
                    .map((metric) => metric.comparison.percentile)
                    .reduce((a, b) => a + b) /
                comparableSport.length)
            .round()
            .clamp(0, 100);

    comparableSport.sort(
      (a, b) => b.comparison.percentile.compareTo(a.comparison.percentile),
    );

    return PhysicalReportSnapshot(
      group: group,
      sportAveragePercentile: average,
      bodyMetrics: _sortByCatalogOrder(body),
      sportMetrics: _sortByCatalogOrder(sport),
      highlights: comparableSport.take(3).toList(growable: false),
    );
  }

  static String? resolveGroupKey(
    PhysicalCompareGroup group,
    PhysicalGender gender,
  ) {
    switch (group) {
      case PhysicalCompareGroup.all:
        return 'all';
      case PhysicalCompareGroup.male:
        return 'male';
      case PhysicalCompareGroup.female:
        return 'female';
      case PhysicalCompareGroup.sameGender:
        if (gender == PhysicalGender.male) return 'male';
        if (gender == PhysicalGender.female) return 'female';
        return 'all';
    }
  }

  static String groupLabel(PhysicalCompareGroup group) {
    switch (group) {
      case PhysicalCompareGroup.sameGender:
        return '同性别';
      case PhysicalCompareGroup.all:
        return '全体';
      case PhysicalCompareGroup.male:
        return '男生';
      case PhysicalCompareGroup.female:
        return '女生';
    }
  }

  static PhysicalGender parseGender(Object? rawValue) {
    if (rawValue == null) return PhysicalGender.unknown;
    final text = rawValue.toString().trim().toLowerCase();
    if (text.isEmpty) return PhysicalGender.unknown;
    if (text == '1' ||
        text == '男' ||
        text == '男生' ||
        text == 'm' ||
        text == 'male') {
      return PhysicalGender.male;
    }
    if (text == '2' ||
        text == '女' ||
        text == '女生' ||
        text == 'f' ||
        text == 'female') {
      return PhysicalGender.female;
    }
    return PhysicalGender.unknown;
  }

  static PhysicalGender inferGenderFromMetricIds(Iterable<String> metricIds) {
    final ids = metricIds.toSet();
    if (ids.contains(PhysicalMetricCatalog.run1000m) ||
        ids.contains(PhysicalMetricCatalog.pullUp)) {
      return PhysicalGender.male;
    }
    if (ids.contains(PhysicalMetricCatalog.run800m) ||
        ids.contains(PhysicalMetricCatalog.sitUp)) {
      return PhysicalGender.female;
    }
    return PhysicalGender.unknown;
  }

  static List<PhysicalStudentMetricResult> normalizeStudentResults(
    Iterable<PhysicalRawScore> scores,
  ) {
    final byMetric = <String, PhysicalStudentMetricResult>{};
    for (final score in scores) {
      final combinedBodyResults = _parseCombinedHeightWeight(score);
      if (combinedBodyResults.isNotEmpty) {
        for (final result in combinedBodyResults) {
          byMetric[result.metricId] = result;
        }
        continue;
      }

      final metricId = PhysicalMetricCatalog.normalizeMetricId(score.name);
      if (metricId == null) continue;
      final value =
          PhysicalResultParser.parseComparableValue(metricId, score.result);
      if (value == null) continue;
      final info = PhysicalMetricCatalog.infoFor(metricId);
      byMetric[metricId] = PhysicalStudentMetricResult(
        metricId: metricId,
        label: info.label,
        rawResult: score.result,
        value: value,
      );
    }
    final values = byMetric.values.toList(growable: false);
    return _sortStudentResults(values);
  }

  static List<PhysicalStudentMetricResult> _parseCombinedHeightWeight(
    PhysicalRawScore score,
  ) {
    final compactName = score.name.replaceAll(RegExp(r'\s+'), '');
    if (!compactName.contains('身高') || !compactName.contains('体重')) {
      return const [];
    }

    final raw = score.result;
    double? height = _valueBeforeUnit(raw, RegExp(r'cm|厘米|公分'));
    double? weight = _valueBeforeUnit(raw, RegExp(r'kg|千克|公斤'));

    if (height == null || weight == null) {
      final numbers = RegExp(r'-?\d+(?:\.\d+)?')
          .allMatches(raw.replaceAll('，', '.').replaceAll(',', '.'))
          .map((match) => double.tryParse(match.group(0)!))
          .whereType<double>()
          .toList(growable: false);
      for (final number in numbers) {
        if (height == null &&
            PhysicalResultParser.parseComparableValue(
                  PhysicalMetricCatalog.height,
                  number,
                ) !=
                null) {
          height = number;
          continue;
        }
        if (weight == null &&
            PhysicalResultParser.parseComparableValue(
                  PhysicalMetricCatalog.weight,
                  number,
                ) !=
                null) {
          weight = number;
        }
      }
    }

    final results = <PhysicalStudentMetricResult>[];
    final parsedHeight = PhysicalResultParser.parseComparableValue(
      PhysicalMetricCatalog.height,
      height,
    );
    if (parsedHeight != null) {
      final info = PhysicalMetricCatalog.infoFor(PhysicalMetricCatalog.height);
      results.add(
        PhysicalStudentMetricResult(
          metricId: PhysicalMetricCatalog.height,
          label: info.label,
          rawResult: _formatNumber(parsedHeight),
          value: parsedHeight,
        ),
      );
    }
    final parsedWeight = PhysicalResultParser.parseComparableValue(
      PhysicalMetricCatalog.weight,
      weight,
    );
    if (parsedWeight != null) {
      final info = PhysicalMetricCatalog.infoFor(PhysicalMetricCatalog.weight);
      results.add(
        PhysicalStudentMetricResult(
          metricId: PhysicalMetricCatalog.weight,
          label: info.label,
          rawResult: _formatNumber(parsedWeight),
          value: parsedWeight,
        ),
      );
    }
    return results;
  }

  static double? _valueBeforeUnit(String raw, RegExp unitPattern) {
    final pattern = RegExp(
      r'(-?\d+(?:[.,]\d+)?)\s*(' + unitPattern.pattern + r')',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    if (match == null) return null;
    return double.tryParse(match.group(1)!.replaceAll(',', '.'));
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(1);
  }

  static double _percentHigherIsBetter(
      List<double> sortedValues, double value) {
    final lower = _lowerBound(sortedValues, value);
    final upper = _upperBound(sortedValues, value);
    return (lower + (upper - lower) / 2) * 100 / sortedValues.length;
  }

  static double _percentLowerIsBetter(List<double> sortedValues, double value) {
    final lower = _lowerBound(sortedValues, value);
    final upper = _upperBound(sortedValues, value);
    final greater = sortedValues.length - upper;
    return (greater + (upper - lower) / 2) * 100 / sortedValues.length;
  }

  static int _lowerBound(List<double> values, double target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (values[mid] < target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  static int _upperBound(List<double> values, double target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (values[mid] <= target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  static List<PhysicalReportMetric> _sortByCatalogOrder(
    List<PhysicalReportMetric> metrics,
  ) {
    final sorted = [...metrics];
    sorted.sort(
      (a, b) => PhysicalMetricCatalog.displayOrder
          .indexOf(a.studentResult.metricId)
          .compareTo(
            PhysicalMetricCatalog.displayOrder
                .indexOf(b.studentResult.metricId),
          ),
    );
    return sorted;
  }

  static List<PhysicalStudentMetricResult> _sortStudentResults(
    List<PhysicalStudentMetricResult> results,
  ) {
    final sorted = [...results];
    sorted.sort(
      (a, b) => PhysicalMetricCatalog.displayOrder
          .indexOf(a.metricId)
          .compareTo(PhysicalMetricCatalog.displayOrder.indexOf(b.metricId)),
    );
    return sorted;
  }
}

class PhysicalRawScore {
  final String name;
  final String result;

  const PhysicalRawScore({
    required this.name,
    required this.result,
  });
}
