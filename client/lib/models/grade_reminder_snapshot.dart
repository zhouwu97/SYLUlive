import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'edu_grade.dart';

class GradeReminderSnapshot {
  final bool initialized;
  final List<GradeReminderSnapshotItem> grades;
  final DateTime updatedAt;

  const GradeReminderSnapshot({
    required this.initialized,
    required this.grades,
    required this.updatedAt,
  });

  factory GradeReminderSnapshot.empty({DateTime? updatedAt}) {
    return GradeReminderSnapshot(
      initialized: true,
      grades: const [],
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  factory GradeReminderSnapshot.fromGrades(
    List<EduGrade> grades, {
    DateTime? updatedAt,
  }) {
    final items = grades
        .map(GradeReminderSnapshotItem.fromGrade)
        .where((item) => item.key.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return GradeReminderSnapshot(
      initialized: true,
      grades: items,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  factory GradeReminderSnapshot.initialBaseline(
    List<EduGrade> grades, {
    DateTime? updatedAt,
  }) {
    final snapshot = GradeReminderSnapshot.fromGrades(
      grades,
      updatedAt: updatedAt,
    );
    if (snapshot.grades.isNotEmpty) return snapshot;
    return GradeReminderSnapshot(
      initialized: false,
      grades: const [],
      updatedAt: snapshot.updatedAt,
    );
  }

  factory GradeReminderSnapshot.fromJson(Map<String, dynamic> json) {
    final rawGrades = json['grades'];
    return GradeReminderSnapshot(
      initialized: json['initialized'] == true,
      grades: rawGrades is List
          ? rawGrades
              .whereType<Map>()
              .map((item) => GradeReminderSnapshotItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .where((item) => item.key.isNotEmpty)
              .toList()
          : const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'initialized': initialized,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'grades': grades.map((item) => item.toJson()).toList(),
      };

  GradeReminderDiff diffFrom(GradeReminderSnapshot? oldSnapshot) {
    if (oldSnapshot == null ||
        !oldSnapshot.initialized ||
        oldSnapshot.grades.isEmpty) {
      return const GradeReminderDiff(changes: [], baselineOnly: true);
    }

    final oldByKey = {
      for (final item in oldSnapshot.grades) item.key: item,
    };
    final changes = <GradeReminderChange>[];

    for (final next in grades) {
      final old = oldByKey[next.key];
      if (old == null) {
        if (next.hasEffectiveGrade) {
          changes.add(GradeReminderChange.added(next));
        }
        continue;
      }

      if (_gradeBecameEffective(old, next) ||
          _changed(old.grade, next.grade) ||
          _changed(old.gpa, next.gpa) ||
          _changed(old.fraction, next.fraction)) {
        if (next.hasEffectiveGrade ||
            old.hasEffectiveGrade ||
            next.gpa != null ||
            next.fraction != null) {
          changes.add(GradeReminderChange.updated(old, next));
        }
      }
    }

    changes.sort((a, b) => a.next.name.compareTo(b.next.name));
    return GradeReminderDiff(changes: changes);
  }

  static bool _gradeBecameEffective(
    GradeReminderSnapshotItem old,
    GradeReminderSnapshotItem next,
  ) {
    return !old.hasEffectiveGrade && next.hasEffectiveGrade;
  }

  static bool _changed(String? a, String? b) {
    return (a ?? '').trim() != (b ?? '').trim();
  }
}

class GradeReminderSnapshotItem {
  final String key;
  final String name;
  final String grade;
  final String? gpa;
  final String? fraction;
  final String credits;
  final String? examType;
  final bool isDegree;

  const GradeReminderSnapshotItem({
    required this.key,
    required this.name,
    required this.grade,
    required this.gpa,
    required this.fraction,
    required this.credits,
    required this.examType,
    required this.isDegree,
  });

  factory GradeReminderSnapshotItem.fromGrade(EduGrade grade) {
    final name = grade.name.trim();
    final credits = _formatNumber(grade.credits);
    final examType = _blankToNull(grade.examType);
    return GradeReminderSnapshotItem(
      key: _stableKey(grade, name, credits, examType),
      name: name,
      grade: grade.displayGrade.trim(),
      gpa: _formatNullableNumber(grade.gpa),
      fraction: _formatNullableNumber(grade.fraction),
      credits: credits,
      examType: examType,
      isDegree: grade.isDegree,
    );
  }

  factory GradeReminderSnapshotItem.fromJson(Map<String, dynamic> json) {
    return GradeReminderSnapshotItem(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      grade: json['grade']?.toString() ?? '',
      gpa: _blankToNull(json['gpa']),
      fraction: _blankToNull(json['fraction']),
      credits: json['credits']?.toString() ?? '0',
      examType: _blankToNull(json['examType'] ?? json['exam_type']),
      isDegree: json['isDegree'] == true || json['is_degree'] == true,
    );
  }

  bool get hasEffectiveGrade {
    final text = grade.trim();
    if (text.isEmpty) return false;
    const placeholders = {
      '--',
      '未录入',
      '暂无',
      '无',
      'null',
      'NULL',
      '缓考',
    };
    return !placeholders.contains(text);
  }

  String get displayGrade => grade.trim().isEmpty ? '--' : grade.trim();

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'grade': grade,
        'gpa': gpa,
        'fraction': fraction,
        'credits': credits,
        'examType': examType,
        'isDegree': isDegree,
      };

  static String _stableKey(
    EduGrade grade,
    String name,
    String credits,
    String? examType,
  ) {
    final studentGradeId = grade.studentGradeId.trim();
    if (studentGradeId.isNotEmpty) return 'student:$studentGradeId';
    final classId = grade.classId.trim();
    if (classId.isNotEmpty) return 'class:$classId';
    final courseId = grade.courseId.trim();
    if (courseId.isNotEmpty) return 'course:$courseId';
    final courseCode = grade.courseCode.trim();
    if (courseCode.isNotEmpty && name.isNotEmpty) {
      return 'code:$courseCode|$name';
    }
    if (name.isNotEmpty) {
      return 'name:$name|$credits|${examType ?? ''}';
    }
    return '';
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  static String? _formatNullableNumber(double? value) {
    if (value == null) return null;
    return _formatNumber(value);
  }

  static String? _blankToNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}

enum GradeReminderChangeType { added, updated }

class GradeReminderChange {
  final GradeReminderChangeType type;
  final GradeReminderSnapshotItem? previous;
  final GradeReminderSnapshotItem next;

  const GradeReminderChange._({
    required this.type,
    required this.previous,
    required this.next,
  });

  factory GradeReminderChange.added(GradeReminderSnapshotItem next) {
    return GradeReminderChange._(
      type: GradeReminderChangeType.added,
      previous: null,
      next: next,
    );
  }

  factory GradeReminderChange.updated(
    GradeReminderSnapshotItem previous,
    GradeReminderSnapshotItem next,
  ) {
    return GradeReminderChange._(
      type: GradeReminderChangeType.updated,
      previous: previous,
      next: next,
    );
  }

  String get summary {
    final oldGrade = previous?.displayGrade ?? '--';
    return '${next.name}: $oldGrade -> ${next.displayGrade}';
  }

  Map<String, dynamic> toHashJson() => {
        'type': type.name,
        'key': next.key,
        'name': next.name,
        'oldGrade': previous?.displayGrade ?? '',
        'newGrade': next.displayGrade,
        'oldGpa': previous?.gpa ?? '',
        'newGpa': next.gpa ?? '',
        'oldFraction': previous?.fraction ?? '',
        'newFraction': next.fraction ?? '',
      };
}

class GradeReminderDiff {
  final List<GradeReminderChange> changes;
  final bool baselineOnly;

  const GradeReminderDiff({
    required this.changes,
    this.baselineOnly = false,
  });

  bool get hasChanges => changes.isNotEmpty;

  String get changeHash {
    if (changes.isEmpty) return '';
    final payload = jsonEncode(changes.map((c) => c.toHashJson()).toList());
    return sha1.convert(utf8.encode(payload)).toString();
  }
}
