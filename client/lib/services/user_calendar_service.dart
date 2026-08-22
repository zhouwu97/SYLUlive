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
  }) async {
    final response =
        await _dio.post('/user/calendar/events', data: <String, dynamic>{
      'title': title,
      'description': description,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': endAt.toUtc().toIso8601String(),
      'all_day': allDay,
      'location': location,
      'timezone': timezone,
    });
    _expect(response, 201);
    return UserCalendarEvent.fromJson(_map(response.data));
  }

  Future<UserCalendarReminder> createReminder(
      int eventId, int minutesBefore) async {
    final response = await _dio.post(
      '/user/calendar/events/$eventId/reminders',
      data: <String, dynamic>{'minutes_before': minutesBefore},
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

  Future<UserCalendarActionDraft> confirmDraft(int id) async {
    final response = await _dio.post('/user/calendar-action-drafts/$id/confirm',
        data: const <String, dynamic>{});
    _expect(response, 200);
    return UserCalendarActionDraft.fromJson(_map(response.data));
  }

  Future<UserCalendarActionDraft> cancelDraft(int id) async {
    final response = await _dio.post('/user/calendar-action-drafts/$id/cancel',
        data: const <String, dynamic>{});
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
