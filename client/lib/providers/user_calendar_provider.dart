import 'package:flutter/foundation.dart';

import '../models/user_calendar.dart';
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
}
