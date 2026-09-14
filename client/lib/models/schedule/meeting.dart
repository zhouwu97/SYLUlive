import 'package:flutter/foundation.dart';

/// 课程教学时间块实体（Meeting）
///
/// 一门课可能存在多个不同时间/教室的上课安排，每个安排对应一个独立的 Meeting。
/// 所有本地调整必须精确定位到 courseKey + meetingKey。
class Meeting {
  final String meetingKey;
  final int weekday;
  final int startSection;
  final int endSection;
  final Set<int> weeks;
  final String? room;
  final String? teacher;
  final String? note;
  final int? periodOrder;
  final String? periodLabel;
  final List<String> periodLabels;

  const Meeting({
    required this.meetingKey,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.room,
    this.teacher,
    this.note,
    this.periodOrder,
    this.periodLabel,
    this.periodLabels = const <String>[],
  });

  int get span => endSection - startSection + 1;

  /// 计算源状态指纹（SourceSnapshotHash）
  ///
  /// 用于在重新同步教务后比对教务课表是否发生了关键变化（节次、周次、教室等）
  String computeSnapshotHash() {
    final sortedWeeks = weeks.toList()..sort();
    final normalizedRoom = room?.trim() ?? '';
    return 'w$weekday:s$startSection-$endSection:weeks[${sortedWeeks.join(',')}]:room[$normalizedRoom]';
  }

  Meeting copyWith({
    String? meetingKey,
    int? weekday,
    int? startSection,
    int? endSection,
    Set<int>? weeks,
    String? room,
    String? teacher,
    String? note,
    int? periodOrder,
    String? periodLabel,
    List<String>? periodLabels,
  }) {
    return Meeting(
      meetingKey: meetingKey ?? this.meetingKey,
      weekday: weekday ?? this.weekday,
      startSection: startSection ?? this.startSection,
      endSection: endSection ?? this.endSection,
      weeks: weeks ?? this.weeks,
      room: room ?? this.room,
      teacher: teacher ?? this.teacher,
      note: note ?? this.note,
      periodOrder: periodOrder ?? this.periodOrder,
      periodLabel: periodLabel ?? this.periodLabel,
      periodLabels: periodLabels ?? this.periodLabels,
    );
  }

  Map<String, dynamic> toJson() {
    final sortedWeeks = weeks.toList()..sort();
    final json = <String, dynamic>{
      'meeting_key': meetingKey,
      'weekday': weekday,
      'start_section': startSection,
      'end_section': endSection,
      'weeks': sortedWeeks,
    };
    if (room != null && room!.isNotEmpty) json['room'] = room;
    if (teacher != null && teacher!.isNotEmpty) json['teacher'] = teacher;
    if (note != null && note!.isNotEmpty) json['note'] = note;
    if (periodOrder != null) json['period_order'] = periodOrder;
    if (periodLabel != null && periodLabel!.isNotEmpty) {
      json['period_label'] = periodLabel;
    }
    if (periodLabels.isNotEmpty) {
      json['period_labels'] = periodLabels;
    }
    return json;
  }

  factory Meeting.fromJson(Map<String, dynamic> json) {
    final rawWeeks = json['weeks'] as List<dynamic>? ?? const [];
    final parsedWeeks = rawWeeks
        .map((e) => int.tryParse(e.toString()) ?? 0)
        .where((e) => e > 0)
        .toSet();

    final rawLabels = json['period_labels'] as List<dynamic>? ?? const [];
    final parsedLabels = rawLabels
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return Meeting(
      meetingKey: json['meeting_key']?.toString() ?? '',
      weekday: (json['weekday'] as num?)?.toInt() ?? 1,
      startSection: (json['start_section'] as num?)?.toInt() ?? 1,
      endSection: (json['end_section'] as num?)?.toInt() ?? 1,
      weeks: parsedWeeks,
      room: json['room']?.toString() ?? json['location']?.toString(),
      teacher: json['teacher']?.toString(),
      note: json['note']?.toString(),
      periodOrder: (json['period_order'] as num?)?.toInt(),
      periodLabel: json['period_label']?.toString(),
      periodLabels: parsedLabels,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Meeting &&
          runtimeType == other.runtimeType &&
          meetingKey == other.meetingKey &&
          weekday == other.weekday &&
          startSection == other.startSection &&
          endSection == other.endSection &&
          setEquals(weeks, other.weeks) &&
          room == other.room &&
          teacher == other.teacher &&
          note == other.note;

  @override
  int get hashCode =>
      meetingKey.hashCode ^
      weekday.hashCode ^
      startSection.hashCode ^
      endSection.hashCode ^
      room.hashCode ^
      teacher.hashCode;
}
