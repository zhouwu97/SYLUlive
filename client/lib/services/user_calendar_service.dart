import 'package:dio/dio.dart';

import '../models/user_calendar.dart';

class UserCalendarService {
  UserCalendarService(this._dio);

  final Dio _dio;

  Future<List<UserCalendarEvent>> listEvents(
      {DateTime? from, DateTime? to}) async {
    final response = await _dio
        .get('/user/calendar/events', queryParameters: <String, dynamic>{
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    });
    _expect(response, 200);
    return _list(response.data, 'events')
        .map(UserCalendarEvent.fromJson)
        .toList(growable: false);
  }

  Future<List<UserCalendarReminder>> listReminders(int eventId) async {
    final response = await _dio.get('/user/calendar/events/$eventId/reminders');
    _expect(response, 200);
    return _list(response.data, 'reminders')
        .map(UserCalendarReminder.fromJson)
        .toList(growable: false);
  }

  Future<UserCalendarEvent> createEvent({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String description = '',
    bool allDay = false,
    String location = '',
    String timezone = 'Asia/Shanghai',
    String? idempotencyKey,
  }) async {
    final response = await _dio.post('/user/calendar/events',
        data: <String, dynamic>{
          'title': title,
          'description': description,
          'start_at': startAt.toUtc().toIso8601String(),
          'end_at': endAt.toUtc().toIso8601String(),
          'all_day': allDay,
          'location': location,
          'timezone': timezone,
        },
        options: _writeOptions(idempotencyKey));
    _expect(response, 201);
    return UserCalendarEvent.fromJson(_map(response.data));
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
    String? idempotencyKey,
  }) async {
    final response = await _dio.patch(
      '/user/calendar/events/$eventId',
      data: <String, dynamic>{
        'version': version,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (startAt != null) 'start_at': startAt.toUtc().toIso8601String(),
        if (endAt != null) 'end_at': endAt.toUtc().toIso8601String(),
        if (allDay != null) 'all_day': allDay,
        if (location != null) 'location': location,
        if (timezone != null) 'timezone': timezone,
      },
      options: _writeOptions(idempotencyKey),
    );
    _expect(response, 200);
    return UserCalendarEvent.fromJson(_map(response.data));
  }

  Future<void> deleteEvent(int eventId, {String? idempotencyKey}) async {
    final response = await _dio.delete(
      '/user/calendar/events/$eventId',
      options: _writeOptions(idempotencyKey),
    );
    _expect(response, 204);
  }

  Future<UserCalendarReminder> createReminder(int eventId, int minutesBefore,
      {String? idempotencyKey}) async {
    final response = await _dio.post(
      '/user/calendar/events/$eventId/reminders',
      data: <String, dynamic>{'minutes_before': minutesBefore},
      options: _writeOptions(idempotencyKey),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    return UserCalendarReminder.fromJson(_map(response.data));
  }

  Future<void> deleteReminder(int eventId, int reminderId,
      {String? idempotencyKey}) async {
    final response = await _dio.delete(
      '/user/calendar/events/$eventId/reminders/$reminderId',
      options: _writeOptions(idempotencyKey),
    );
    _expect(response, 204);
  }

  Future<UserCalendarActionDraft> createEventDraft(
    Map<String, dynamic> payload, {
    String? idempotencyKey,
  }) async {
    final response = await _dio.post(
      '/ai/action-drafts/calendar-event',
      data: payload,
      options: Options(headers: <String, dynamic>{
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    return UserCalendarActionDraft.fromJson(_map(response.data));
  }

  Future<UserCalendarActionDraft> createReminderDraft(
    Map<String, dynamic> payload, {
    String? idempotencyKey,
  }) async {
    final response = await _dio.post(
      '/ai/action-drafts/calendar-reminder',
      data: payload,
      options: Options(headers: <String, dynamic>{
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    return UserCalendarActionDraft.fromJson(_map(response.data));
  }

  Future<UserCalendarActionDraft> confirmDraft(int id,
      {String? idempotencyKey}) async {
    final response = await _dio.post(
      '/user/calendar-action-drafts/$id/confirm',
      data: const <String, dynamic>{},
      options: _writeOptions(idempotencyKey),
    );
    _expect(response, 200);
    return UserCalendarActionDraft.fromJson(_map(response.data));
  }

  Future<UserCalendarActionDraft> cancelDraft(int id,
      {String? idempotencyKey}) async {
    final response = await _dio.post(
      '/user/calendar-action-drafts/$id/cancel',
      data: const <String, dynamic>{},
      options: _writeOptions(idempotencyKey),
    );
    _expect(response, 200);
    return UserCalendarActionDraft.fromJson(_map(response.data));
  }

  static List<Map<String, dynamic>> _list(dynamic data, String key) {
    final map = _map(data);
    final value = map[key];
    return value is List
        ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static Options? _writeOptions(String? idempotencyKey) {
    final key = idempotencyKey?.trim();
    if (key == null || key.isEmpty) return null;
    return Options(headers: <String, dynamic>{'Idempotency-Key': key});
  }

  static void _expect(Response<dynamic> response, int status) {
    if (response.statusCode != status) {
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
  }
}
