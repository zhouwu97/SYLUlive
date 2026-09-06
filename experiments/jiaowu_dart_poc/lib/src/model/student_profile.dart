/// 教务系统学生基本信息的稳定领域模型。
final class StudentProfile {
  const StudentProfile({
    required this.name,
    required this.grade,
    required this.college,
    required this.major,
  });

  final String name;
  final String grade;
  final String college;
  final String major;

  Map<String, String> toJson() => {
        'name': name,
        'grade': grade,
        'college': college,
        'major': major,
      };

  @override
  String toString() => 'StudentProfile(<redacted>)';
}
