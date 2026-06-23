// ---- 活动明细 ----

class ErkeActivity {
  final String item;
  final String score;
  final String date;
  final String category;

  const ErkeActivity({
    required this.item,
    required this.score,
    required this.date,
    required this.category,
  });

  factory ErkeActivity.fromJson(Map<String, dynamic> json) => ErkeActivity(
        item: json['item'] as String? ?? '',
        score: json['score'] as String? ?? '0',
        date: json['date'] as String? ?? '',
        category: json['category'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'item': item,
        'score': score,
        'date': date,
        'category': category,
      };

  double get scoreValue => double.tryParse(score) ?? 0;

  /// 从旧缓存 Map 迁移（旧格式可能有不同 key）
  factory ErkeActivity.fromLegacyMap(Map<String, dynamic> map) =>
      ErkeActivity.fromJson(map);
}

// ---- 毕业要求 ----

class ErkeRequirementCategory {
  final String code; // "A"~"E"
  final String name; // "思想成长" 等
  final double required; // 要求分
  final double earned; // 已得分
  final bool meetsNumerically; // earned >= required

  const ErkeRequirementCategory({
    required this.code,
    required this.name,
    required this.required,
    required this.earned,
    required this.meetsNumerically,
  });

  double get gap => (earned < required) ? required - earned : 0;

  factory ErkeRequirementCategory.fromJson(Map<String, dynamic> json) =>
      ErkeRequirementCategory(
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        required: (json['required'] as num?)?.toDouble() ?? 0,
        earned: (json['earned'] as num?)?.toDouble() ?? 0,
        meetsNumerically: json['meetsNumerically'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'required': required,
        'earned': earned,
        'meetsNumerically': meetsNumerically,
      };
}

class ErkeGraduationSummary {
  final double requiredTotal;
  final double earnedTotal;
  final double rawTotalGap; // max(0, requiredTotal - earnedTotal)
  final double categoryGap; // 所有分类 max(0, required - earned) 的总和
  final double graduationGap; // max(rawTotalGap, categoryGap)
  final int unmetCount;
  final String officialConclusion;
  final List<ErkeRequirementCategory> categories;

  const ErkeGraduationSummary({
    required this.requiredTotal,
    required this.earnedTotal,
    required this.rawTotalGap,
    required this.categoryGap,
    required this.graduationGap,
    required this.unmetCount,
    required this.officialConclusion,
    required this.categories,
  });

  /// 实际完成百分比 = (requiredTotal - graduationGap) / requiredTotal
  double get percentage => requiredTotal > 0
      ? ((requiredTotal - graduationGap) / requiredTotal * 100).clamp(0, 100)
      : 0;

  factory ErkeGraduationSummary.fromJson(Map<String, dynamic> json) {
    final cats = (json['categories'] as List<dynamic>?)
            ?.map((e) =>
                ErkeRequirementCategory.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return ErkeGraduationSummary(
      requiredTotal: (json['requiredTotal'] as num?)?.toDouble() ?? 0,
      earnedTotal: (json['earnedTotal'] as num?)?.toDouble() ?? 0,
      rawTotalGap: (json['rawTotalGap'] as num?)?.toDouble() ?? 0,
      categoryGap: (json['categoryGap'] as num?)?.toDouble() ?? 0,
      graduationGap: (json['graduationGap'] as num?)?.toDouble() ?? 0,
      unmetCount: json['unmetCount'] as int? ?? 0,
      officialConclusion: json['officialConclusion'] as String? ?? '',
      categories: cats,
    );
  }

  Map<String, dynamic> toJson() => {
        'requiredTotal': requiredTotal,
        'earnedTotal': earnedTotal,
        'rawTotalGap': rawTotalGap,
        'categoryGap': categoryGap,
        'graduationGap': graduationGap,
        'unmetCount': unmetCount,
        'officialConclusion': officialConclusion,
        'categories': categories.map((c) => c.toJson()).toList(),
      };
}

// ---- 学年要求 ----

class ErkeYearlyCategory {
  final String code;
  final String name;
  final double required; // 本学年要求
  final double yearEarned; // 本学年得分
  final double cumulative; // 累计得分（全部学年）
  final bool meetsNumerically; // yearEarned >= required

  const ErkeYearlyCategory({
    required this.code,
    required this.name,
    required this.required,
    required this.yearEarned,
    required this.cumulative,
    required this.meetsNumerically,
  });

  double get gap => (yearEarned < required) ? required - yearEarned : 0;

  factory ErkeYearlyCategory.fromJson(Map<String, dynamic> json) =>
      ErkeYearlyCategory(
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        required: (json['required'] as num?)?.toDouble() ?? 0,
        yearEarned: (json['yearEarned'] as num?)?.toDouble() ?? 0,
        cumulative: (json['cumulative'] as num?)?.toDouble() ?? 0,
        meetsNumerically: json['meetsNumerically'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'required': required,
        'yearEarned': yearEarned,
        'cumulative': cumulative,
        'meetsNumerically': meetsNumerically,
      };
}

class ErkeYearlySummary {
  final String year;
  final List<String> availableYears;
  final double requiredTotal;
  final double yearEarnedTotal;
  final double cumulativeTotal;
  final double rawYearGap; // max(0, requiredTotal - yearEarnedTotal)
  final double categoryGap; // 各分类 max(0, required - yearEarned) 之和
  final double minimumGap; // max(rawYearGap, categoryGap)
  final String officialConclusion;
  final List<ErkeYearlyCategory> categories;

  const ErkeYearlySummary({
    required this.year,
    required this.availableYears,
    required this.requiredTotal,
    required this.yearEarnedTotal,
    required this.cumulativeTotal,
    required this.rawYearGap,
    required this.categoryGap,
    required this.minimumGap,
    required this.officialConclusion,
    required this.categories,
  });

  /// 分类最低完成度 = (requiredTotal - minimumGap) / requiredTotal
  double get percentage => requiredTotal > 0
      ? ((requiredTotal - minimumGap) / requiredTotal * 100).clamp(0, 100)
      : 0;

  factory ErkeYearlySummary.fromJson(Map<String, dynamic> json) {
    final cats = (json['categories'] as List<dynamic>?)
            ?.map((e) => ErkeYearlyCategory.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final years = (json['availableYears'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    return ErkeYearlySummary(
      year: json['year'] as String? ?? '',
      availableYears: years,
      requiredTotal: (json['requiredTotal'] as num?)?.toDouble() ?? 0,
      yearEarnedTotal: (json['yearEarnedTotal'] as num?)?.toDouble() ?? 0,
      cumulativeTotal: (json['cumulativeTotal'] as num?)?.toDouble() ?? 0,
      rawYearGap: (json['rawYearGap'] as num?)?.toDouble() ?? 0,
      categoryGap: (json['categoryGap'] as num?)?.toDouble() ?? 0,
      minimumGap: (json['minimumGap'] as num?)?.toDouble() ?? 0,
      officialConclusion: json['officialConclusion'] as String? ?? '',
      categories: cats,
    );
  }

  Map<String, dynamic> toJson() => {
        'year': year,
        'availableYears': availableYears,
        'requiredTotal': requiredTotal,
        'yearEarnedTotal': yearEarnedTotal,
        'cumulativeTotal': cumulativeTotal,
        'rawYearGap': rawYearGap,
        'categoryGap': categoryGap,
        'minimumGap': minimumGap,
        'officialConclusion': officialConclusion,
        'categories': categories.map((c) => c.toJson()).toList(),
      };
}

// ---- 完整快照 ----

class ErkeSnapshot {
  final ErkeGraduationSummary? graduation;
  final ErkeYearlySummary? yearly;
  final Map<String, ErkeYearlySummary> yearlyByYear;
  final List<ErkeActivity> activities;
  final Map<String, List<ErkeActivity>> activitiesByYear;
  final DateTime? fetchedAt;

  const ErkeSnapshot({
    this.graduation,
    this.yearly,
    this.yearlyByYear = const {},
    this.activities = const [],
    this.activitiesByYear = const {},
    this.fetchedAt,
  });

  factory ErkeSnapshot.fromJson(Map<String, dynamic> json) {
    final yearlyMap = <String, ErkeYearlySummary>{};
    final rawYearlyMap = json['yearlyByYear'] as Map<String, dynamic>?;
    if (rawYearlyMap != null) {
      for (final entry in rawYearlyMap.entries) {
        yearlyMap[entry.key] =
            ErkeYearlySummary.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    final acts = (json['activities'] as List<dynamic>?)
            ?.map((e) => ErkeActivity.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    final actsByYear = <String, List<ErkeActivity>>{};
    final rawActsByYear = json['activitiesByYear'] as Map<String, dynamic>?;
    if (rawActsByYear != null) {
      for (final entry in rawActsByYear.entries) {
        actsByYear[entry.key] = (entry.value as List<dynamic>)
            .map((e) => ErkeActivity.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    }

    return ErkeSnapshot(
      graduation: json['graduation'] != null
          ? ErkeGraduationSummary.fromJson(
              json['graduation'] as Map<String, dynamic>)
          : null,
      yearly: json['yearly'] != null
          ? ErkeYearlySummary.fromJson(json['yearly'] as Map<String, dynamic>)
          : null,
      yearlyByYear: yearlyMap,
      activities: acts,
      activitiesByYear: actsByYear,
      fetchedAt: json['fetchedAt'] != null
          ? DateTime.tryParse(json['fetchedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        if (graduation != null) 'graduation': graduation!.toJson(),
        if (yearly != null) 'yearly': yearly!.toJson(),
        'yearlyByYear': yearlyByYear.map((k, v) => MapEntry(k, v.toJson())),
        'activities': activities.map((a) => a.toJson()).toList(),
        'activitiesByYear': activitiesByYear
            .map((k, v) => MapEntry(k, v.map((a) => a.toJson()).toList())),
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toIso8601String(),
      };

  /// 从旧缓存迁移：旧格式只有 summary (List<Map>) 和 scores (List<Map>)
  factory ErkeSnapshot.fromLegacyCache({
    required List<dynamic>? scores,
    required List<dynamic>? summary,
  }) {
    final activities = (scores ?? [])
        .map((e) => ErkeActivity.fromLegacyMap(e as Map<String, dynamic>))
        .toList();
    // 旧 summary 是本地计算的，没有官方结论。仅做迁移占位。
    return ErkeSnapshot(
      activities: activities,
      fetchedAt: null,
    );
  }

  bool get hasGraduationData => graduation != null;
  bool get hasYearlyData => yearly != null;
  bool get hasActivities => activities.isNotEmpty;
}

// ---- 学年查询表单（GET 返回的初始页面结构）----

class YearPageForm {
  final List<String> availableYears;
  final String selectedYear;
  final Map<String, String> hiddenInputs;
  final String? submitButtonName;
  final String? submitButtonValue;
  final String? eventTarget;

  const YearPageForm({
    required this.availableYears,
    required this.selectedYear,
    required this.hiddenInputs,
    this.submitButtonName,
    this.submitButtonValue,
    this.eventTarget,
  });

  bool get isResultPage => false; // 表单页不是结果页
}
