import 'dart:convert';

/// 由服务端发布、客户端渲染的校历数据。
class CampusCalendar {
  final int schemaVersion;
  final String calendarId;
  final String school;
  final String academicYear;
  final String timezone;
  final int version;
  final String revision;
  final String status;
  final CampusCalendarSource source;
  final List<CampusSemester> semesters;
  final List<CampusCalendarEvent> events;
  final List<CampusDayOverride> dayOverrides;
  final List<String> unresolvedItems;

  const CampusCalendar({
    required this.schemaVersion,
    required this.calendarId,
    required this.school,
    required this.academicYear,
    required this.timezone,
    required this.version,
    required this.revision,
    required this.status,
    required this.source,
    required this.semesters,
    required this.events,
    required this.dayOverrides,
    required this.unresolvedItems,
  });

  factory CampusCalendar.fromJson(Map<String, dynamic> json) {
    return CampusCalendar(
      schemaVersion: _asInt(json['schema_version']),
      calendarId: _asString(json['calendar_id']),
      school: _asString(json['school']),
      academicYear: _asString(json['academic_year']),
      timezone: _asString(json['timezone'], fallback: 'Asia/Shanghai'),
      version: _asInt(json['version']),
      revision: _asString(json['revision']),
      status: _asString(json['status']),
      source: CampusCalendarSource.fromJson(_asMap(json['source'])),
      semesters: _asList(json['semesters'])
          .map((item) => CampusSemester.fromJson(_asMap(item)))
          .toList(growable: false),
      events: _asList(json['events'])
          .map((item) => CampusCalendarEvent.fromJson(_asMap(item)))
          .toList(growable: false),
      dayOverrides: _asList(json['day_overrides'])
          .map((item) => CampusDayOverride.fromJson(_asMap(item)))
          .toList(growable: false),
      unresolvedItems: _asList(json['unresolved_items'])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'calendar_id': calendarId,
        'school': school,
        'academic_year': academicYear,
        'timezone': timezone,
        'version': version,
        if (revision.isNotEmpty) 'revision': revision,
        'status': status,
        'source': source.toJson(),
        'semesters': semesters.map((item) => item.toJson()).toList(),
        'events': events.map((item) => item.toJson()).toList(),
        'day_overrides': dayOverrides.map((item) => item.toJson()).toList(),
        'unresolved_items': unresolvedItems,
      };

  String encode() => jsonEncode(toJson());

  CampusSemester? semesterFor(DateTime date) {
    return _firstWhereOrNull(
      semesters,
      (semester) => semester.contains(date),
    );
  }

  CampusDayInfo dayInfo(DateTime date) {
    final normalized = dateOnly(date);
    final semester = semesterFor(normalized);
    final teachingWeek = semester?.teachingWeekFor(normalized);
    final override = _firstWhereOrNull(
      dayOverrides,
      (item) => sameDay(item.date, normalized),
    );
    final dayEvents = events
        .where((event) => event.contains(normalized))
        .toList(growable: false);
    return CampusDayInfo(
      date: normalized,
      semester: semester,
      teachingWeek: teachingWeek,
      override: override,
      events: dayEvents,
    );
  }
}

class CampusCalendarSource {
  final String type;
  final String title;
  final String fileName;
  final bool verified;

  const CampusCalendarSource({
    required this.type,
    required this.title,
    required this.fileName,
    required this.verified,
  });

  factory CampusCalendarSource.fromJson(Map<String, dynamic> json) {
    return CampusCalendarSource(
      type: _asString(json['type']),
      title: _asString(json['title']),
      fileName: _asString(json['file_name']),
      verified: json['verified'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'title': title,
        'file_name': fileName,
        'verified': verified,
      };
}

class CampusSemester {
  final String id;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final List<TeachingWeek> teachingWeeks;

  const CampusSemester({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.teachingWeeks,
  });

  factory CampusSemester.fromJson(Map<String, dynamic> json) {
    return CampusSemester(
      id: _asString(json['id']),
      name: _asString(json['name']),
      startDate: parseCalendarDate(_asString(json['start_date'])),
      endDate: parseCalendarDate(_asString(json['end_date'])),
      teachingWeeks: _asList(json['teaching_weeks'])
          .map((item) => TeachingWeek.fromJson(_asMap(item)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'start_date': formatCalendarDate(startDate),
        'end_date': formatCalendarDate(endDate),
        'teaching_weeks': teachingWeeks.map((item) => item.toJson()).toList(),
      };

  bool contains(DateTime date) =>
      !date.isBefore(startDate) && !date.isAfter(endDate);

  TeachingWeek? teachingWeekFor(DateTime date) =>
      _firstWhereOrNull(teachingWeeks, (week) => week.contains(date));
}

class TeachingWeek {
  final int week;
  final DateTime startDate;
  final DateTime endDate;

  const TeachingWeek({
    required this.week,
    required this.startDate,
    required this.endDate,
  });

  factory TeachingWeek.fromJson(Map<String, dynamic> json) => TeachingWeek(
        week: _asInt(json['week']),
        startDate: parseCalendarDate(_asString(json['start_date'])),
        endDate: parseCalendarDate(_asString(json['end_date'])),
      );

  Map<String, dynamic> toJson() => {
        'week': week,
        'start_date': formatCalendarDate(startDate),
        'end_date': formatCalendarDate(endDate),
      };

  bool contains(DateTime date) =>
      !date.isBefore(startDate) && !date.isAfter(endDate);
}

class CampusCalendarEvent {
  final String id;
  final String title;
  final String type;
  final DateTime startDate;
  final DateTime endDate;
  final String badge;
  final String description;
  final String status;

  const CampusCalendarEvent({
    required this.id,
    required this.title,
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.badge,
    required this.description,
    required this.status,
  });

  factory CampusCalendarEvent.fromJson(Map<String, dynamic> json) {
    return CampusCalendarEvent(
      id: _asString(json['id']),
      title: _asString(json['title']),
      type: _asString(json['type']),
      startDate: parseCalendarDate(_asString(json['start_date'])),
      endDate: parseCalendarDate(_asString(json['end_date'])),
      badge: _asString(json['badge']),
      description: _asString(json['description']),
      status: _asString(json['status'], fallback: 'confirmed'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type,
        'start_date': formatCalendarDate(startDate),
        'end_date': formatCalendarDate(endDate),
        'badge': badge,
        'description': description,
        'status': status,
      };

  bool contains(DateTime date) =>
      !date.isBefore(startDate) && !date.isAfter(endDate);
}

class CampusDayOverride {
  final DateTime date;
  final String dayMode;
  final String badge;
  final String title;
  final int? scheduleAsWeekday;
  final String description;

  const CampusDayOverride({
    required this.date,
    required this.dayMode,
    required this.badge,
    required this.title,
    required this.scheduleAsWeekday,
    required this.description,
  });

  factory CampusDayOverride.fromJson(Map<String, dynamic> json) {
    return CampusDayOverride(
      date: parseCalendarDate(_asString(json['date'])),
      dayMode: _asString(json['day_mode']),
      badge: _asString(json['badge']),
      title: _asString(json['title']),
      scheduleAsWeekday: json['schedule_as_weekday'] is int
          ? json['schedule_as_weekday'] as int
          : int.tryParse('${json['schedule_as_weekday'] ?? ''}'),
      description: _asString(json['description']),
    );
  }

  Map<String, dynamic> toJson() => {
        'date': formatCalendarDate(date),
        'day_mode': dayMode,
        'badge': badge,
        'title': title,
        if (scheduleAsWeekday != null) 'schedule_as_weekday': scheduleAsWeekday,
        'description': description,
      };
}

class CampusDayInfo {
  final DateTime date;
  final CampusSemester? semester;
  final TeachingWeek? teachingWeek;
  final CampusDayOverride? override;
  final List<CampusCalendarEvent> events;

  const CampusDayInfo({
    required this.date,
    required this.semester,
    required this.teachingWeek,
    required this.override,
    required this.events,
  });

  bool get isWeekend =>
      date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

  bool get isTeachingDay {
    if (override != null) return override!.dayMode == 'makeup_teaching';
    return teachingWeek != null && !isWeekend;
  }

  List<CampusCalendarMarker> get markers {
    final result = <CampusCalendarMarker>[];
    if (override != null && override!.badge.isNotEmpty) {
      result.add(CampusCalendarMarker(
        badge: override!.badge,
        type: override!.dayMode,
        title: override!.title,
      ));
    }
    for (final event in events) {
      if (event.badge.isNotEmpty) {
        result.add(CampusCalendarMarker(
          badge: event.badge,
          type: event.type,
          title: event.title,
        ));
      }
    }
    return result;
  }
}

class CampusCalendarMarker {
  final String badge;
  final String type;
  final String title;

  const CampusCalendarMarker({
    required this.badge,
    required this.type,
    required this.title,
  });
}

DateTime parseCalendarDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) throw FormatException('无效校历日期: $value');
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

String formatCalendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

bool sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

T? _firstWhereOrNull<T>(Iterable<T> source, bool Function(T item) predicate) {
  for (final item in source) {
    if (predicate(item)) return item;
  }
  return null;
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<dynamic> _asList(dynamic value) => value is List ? value : const [];

String _asString(dynamic value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

int _asInt(dynamic value) => value is int ? value : int.tryParse('$value') ?? 0;
