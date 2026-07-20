class FitnessTimeWindow {
  const FitnessTimeWindow({required this.start, required this.end});
  final DateTime start;
  final DateTime end;
  int get minutes => end.difference(start).inMinutes;
}

enum FitnessIntensity { light, moderate }

class FitnessSession {
  const FitnessSession({
    required this.start,
    required this.minutes,
    required this.intensity,
  });
  final DateTime start;
  final int minutes;
  final FitnessIntensity intensity;
}

class FitnessWeeklyPlan {
  FitnessWeeklyPlan({
    required this.bmi,
    required this.bmiVersion,
    required List<FitnessSession> sessions,
    required List<String> safetyNotes,
  })  : sessions = List.unmodifiable(sessions),
        safetyNotes = List.unmodifiable(safetyNotes);
  final double? bmi;
  final String bmiVersion;
  final List<FitnessSession> sessions;
  final List<String> safetyNotes;
}

class FitnessWeeklyPlanEngine {
  static const String bmiVersion = 'who-bmi-v1';

  FitnessWeeklyPlan build({
    required List<FitnessTimeWindow> freeWindows,
    double? heightMeters,
    double? weightKg,
    bool physicalOverviewAvailable = false,
    bool physicalOverviewStale = false,
    bool reportsDiscomfort = false,
  }) {
    final validBody = heightMeters != null &&
        weightKg != null &&
        heightMeters >= 1.2 &&
        heightMeters <= 2.3 &&
        weightKg >= 30 &&
        weightKg <= 250;
    final bmi = validBody ? weightKg / (heightMeters * heightMeters) : null;
    final extremeBmi = bmi != null && (bmi < 16 || bmi > 35);
    final intensity = physicalOverviewAvailable &&
            !physicalOverviewStale &&
            !reportsDiscomfort &&
            !extremeBmi
        ? FitnessIntensity.moderate
        : FitnessIntensity.light;
    final sorted = freeWindows.where((item) => item.minutes >= 30).toList()
      ..sort((left, right) => left.start.compareTo(right.start));
    final sessions = <FitnessSession>[];
    for (final window in sorted) {
      if (reportsDiscomfort || extremeBmi) break;
      if (sessions.length >= 3) break;
      if (sessions.isNotEmpty &&
          window.start.difference(sessions.last.start).inHours < 20) {
        continue;
      }
      sessions.add(
        FitnessSession(
          start: window.start,
          minutes: window.minutes.clamp(30, 60),
          intensity: intensity,
        ),
      );
    }
    return FitnessWeeklyPlan(
      bmi: bmi,
      bmiVersion: bmiVersion,
      sessions: sessions,
      safetyNotes: <String>[
        if (!validBody) '缺少有效身高体重，不据此提高训练强度',
        if (!physicalOverviewAvailable) '缺少体测概览，仅安排轻强度活动',
        if (physicalOverviewStale) '体测数据已过期，仅保留保守安排',
        if (reportsDiscomfort) '存在身体不适时停止训练并寻求专业帮助',
        if (extremeBmi) 'BMI 处于高风险范围，停止具体训练强度建议并咨询专业人士',
        '本计划不是医疗诊断或减重处方',
      ],
    );
  }
}
