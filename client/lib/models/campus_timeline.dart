import 'package:flutter/material.dart';

enum CampusTimelineType {
  course,
  exam,
  competition,
  campusEvent,
  personal,
}

class CampusTimelineItem {
  const CampusTimelineItem({
    required this.type,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.allDay,
    required this.location,
    required this.sourceType,
    required this.sourceId,
    required this.importance,
    required this.editable,
    this.sourceVersion,
    this.description = '',
  });

  final CampusTimelineType type;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String location;
  final String sourceType;
  final String sourceId;
  final String importance;
  final bool editable;
  final String? sourceVersion;
  final String description;

  bool intersects(DateTimeRange range) =>
      startAt.isBefore(range.end) && endAt.isAfter(range.start);

  bool occursOn(DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final nextDay = dayStart.add(const Duration(days: 1));
    return startAt.isBefore(nextDay) && endAt.isAfter(dayStart);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.name,
        'title': title,
        'start_at': startAt.toIso8601String(),
        'end_at': endAt.toIso8601String(),
        'all_day': allDay,
        'location': location,
        'source_type': sourceType,
        'source_id': sourceId,
        'importance': importance,
        'editable': editable,
        if (sourceVersion != null) 'source_version': sourceVersion,
        if (description.isNotEmpty) 'description': description,
      };
}

class CompetitionTimelineEntry {
  const CompetitionTimelineEntry({
    required this.eventId,
    required this.title,
    this.registrationEnd,
    this.eventStart,
    this.eventEnd,
    this.version,
    this.location = '',
  });

  final int eventId;
  final String title;
  final DateTime? registrationEnd;
  final DateTime? eventStart;
  final DateTime? eventEnd;
  final int? version;
  final String location;
}
