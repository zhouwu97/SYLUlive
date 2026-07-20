import '../../../campus_data/erke/erke_models.dart';

class ErkeCategoryOverview {
  const ErkeCategoryOverview({
    required this.code,
    required this.name,
    required this.required,
    required this.earned,
    required this.meetsNumerically,
  });

  final String code;
  final String name;
  final double required;
  final double earned;
  final bool meetsNumerically;
}

/// 供后续 Skill 使用的二课概览，不包含原始缓存 JSON 或来源账号。
class ErkeOverview {
  const ErkeOverview({
    required this.activityCount,
    required this.categories,
    this.requiredTotal,
    this.earnedTotal,
    this.graduationGap,
    this.unmetCount,
    this.latestActivityDate,
    this.selectedYear,
    this.selectedYearEarned,
  });

  final double? requiredTotal;
  final double? earnedTotal;
  final double? graduationGap;
  final int? unmetCount;
  final int activityCount;
  final String? latestActivityDate;
  final String? selectedYear;
  final double? selectedYearEarned;
  final List<ErkeCategoryOverview> categories;

  factory ErkeOverview.fromPayload(Map<String, dynamic> payload) {
    _validatePayload(payload);
    final snapshot = ErkeSnapshot.fromJson(payload);
    final graduation = snapshot.graduation;
    final yearly = snapshot.yearly;
    final categories = graduation?.categories
            .map(
              (category) => ErkeCategoryOverview(
                code: category.code,
                name: category.name,
                required: category.required,
                earned: category.earned,
                meetsNumerically: category.meetsNumerically,
              ),
            )
            .toList(growable: false) ??
        const <ErkeCategoryOverview>[];
    final latestActivityDate = snapshot.activities
        .map((activity) => activity.date.trim())
        .where((date) => date.isNotEmpty)
        .fold<String?>(null, (latest, date) {
      if (latest == null || date.compareTo(latest) > 0) return date;
      return latest;
    });

    return ErkeOverview(
      requiredTotal: graduation?.requiredTotal,
      earnedTotal: graduation?.earnedTotal,
      graduationGap: graduation?.graduationGap,
      unmetCount: graduation?.unmetCount,
      activityCount: snapshot.activities.length,
      latestActivityDate: latestActivityDate,
      selectedYear: yearly?.year,
      selectedYearEarned: yearly?.yearEarnedTotal,
      categories: categories,
    );
  }

  static void _validatePayload(Map<String, dynamic> payload) {
    if (payload.isEmpty ||
        (payload['graduation'] != null && payload['graduation'] is! Map) ||
        (payload['yearly'] != null && payload['yearly'] is! Map) ||
        (payload['activities'] != null && payload['activities'] is! List)) {
      throw const FormatException('二课保险箱快照格式错误');
    }
  }
}
