import 'package:flutter/foundation.dart';

import '../models/user_calendar.dart';
import '../platform/contracts/reminder_notification_client.dart';
import '../services/user_calendar_service.dart';

class UserCalendarProvider extends ChangeNotifier {
  UserCalendarProvider(this._service);

  final UserCalendarService _service;
  List<UserCalendarEvent> _events = const <UserCalendarEvent>[];
  bool _isLoading = false;
  String? _error;

  List<UserCalendarEvent> get events => _events;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> load({DateTime? from, DateTime? to}) async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _events = await _service.listEvents(from: from, to: to);
    } catch (_) {
      _error = '个人日历暂不可用';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<UserCalendarEvent?> createEvent({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String description = '',
    bool allDay = false,
    String location = '',
    String timezone = 'Asia/Shanghai',
  }) async {
    final event = await _service.createEvent(
      title: title,
      startAt: startAt,
      endAt: endAt,
      description: description,
      allDay: allDay,
      location: location,
      timezone: timezone,
    );
    _events = <UserCalendarEvent>[..._events, event]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    notifyListeners();
    return event;
  }

  Future<UserCalendarEvent> updateEvent(
    int eventId, {
    String? title,
    String? description,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    String? location,
    String? timezone,
  }) async {
    final reminders = await _service.listReminders(eventId);
    final event = await _service.updateEvent(
      eventId,
      title: title,
      description: description,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      location: location,
      timezone: timezone,
    );
    _events = _replaceEvent(event);
    for (final reminder in reminders) {
      final client = ReminderNotificationClient.instance;
      await client.cancelCalendarReminder(
        calendarReminderNotificationId(eventId, reminder.minutesBefore),
      );
      await _scheduleReminder(event, reminder);
    }
    notifyListeners();
    return event;
  }

  Future<void> deleteEvent(int eventId) async {
    final reminders = await _service.listReminders(eventId);
    await _service.deleteEvent(eventId);
    _events =
        _events.where((event) => event.id != eventId).toList(growable: false);
    for (final reminder in reminders) {
      await ReminderNotificationClient.instance.cancelCalendarReminder(
        calendarReminderNotificationId(eventId, reminder.minutesBefore),
      );
    }
    notifyListeners();
  }

  Future<UserCalendarReminder> createReminder(
    int eventId,
    int minutesBefore,
  ) async {
    final reminder = await _service.createReminder(eventId, minutesBefore);
    UserCalendarEvent? event;
    for (final item in _events) {
      if (item.id == eventId) {
        event = item;
        break;
      }
    }
    final scheduledTime = event?.startAt.subtract(
      Duration(minutes: minutesBefore),
    );
    if (event != null &&
        scheduledTime != null &&
        scheduledTime.isAfter(DateTime.now())) {
      await _scheduleReminder(event, reminder);
    }
    return reminder;
  }

  Future<void> deleteReminder(
      int eventId, UserCalendarReminder reminder) async {
    await _service.deleteReminder(eventId, reminder.id);
    await ReminderNotificationClient.instance.cancelCalendarReminder(
      calendarReminderNotificationId(eventId, reminder.minutesBefore),
    );
  }

  Future<void> _scheduleReminder(
    UserCalendarEvent event,
    UserCalendarReminder reminder,
  ) async {
    final scheduledTime = event.startAt.subtract(
      Duration(minutes: reminder.minutesBefore),
    );
    if (!scheduledTime.isAfter(DateTime.now())) return;
    await ReminderNotificationClient.instance.scheduleCalendarReminder(
      id: calendarReminderNotificationId(event.id, reminder.minutesBefore),
      title: event.title,
      body: event.location.isEmpty ? '日历事件即将开始' : event.location,
      scheduledTime: scheduledTime,
      payload: 'calendar_event:${event.id}:reminder:${reminder.id}',
    );
  }

  List<UserCalendarEvent> _replaceEvent(UserCalendarEvent event) {
    final next = <UserCalendarEvent>[
      ..._events.where((item) => item.id != event.id),
      event,
    ];
    next.sort((a, b) => a.startAt.compareTo(b.startAt));
    return next;
  }
}
