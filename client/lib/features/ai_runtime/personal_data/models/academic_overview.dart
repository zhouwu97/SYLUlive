/// 单学期成绩数据的最小化覆盖信息。
class AcademicTermOverview {
  const AcademicTermOverview({
    required this.year,
    required this.semester,
    required this.courseCount,
    required this.fetchedAt,
  });

  final String year;
  final int semester;
  final int courseCount;
  final DateTime fetchedAt;
}

/// 供后续本地 Skill 使用的成绩数据覆盖概览。
///
/// 阶段 4B 不计算 GPA、学分或毕业结论，也不返回单门成绩、课程名称、学号
/// 或保险箱原始 Payload。
class AcademicOverview {
  AcademicOverview({
    required List<AcademicTermOverview> terms,
    required this.totalRecordedCourses,
    required this.hasAcademicSituation,
    this.academicSituationFetchedAt,
  }) : terms = List<AcademicTermOverview>.unmodifiable(terms);

  final List<AcademicTermOverview> terms;
  final int totalRecordedCourses;
  final bool hasAcademicSituation;
  final DateTime? academicSituationFetchedAt;
}
