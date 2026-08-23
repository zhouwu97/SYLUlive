import 'package:flutter/foundation.dart';

import '../models/user_calendar.dart';
import '../platform/contracts/reminder_notification_client.dart';
import '../services/user_calendar_service.dart';
import '../services/domain_change_bus.dart';

class UserCalendarProvider extends ChangeNotifier {
  UserCalendarProvider(this._service);

  final UserCalendarService _service;
  List<UserCalendarEvent> _events = const <UserCalendarEvent>[];
  bool _isLoading = false;
  String? _error;
  String? _reminderWarning;
  int? _sessionUserId;
  int _authSessionGeneration = 0;
  int _requestGeneration = 0;

  List<UserCalendarEvent> get events => _events;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get reminderWarning => _reminderWarning;

  /// 由 AuthProvider ProxyProvider 驱动。切号时先清空旧账号数据，再让所有
  /// 未完成请求失效，避免旧响应覆盖当前账号的日历状态。
  void syncSessionUser(int? userId, int authSessionGeneration) {
    final normalizedUserId = userId != null && userId > 0 ? userId : null;
    if (_sessionUserId == normalizedUserId &&
        _authSessionGeneration == authSessionGeneration) {
      return;
    }
    _sessionUserId = normalizedUserId;
    _authSessionGeneration = authSessionGeneration;
    _requestGeneration++;
    _events = const <UserCalendarEvent>[];
    _isLoading = false;
    _error = null;
    _reminderWarning = null;
    notifyListeners();
  }

  Future<void> load({DateTime? from, DateTime? to}) async {
    if (_isLoading) return;
    final generation = _requestGeneration;
    final userId = _sessionUserId;
    final authSessionGeneration = _authSessionGeneration;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final events = await _service.listEvents(from: from, to: to);
      if (!_isCurrent(generation, userId, authSessionGeneration)) return;
      _events = events;
      await _reconcileReminders(
        events,
        generation: generation,
        userId: userId,
        authSessionGeneration: authSessionGeneration,
      );
    } catch (_) {
      if (_isCurrent(generation, userId, authSessionGeneration)) {
        _error = '个人日历暂不可用';
      }
    } finally {
      if (_isCurrent(generation, userId, authSessionGeneration)) {
        _isLoading = false;
        notifyListeners();
      }
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
    final capture = _capture();
    final event = await _service.createEvent(
      title: title,
      startAt: startAt,
      endAt: endAt,
      description: description,
      allDay: allDay,
      location: location,
      timezone: timezone,
    );
    if (!_isCurrentCapture(capture)) return null;
    _events = <UserCalendarEvent>[..._events, event]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    notifyListeners();
    DomainChangeBus.instance.emit(DomainChange.userCalendar);
    return event;
  }

  Future<UserCalendarEvent> updateEvent(
    int eventId, {
    required int version,
    String? title,
    String? description,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    String? location,
    String? timezone,
  }) async {
    final capture = _capture();
    final reminders = await _service.listReminders(eventId);
    if (!_isCurrentCapture(capture)) {
      throw StateError('calendar_session_changed');
    }
    final event = await _service.updateEvent(
      eventId,
      version: version,
      title: title,
      description: description,
      startAt: startAt,
      endAt: endAt,
      allDay: allDay,
      location: location,
      timezone: timezone,
    );
    if (!_isCurrentCapture(capture)) {
      return event;
    }
    _events = _replaceEvent(event);
    for (final reminder in reminders) {
      final client = ReminderNotificationClient.instance;
      try {
        await client.cancelCalendarReminder(
          calendarReminderNotificationId(eventId, reminder.minutesBefore),
        );
      } catch (_) {}
      final scheduled = await _scheduleReminder(event, reminder);
      if (!scheduled) _reminderWarning = _reminderUnavailableMessage;
    }
    notifyListeners();
    DomainChangeBus.instance.emit(DomainChange.userCalendar);
    return event;
  }

  Future<void> deleteEvent(int eventId) async {
    final capture = _capture();
    final reminders = await _service.listReminders(eventId);
    if (!_isCurrentCapture(capture)) return;
    await _service.deleteEvent(eventId);
    if (!_isCurrentCapture(capture)) return;
    _events =
        _events.where((event) => event.id != eventId).toList(growable: false);
    for (final reminder in reminders) {
      try {
        await ReminderNotificationClient.instance.cancelCalendarReminder(
          calendarReminderNotificationId(eventId, reminder.minutesBefore),
        );
      } catch (_) {}
    }
    notifyListeners();
    DomainChangeBus.instance.emit(DomainChange.userCalendar);
  }

  Future<UserCalendarReminder> createReminder(
    int eventId,
    int minutesBefore,
  ) async {
    final capture = _capture();
    final reminder = await _service.createReminder(eventId, minutesBefore);
    if (!_isCurrentCapture(capture)) return reminder;
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
      final scheduled = await _scheduleReminder(event, reminder);
      if (!scheduled) _reminderWarning = _reminderUnavailableMessage;
    }
    DomainChangeBus.instance.emit(DomainChange.reminder);
    return reminder;
  }

  Future<void> deleteReminder(
      int eventId, UserCalendarReminder reminder) async {
    final capture = _capture();
    await _service.deleteReminder(eventId, reminder.id);
    if (!_isCurrentCapture(capture)) return;
    try {
      await ReminderNotificationClient.instance.cancelCalendarReminder(
        calendarReminderNotificationId(eventId, reminder.minutesBefore),
      );
    } catch (_) {}
    DomainChangeBus.instance.emit(DomainChange.reminder);
  }

  Future<bool> _scheduleReminder(
    UserCalendarEvent event,
    UserCalendarReminder reminder,
  ) async {
    final scheduledTime = event.startAt.subtract(
      Duration(minutes: reminder.minutesBefore),
    );
    if (!scheduledTime.isAfter(DateTime.now())) return true;
    try {
      return await ReminderNotificationClient.instance.scheduleCalendarReminder(
        id: calendarReminderNotificationId(event.id, reminder.minutesBefore),
        title: event.title,
        body: event.location.isEmpty ? '日历事件即将开始' : event.location,
        scheduledTime: scheduledTime,
        payload: 'calendar_event:${event.id}:reminder:${reminder.id}',
      );
    } catch (_) {
      return false;
    }
  }

  static const _reminderUnavailableMessage = '提醒已保存，但当前设备未启用本地系统提醒';

  Future<void> _reconcileReminders(
    List<UserCalendarEvent> events, {
    required int generation,
    required int? userId,
    required int authSessionGeneration,
  }) async {
    final upcoming = events
        .where((event) => event.startAt.isAfter(DateTime.now()))
        .toList(growable: false);
    for (final event in upcoming) {
      if (!_isCurrent(generation, userId, authSessionGeneration)) return;
      try {
        final reminders = await _service.listReminders(event.id);
        if (!_isCurrent(generation, userId, authSessionGeneration)) return;
        for (final reminder in reminders) {
          final scheduled = await _scheduleReminder(event, reminder);
          if (!scheduled) _reminderWarning = _reminderUnavailableMessage;
        }
      } catch (_) {
        // 日历主体已成功加载；提醒恢复失败只进入可见警告，不污染日历数据状态。
        _reminderWarning = _reminderUnavailableMessage;
      }
    }
  }

  ({int generation, int? userId, int authSessionGeneration}) _capture() => (
        generation: _requestGeneration,
        userId: _sessionUserId,
        authSessionGeneration: _authSessionGeneration,
      );

  bool _isCurrent(
    int generation,
    int? userId,
    int authSessionGeneration,
  ) =>
      generation == _requestGeneration &&
      userId == _sessionUserId &&
      authSessionGeneration == _authSessionGeneration;

  bool _isCurrentCapture(
    ({int generation, int? userId, int authSessionGeneration}) capture,
  ) =>
      _isCurrent(
          capture.generation, capture.userId, capture.authSessionGeneration);

  List<UserCalendarEvent> _replaceEvent(UserCalendarEvent event) {
    final next = <UserCalendarEvent>[
      ..._events.where((item) => item.id != event.id),
      event,
    ];
    next.sort((a, b) => a.startAt.compareTo(b.startAt));
    return next;
  }
}
