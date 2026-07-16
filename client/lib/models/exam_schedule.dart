/// 用户维护的单场考试安排。
class ExamModel {
  const ExamModel({
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.location,
    this.semester = '',
  });

  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final String location;
  final String semester;

  factory ExamModel.fromJson(Map<String, dynamic> json) => ExamModel(
        name: json['name'] as String? ?? '',
        startTime: DateTime.parse(json['startTime'] as String),
        endTime: DateTime.parse(json['endTime'] as String),
        location: json['location'] as String? ?? '',
        semester: json['semester'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'location': location,
        'semester': semester,
      };

  bool occursOn(DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final nextDay = dayStart.add(const Duration(days: 1));
    return startTime.isBefore(nextDay) && endTime.isAfter(dayStart);
  }
}
