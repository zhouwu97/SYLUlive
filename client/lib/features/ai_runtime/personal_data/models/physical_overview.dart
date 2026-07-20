class PhysicalMetricOverview {
  const PhysicalMetricOverview({
    required this.name,
    required this.result,
    required this.grade,
    required this.score,
  });

  final String name;
  final String result;
  final String grade;
  final double? score;
}

/// 仅保留最近学年的体测概览，不暴露原始保险箱 Payload。
class PhysicalOverview {
  const PhysicalOverview({
    required this.latestYear,
    required this.availableYears,
    required this.totalGrade,
    required this.totalScore,
    required this.metrics,
  });

  final String latestYear;
  final List<String> availableYears;
  final String totalGrade;
  final double? totalScore;
  final List<PhysicalMetricOverview> metrics;

  factory PhysicalOverview.fromPayload(Map<String, dynamic> payload) {
    final rawYears = payload['years'];
    if (rawYears is! Map || rawYears.isEmpty) {
      throw const FormatException('体测保险箱快照格式错误');
    }

    final years = <String, Map<String, dynamic>>{};
    for (final entry in rawYears.entries) {
      final year = entry.key.toString().trim();
      if (year.isEmpty || entry.value is! Map) {
        throw const FormatException('体测年份数据格式错误');
      }
      years[year] = Map<String, dynamic>.from(entry.value as Map);
    }
    final availableYears = years.keys.toList()..sort(_compareYearsDescending);
    final latestYear = availableYears.first;
    final latest = years[latestYear]!;
    final rawScores = latest['scores'];
    if (rawScores != null && rawScores is! List) {
      throw const FormatException('体测项目数据格式错误');
    }

    final metrics = <PhysicalMetricOverview>[];
    for (final rawScore in rawScores ?? const <dynamic>[]) {
      if (rawScore is! Map) {
        throw const FormatException('体测项目格式错误');
      }
      final score = Map<String, dynamic>.from(rawScore);
      metrics.add(
        PhysicalMetricOverview(
          name: _stringValue(score['sub_name']),
          result: _stringValue(score['result']),
          grade: _stringValue(score['grade']),
          score: _doubleValue(score['score']),
        ),
      );
    }

    return PhysicalOverview(
      latestYear: latestYear,
      availableYears: List<String>.unmodifiable(availableYears),
      totalGrade: _stringValue(latest['total_grade']),
      totalScore: _doubleValue(latest['total_score']),
      metrics: List<PhysicalMetricOverview>.unmodifiable(metrics),
    );
  }

  static int _compareYearsDescending(String left, String right) {
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      return rightNumber.compareTo(leftNumber);
    }
    return right.compareTo(left);
  }

  static String _stringValue(Object? value) => value?.toString().trim() ?? '';

  static double? _doubleValue(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
