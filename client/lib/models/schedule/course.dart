import 'package:flutter/foundation.dart';
import 'course_source.dart';
import 'meeting.dart';

/// 统一课程数据模型
///
/// 教务课（source = edu）与手动课（source = manual）统一采用本模型。
/// 一门课程包含若干个独立的上课时间块（Meeting）。
class Course {
  final String courseKey;
  final String semesterId;
  final CourseSource source;
  final String name;
  final String? courseCode;
  final String? teachingClassId;
  final String? teacher;
  final double? credit;
  final String color;
  final List<Meeting> meetings;

  const Course({
    required this.courseKey,
    required this.semesterId,
    required this.source,
    required this.name,
    this.courseCode,
    this.teachingClassId,
    this.teacher,
    this.credit,
    this.color = '#6366F1',
    required this.meetings,
  });

  Course copyWith({
    String? courseKey,
    String? semesterId,
    CourseSource? source,
    String? name,
    String? courseCode,
    String? teachingClassId,
    String? teacher,
    double? credit,
    String? color,
    List<Meeting>? meetings,
  }) {
    return Course(
      courseKey: courseKey ?? this.courseKey,
      semesterId: semesterId ?? this.semesterId,
      source: source ?? this.source,
      name: name ?? this.name,
      courseCode: courseCode ?? this.courseCode,
      teachingClassId: teachingClassId ?? this.teachingClassId,
      teacher: teacher ?? this.teacher,
      credit: credit ?? this.credit,
      color: color ?? this.color,
      meetings: meetings ?? this.meetings,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'course_key': courseKey,
      'semester_id': semesterId,
      'source': source.name,
      'name': name,
      if (courseCode != null) 'course_code': courseCode,
      if (teachingClassId != null) 'teaching_class_id': teachingClassId,
      if (teacher != null) 'teacher': teacher,
      if (credit != null) 'credit': credit,
      'color': color,
      'meetings': meetings.map((m) => m.toJson()).toList(),
    };
  }

  factory Course.fromJson(Map<String, dynamic> json) {
    final rawMeetings = json['meetings'] as List<dynamic>? ?? const [];
    final meetings = rawMeetings
        .whereType<Map<String, dynamic>>()
        .map((m) => Meeting.fromJson(m))
        .toList();

    return Course(
      courseKey: json['course_key']?.toString() ?? '',
      semesterId: json['semester_id']?.toString() ?? '',
      source: json['source'] == 'manual'
          ? CourseSource.manual
          : CourseSource.edu,
      name: json['name']?.toString() ?? '',
      courseCode: json['course_code']?.toString(),
      teachingClassId: json['teaching_class_id']?.toString(),
      teacher: json['teacher']?.toString(),
      credit: (json['credit'] as num?)?.toDouble(),
      color: json['color']?.toString() ?? '#6366F1',
      meetings: meetings,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Course &&
          runtimeType == other.runtimeType &&
          courseKey == other.courseKey &&
          semesterId == other.semesterId &&
          source == other.source &&
          name == other.name &&
          listEquals(meetings, other.meetings);

  @override
  int get hashCode =>
      courseKey.hashCode ^ semesterId.hashCode ^ source.hashCode ^ name.hashCode;
}
