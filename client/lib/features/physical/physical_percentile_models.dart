enum PhysicalCompareGroup {
  sameGender,
  all,
  male,
  female,
}

enum PhysicalGender {
  male,
  female,
  unknown,
}

class PhysicalMetricInfo {
  final String id;
  final String label;
  final String unit;
  final bool higherIsBetter;
  final String category;

  const PhysicalMetricInfo({
    required this.id,
    required this.label,
    required this.unit,
    required this.higherIsBetter,
    required this.category,
  });

  factory PhysicalMetricInfo.fromJson(String id, Map<String, dynamic> json) {
    return PhysicalMetricInfo(
      id: id,
      label: json['label']?.toString() ?? id,
      unit: json['unit']?.toString() ?? '',
      higherIsBetter: json['higher_is_better'] != false,
      category: json['category']?.toString() ?? 'sport',
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'unit': unit,
        'higher_is_better': higherIsBetter,
        'category': category,
      };
}

class PhysicalMetricCatalog {
  static const String height = 'height';
  static const String weight = 'weight';
  static const String vitalCapacity = 'vital_capacity';
  static const String run50m = 'run_50m';
  static const String sitReach = 'sit_reach';
  static const String standingJump = 'standing_jump';
  static const String pullUp = 'pull_up';
  static const String run1000m = 'run_1000m';
  static const String sitUp = 'sit_up';
  static const String run800m = 'run_800m';

  static const List<String> displayOrder = [
    height,
    weight,
    vitalCapacity,
    run50m,
    sitReach,
    standingJump,
    pullUp,
    run1000m,
    sitUp,
    run800m,
  ];

  static const List<String> bodyMetricIds = [height, weight];

  static const List<String> sportMetricIds = [
    vitalCapacity,
    run50m,
    sitReach,
    standingJump,
    pullUp,
    run1000m,
    sitUp,
    run800m,
  ];

  static final Map<String, PhysicalMetricInfo> defaults = {
    height: const PhysicalMetricInfo(
      id: height,
      label: '身高',
      unit: 'cm',
      higherIsBetter: true,
      category: 'body',
    ),
    weight: const PhysicalMetricInfo(
      id: weight,
      label: '体重',
      unit: 'kg',
      higherIsBetter: true,
      category: 'body',
    ),
    vitalCapacity: const PhysicalMetricInfo(
      id: vitalCapacity,
      label: '肺活量',
      unit: 'mL',
      higherIsBetter: true,
      category: 'sport',
    ),
    run50m: const PhysicalMetricInfo(
      id: run50m,
      label: '50 米跑',
      unit: '秒',
      higherIsBetter: false,
      category: 'sport',
    ),
    sitReach: const PhysicalMetricInfo(
      id: sitReach,
      label: '坐位体前屈',
      unit: 'cm',
      higherIsBetter: true,
      category: 'sport',
    ),
    standingJump: const PhysicalMetricInfo(
      id: standingJump,
      label: '立定跳远',
      unit: 'cm',
      higherIsBetter: true,
      category: 'sport',
    ),
    pullUp: const PhysicalMetricInfo(
      id: pullUp,
      label: '引体向上',
      unit: '次',
      higherIsBetter: true,
      category: 'sport',
    ),
    run1000m: const PhysicalMetricInfo(
      id: run1000m,
      label: '1000 米',
      unit: '秒',
      higherIsBetter: false,
      category: 'sport',
    ),
    sitUp: const PhysicalMetricInfo(
      id: sitUp,
      label: '1 分钟仰卧起坐',
      unit: '次',
      higherIsBetter: true,
      category: 'sport',
    ),
    run800m: const PhysicalMetricInfo(
      id: run800m,
      label: '800 米',
      unit: '秒',
      higherIsBetter: false,
      category: 'sport',
    ),
  };

  static PhysicalMetricInfo infoFor(
    String metricId, {
    PhysicalPercentileDataset? dataset,
  }) {
    return dataset?.metrics[metricId] ??
        defaults[metricId] ??
        PhysicalMetricInfo(
          id: metricId,
          label: metricId,
          unit: '',
          higherIsBetter: true,
          category: 'sport',
        );
  }

  static String? normalizeMetricId(String rawName) {
    final source = rawName.trim();
    if (source.isEmpty) return null;

    final compact = source
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('ｍ', 'm')
        .replaceAll('米', 'm')
        .replaceAll('公尺', 'm');

    if (compact == height || compact.contains('身高')) return height;
    if (compact == weight ||
        compact.contains('体重') ||
        compact.contains('bmi') ||
        compact.contains('体重指数')) {
      return weight;
    }
    if (compact == vitalCapacity || compact.contains('肺活量')) {
      return vitalCapacity;
    }
    if (compact == run50m ||
        compact.contains('50m') ||
        compact.contains('50米') ||
        compact.contains('50')) {
      return run50m;
    }
    if (compact == sitReach ||
        compact.contains('坐体前屈') ||
        compact.contains('坐位体前屈') ||
        compact.contains('体前屈')) {
      return sitReach;
    }
    if (compact == standingJump ||
        compact.contains('立定跳远') ||
        compact.contains('跳远')) {
      return standingJump;
    }
    if (compact == pullUp || compact.contains('引体')) return pullUp;
    if (compact == sitUp ||
        compact.contains('仰卧') ||
        compact.contains('一分钟仰卧') ||
        compact.contains('1分钟仰卧')) {
      return sitUp;
    }
    if (compact == run1000m ||
        compact == '1000' ||
        compact.contains('1000m') ||
        compact.contains('1000米')) {
      return run1000m;
    }
    if (compact == run800m ||
        compact == '800' ||
        compact.contains('800m') ||
        compact.contains('800米')) {
      return run800m;
    }

    return null;
  }
}

class PhysicalStudentMetricResult {
  final String metricId;
  final String label;
  final String rawResult;
  final double value;

  const PhysicalStudentMetricResult({
    required this.metricId,
    required this.label,
    required this.rawResult,
    required this.value,
  });
}

class PhysicalPercentileDataset {
  final int version;
  final String generatedAt;
  final Map<String, PhysicalMetricInfo> metrics;
  final Map<String, Map<String, List<double>>> groups;

  const PhysicalPercentileDataset({
    required this.version,
    required this.generatedAt,
    required this.metrics,
    required this.groups,
  });

  factory PhysicalPercentileDataset.fromJson(Map<String, dynamic> json) {
    final rawMetrics = json['metrics'];
    final metrics = <String, PhysicalMetricInfo>{
      ...PhysicalMetricCatalog.defaults
    };
    if (rawMetrics is Map) {
      rawMetrics.forEach((key, value) {
        if (value is Map) {
          final id = key.toString();
          metrics[id] =
              PhysicalMetricInfo.fromJson(id, Map<String, dynamic>.from(value));
        }
      });
    }

    final groups = <String, Map<String, List<double>>>{};
    final rawGroups = json['groups'];
    if (rawGroups is Map) {
      rawGroups.forEach((groupKey, value) {
        final groupMap = <String, List<double>>{};
        if (value is Map) {
          value.forEach((metricKey, rawValues) {
            if (rawValues is List) {
              groupMap[metricKey.toString()] = rawValues
                  .map((entry) => double.tryParse(entry.toString()))
                  .whereType<double>()
                  .toList(growable: false)
                ..sort();
            }
          });
        }
        groups[groupKey.toString()] = groupMap;
      });
    }

    return PhysicalPercentileDataset(
      version: int.tryParse(json['version']?.toString() ?? '') ?? 1,
      generatedAt: json['generated_at']?.toString() ?? '',
      metrics: metrics,
      groups: groups,
    );
  }

  List<double> valuesFor(String groupKey, String metricId) {
    return groups[groupKey]?[metricId] ?? const <double>[];
  }
}

class PhysicalPercentileResult {
  final String metricId;
  final PhysicalCompareGroup group;
  final bool isComparable;
  final int percentile;
  final int sampleSize;

  const PhysicalPercentileResult({
    required this.metricId,
    required this.group,
    required this.isComparable,
    required this.percentile,
    required this.sampleSize,
  });

  const PhysicalPercentileResult.unavailable({
    required this.metricId,
    required this.group,
    this.percentile = 0,
    this.sampleSize = 0,
  }) : isComparable = false;
}

class PhysicalReportMetric {
  final PhysicalStudentMetricResult studentResult;
  final PhysicalMetricInfo metricInfo;
  final PhysicalPercentileResult comparison;

  const PhysicalReportMetric({
    required this.studentResult,
    required this.metricInfo,
    required this.comparison,
  });
}

class PhysicalReportSnapshot {
  final PhysicalCompareGroup group;
  final int sportAveragePercentile;
  final List<PhysicalReportMetric> bodyMetrics;
  final List<PhysicalReportMetric> sportMetrics;
  final List<PhysicalReportMetric> highlights;

  const PhysicalReportSnapshot({
    required this.group,
    required this.sportAveragePercentile,
    required this.bodyMetrics,
    required this.sportMetrics,
    required this.highlights,
  });
}
