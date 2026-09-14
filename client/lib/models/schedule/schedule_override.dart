import 'package:flutter/foundation.dart';

/// 本地课表调整类型
enum ScheduleOverrideType {
  /// 调整时间（也可附带调整教室）
  reschedule,

  /// 仅修改教室
  changeRoom,

  /// 停课
  cancel,
}

/// 本地课表调整状态
enum ScheduleOverrideStatus {
  /// 正常生效
  active,

  /// 产生课程冲突（仍生效，但课表上标注冲突）
  conflicted,

  /// 孤立规则（教务重新同步后无法重新关联到对应 Meeting）
  orphaned,

  /// 已停用
  disabled,

  /// 需要用户重新确认（教务源数据发生变化，指纹不一致）
  needsReview,
}

/// 本地课表调整规则实体
///
/// 严格遵守不可变原则：用户修改时间、教室、停课均生成或更新此规则，
/// 严禁直接篡改 BaseSchedule。
class ScheduleOverride {
  final String id;
  final String semesterId;
  final String courseKey;
  final String meetingKey;

  final ScheduleOverrideType type;
  final ScheduleOverrideStatus status;

  final Set<int> affectedWeeks;

  final int? toWeekday;
  final int? toStartSection;
  final int? toEndSection;

  final String? toRoom;

  /// 源状态指纹，用于识别教务课表是否已变动
  final String sourceSnapshotHash;

  /// 审计展示字段（Resolver 不依赖这些字段运行）
  final int? fromWeekday;
  final int? fromStartSection;
  final int? fromEndSection;
  final String? fromRoom;

  final DateTime createdAt;
  final DateTime updatedAt;

  const ScheduleOverride({
    required this.id,
    required this.semesterId,
    required this.courseKey,
    required this.meetingKey,
    required this.type,
    this.status = ScheduleOverrideStatus.active,
    required this.affectedWeeks,
    this.toWeekday,
    this.toStartSection,
    this.toEndSection,
    this.toRoom,
    required this.sourceSnapshotHash,
    this.fromWeekday,
    this.fromStartSection,
    this.fromEndSection,
    this.fromRoom,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isActive => status == ScheduleOverrideStatus.active || status == ScheduleOverrideStatus.conflicted;

  ScheduleOverride copyWith({
    String? id,
    String? semesterId,
    String? courseKey,
    String? meetingKey,
    ScheduleOverrideType? type,
    ScheduleOverrideStatus? status,
    Set<int>? affectedWeeks,
    int? toWeekday,
    int? toStartSection,
    int? toEndSection,
    String? toRoom,
    String? sourceSnapshotHash,
    int? fromWeekday,
    int? fromStartSection,
    int? fromEndSection,
    String? fromRoom,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScheduleOverride(
      id: id ?? this.id,
      semesterId: semesterId ?? this.semesterId,
      courseKey: courseKey ?? this.courseKey,
      meetingKey: meetingKey ?? this.meetingKey,
      type: type ?? this.type,
      status: status ?? this.status,
      affectedWeeks: affectedWeeks ?? this.affectedWeeks,
      toWeekday: toWeekday ?? this.toWeekday,
      toStartSection: toStartSection ?? this.toStartSection,
      toEndSection: toEndSection ?? this.toEndSection,
      toRoom: toRoom ?? this.toRoom,
      sourceSnapshotHash: sourceSnapshotHash ?? this.sourceSnapshotHash,
      fromWeekday: fromWeekday ?? this.fromWeekday,
      fromStartSection: fromStartSection ?? this.fromStartSection,
      fromEndSection: fromEndSection ?? this.fromEndSection,
      fromRoom: fromRoom ?? this.fromRoom,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    final sortedWeeks = affectedWeeks.toList()..sort();
    return <String, dynamic>{
      'id': id,
      'semester_id': semesterId,
      'course_key': courseKey,
      'meeting_key': meetingKey,
      'type': type.name,
      'status': status.name,
      'affected_weeks': sortedWeeks,
      if (toWeekday != null) 'to_weekday': toWeekday,
      if (toStartSection != null) 'to_start_section': toStartSection,
      if (toEndSection != null) 'to_end_section': toEndSection,
      if (toRoom != null) 'to_room': toRoom,
      'source_snapshot_hash': sourceSnapshotHash,
      if (fromWeekday != null) 'from_weekday': fromWeekday,
      if (fromStartSection != null) 'from_start_section': fromStartSection,
      if (fromEndSection != null) 'from_end_section': fromEndSection,
      if (fromRoom != null) 'from_room': fromRoom,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory ScheduleOverride.fromJson(Map<String, dynamic> json) {
    final rawWeeks = json['affected_weeks'] as List<dynamic>? ?? const [];
    final parsedWeeks = rawWeeks
        .map((e) => int.tryParse(e.toString()) ?? 0)
        .where((e) => e > 0)
        .toSet();

    final typeStr = json['type']?.toString();
    final type = ScheduleOverrideType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => ScheduleOverrideType.reschedule,
    );

    final statusStr = json['status']?.toString();
    final status = ScheduleOverrideStatus.values.firstWhere(
      (e) => e.name == statusStr,
      orElse: () => ScheduleOverrideStatus.active,
    );

    return ScheduleOverride(
      id: json['id']?.toString() ?? '',
      semesterId: json['semester_id']?.toString() ?? '',
      courseKey: json['course_key']?.toString() ?? '',
      meetingKey: json['meeting_key']?.toString() ?? '',
      type: type,
      status: status,
      affectedWeeks: parsedWeeks,
      toWeekday: (json['to_weekday'] as num?)?.toInt(),
      toStartSection: (json['to_start_section'] as num?)?.toInt(),
      toEndSection: (json['to_end_section'] as num?)?.toInt(),
      toRoom: json['to_room']?.toString(),
      sourceSnapshotHash: json['source_snapshot_hash']?.toString() ?? '',
      fromWeekday: (json['from_weekday'] as num?)?.toInt(),
      fromStartSection: (json['from_start_section'] as num?)?.toInt(),
      fromEndSection: (json['from_end_section'] as num?)?.toInt(),
      fromRoom: json['from_room']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleOverride &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          semesterId == other.semesterId &&
          courseKey == other.courseKey &&
          meetingKey == other.meetingKey &&
          type == other.type &&
          status == other.status &&
          setEquals(affectedWeeks, other.affectedWeeks) &&
          toWeekday == other.toWeekday &&
          toStartSection == other.toStartSection &&
          toEndSection == other.toEndSection &&
          toRoom == other.toRoom &&
          sourceSnapshotHash == other.sourceSnapshotHash;

  @override
  int get hashCode =>
      id.hashCode ^
      semesterId.hashCode ^
      courseKey.hashCode ^
      meetingKey.hashCode ^
      type.hashCode ^
      status.hashCode;
}
