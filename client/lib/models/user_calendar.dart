import '../features/ai_runtime/skills/personal_skill.dart';

class UserCalendarEvent {
  const UserCalendarEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.description,
    required this.startAt,
    required this.endAt,
    required this.allDay,
    required this.location,
    required this.timezone,
    required this.sourceType,
    required this.createdBy,
    required this.version,
  });

  final int id;
  final int calendarId;
  final String title;
  final String description;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String location;
  final String timezone;
  final String sourceType;
  final String createdBy;
  final int version;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'calendar_id': calendarId,
        'title': title,
        'description': description,
        'start_at': startAt.toUtc().toIso8601String(),
        'end_at': endAt.toUtc().toIso8601String(),
        'all_day': allDay,
        'location': location,
        'timezone': timezone,
        'source_type': sourceType,
        'created_by': createdBy,
        'version': version,
      };

  factory UserCalendarEvent.fromJson(Map<String, dynamic> json) {
    return UserCalendarEvent(
      id: _int(json['id']),
      calendarId: _int(json['calendar_id']),
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      startAt: DateTime.tryParse(json['start_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endAt: DateTime.tryParse(json['end_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      allDay: json['all_day'] == true,
      location: json['location']?.toString() ?? '',
      timezone: json['timezone']?.toString() ?? 'Asia/Shanghai',
      sourceType: json['source_type']?.toString() ?? 'manual',
      createdBy: json['created_by']?.toString() ?? 'user',
      version: _int(json['version'], fallback: 1),
    );
  }
}

class UserCalendarReminder {
  const UserCalendarReminder({
    required this.id,
    required this.eventId,
    required this.minutesBefore,
    required this.version,
  });

  final int id;
  final int eventId;
  final int minutesBefore;
  final int version;

  factory UserCalendarReminder.fromJson(Map<String, dynamic> json) {
    return UserCalendarReminder(
      id: _int(json['id']),
      eventId: _int(json['event_id']),
      minutesBefore: _int(json['minutes_before']),
      version: _int(json['version'], fallback: 1),
    );
  }
}

class UserCalendarActionDraft implements SkillActionArtifact {
  const UserCalendarActionDraft({
    required this.id,
    required this.actionType,
    required this.status,
    required this.title,
    required this.description,
    required this.startAt,
    required this.endAt,
    required this.allDay,
    required this.location,
    required this.timezone,
    required this.expiresAt,
    this.targetEventId,
    this.reminderMinutesBefore,
    this.calendarEventId,
    this.event,
  });

  final int id;
  final String actionType;
  final String status;
  final String title;
  final String description;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String location;
  final String timezone;
  final DateTime expiresAt;
  final int? targetEventId;
  final int? reminderMinutesBefore;
  final int? calendarEventId;
  final UserCalendarEvent? event;

  bool get isPending => status == 'waiting_confirmation';
  bool get isExpired =>
      status == 'expired' || !expiresAt.isAfter(DateTime.now());

  UserCalendarActionDraft copyWith({
    String? status,
    DateTime? expiresAt,
    int? calendarEventId,
    UserCalendarEvent? event,
  }) {
    return UserCalendarActionDraft(
      id: id,
      actionType: actionType,
      status: status ?? this.status,
      title: title,
      description: description,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      location: location,
      timezone: timezone,
      expiresAt: expiresAt ?? this.expiresAt,
      targetEventId: targetEventId,
      reminderMinutesBefore: reminderMinutesBefore,
      calendarEventId: calendarEventId ?? this.calendarEventId,
      event: event ?? this.event,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'action_type': actionType,
        'status': status,
        'title': title,
        'description': description,
        'start_at': startAt.toUtc().toIso8601String(),
        'end_at': endAt.toUtc().toIso8601String(),
        'all_day': allDay,
        'location': location,
        'timezone': timezone,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        if (targetEventId != null) 'target_event_id': targetEventId,
        if (reminderMinutesBefore != null)
          'reminder_minutes_before': reminderMinutesBefore,
        if (calendarEventId != null) 'calendar_event_id': calendarEventId,
        if (event != null) 'event': event!.toJson(),
      };

  factory UserCalendarActionDraft.fromJson(Map<String, dynamic> json) {
    return UserCalendarActionDraft(
      id: _int(json['id']),
      actionType: json['action_type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      startAt: DateTime.tryParse(json['start_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endAt: DateTime.tryParse(json['end_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      allDay: json['all_day'] == true,
      location: json['location']?.toString() ?? '',
      timezone: json['timezone']?.toString() ?? 'Asia/Shanghai',
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      targetEventId: json['target_event_id'] == null
          ? null
          : _int(json['target_event_id']),
      reminderMinutesBefore: json['reminder_minutes_before'] == null
          ? null
          : _int(json['reminder_minutes_before']),
      calendarEventId: json['calendar_event_id'] == null
          ? null
          : _int(json['calendar_event_id']),
      event: json['event'] is Map
          ? UserCalendarEvent.fromJson(
              Map<String, dynamic>.from(json['event'] as Map),
            )
          : null,
    );
  }
}

int _int(dynamic value, {int fallback = 0}) =>
    value is int ? value : int.tryParse(value?.toString() ?? '') ?? fallback;

int calendarReminderNotificationId(int eventId, int minutesBefore) =>
    1000000000 + ((eventId * 131 + minutesBefore) % 500000000);
