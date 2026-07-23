import 'dart:convert';


import '../models/exam_schedule.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


/// 统一管理考试页与其它校园页面共享的本地考试安排。
class ExamScheduleRepository {
  static const localExamsKey = 'local_exams';

  Future<List<ExamModel>> load() async {
    final preferences = await AppPreferencesStore.getInstance();
    final encoded = preferences.getString(localExamsKey);
    if (encoded == null || encoded.isEmpty) return const [];

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const [];

      final exams = <ExamModel>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          exams.add(ExamModel.fromJson(Map<String, dynamic>.from(item)));
        } on FormatException {
          // 忽略损坏的单条记录，避免其余导入安排无法展示。
        }
      }
      exams.sort((left, right) => left.startTime.compareTo(right.startTime));
      return exams;
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<ExamModel> exams) async {
    final preferences = await AppPreferencesStore.getInstance();
    final encoded = jsonEncode(exams.map((exam) => exam.toJson()).toList());
    await preferences.setString(localExamsKey, encoded);
  }
}
