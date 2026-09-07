/// 教务系统学生基本信息的稳定领域模型。
final class StudentProfile {
  const StudentProfile({
    required this.name,
    required this.grade,
    required this.college,
    required this.major,
    this.studentId,
  });

  final String name;
  final String grade;
  final String college;
  final String major;

  /// 学校资料页明确返回的学号；缺失时上层 Match Gate 必须拒绝继续读取。
  final String? studentId;

  Map<String, String> toJson() => {
        'name': name,
        'grade': grade,
        'college': college,
        'major': major,
        if (studentId != null && studentId!.isNotEmpty)
          'student_id': studentId!,
      };

  @override
  String toString() => 'StudentProfile(<redacted>)';
}
