import 'package:dio/dio.dart';

import '../../../models/user_calendar.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class CalendarActionInput {
  const CalendarActionInput({
    required this.actionType,
    this.eventId,
    this.title,
    this.description,
    this.startAt,
    this.endAt,
    this.allDay,
    this.location,
    this.timezone,
    this.reminderMinutesBefore,
  });

  final String actionType;
  final int? eventId;
  final String? title;
  final String? description;
  final DateTime? startAt;
  final DateTime? endAt;
  final bool? allDay;
  final String? location;
  final String? timezone;
  final int? reminderMinutesBefore;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action_type': actionType,
        if (eventId != null) 'event_id': eventId,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (startAt != null) 'start_at': startAt!.toUtc().toIso8601String(),
        if (endAt != null) 'end_at': endAt!.toUtc().toIso8601String(),
        if (allDay != null) 'all_day': allDay,
        if (location != null) 'location': location,
        if (timezone != null) 'timezone': timezone,
        if (reminderMinutesBefore != null)
          'reminder_minutes_before': reminderMinutesBefore,
      };
}

class CalendarActionException implements Exception {
  const CalendarActionException(this.code, this.message, {this.draft});

  final String code;
  final String message;
  final UserCalendarActionDraft? draft;

  @override
  String toString() => message;
}

abstract interface class CalendarActionSource {
  Future<UserCalendarActionDraft> create(CalendarActionInput input);

  Future<UserCalendarActionDraft> confirm(int draftId);

  Future<UserCalendarActionDraft> cancel(int draftId);
}

class DioCalendarActionSource implements CalendarActionSource {
  DioCalendarActionSource(this._dio);

  final Dio _dio;

  @override
  Future<UserCalendarActionDraft> create(CalendarActionInput input) async {
    final endpoint = input.actionType == 'calendar_reminder_create'
        ? '/ai/action-drafts/calendar-reminder'
        : '/ai/action-drafts/calendar-event';
    try {
      final response = await _dio.post<dynamic>(
        endpoint,
        data: input.toJson(),
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _idempotencyKey(input),
        }),
      );
      return _parse(response.data);
    } on DioException catch (error) {
      throw _actionError(error);
    }
  }

  @override
  Future<UserCalendarActionDraft> confirm(int draftId) async {
    try {
      final response = await _dio.post<dynamic>(
        '/user/calendar-action-drafts/$draftId/confirm',
        data: const <String, dynamic>{},
      );
      return _parse(response.data);
    } on DioException catch (error) {
      throw _actionError(error);
    }
  }

  @override
  Future<UserCalendarActionDraft> cancel(int draftId) async {
    try {
      final response = await _dio.post<dynamic>(
        '/user/calendar-action-drafts/$draftId/cancel',
        data: const <String, dynamic>{},
      );
      return _parse(response.data);
    } on DioException catch (error) {
      throw _actionError(error);
    }
  }

  UserCalendarActionDraft _parse(Object? value) {
    if (value is! Map) {
      throw const FormatException('日历操作草稿响应格式错误');
    }
    return UserCalendarActionDraft.fromJson(
      Map<String, dynamic>.from(value),
    );
  }

  CalendarActionException _actionError(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      UserCalendarActionDraft? draft;
      if (map['draft'] is Map) {
        try {
          draft = UserCalendarActionDraft.fromJson(
            Map<String, dynamic>.from(map['draft'] as Map),
          );
        } catch (_) {}
      }
      return CalendarActionException(
        '${map['code'] ?? 'calendar_action_failed'}',
        '${map['message'] ?? '日历操作未完成'}',
        draft: draft,
      );
    }
    return const CalendarActionException(
      'calendar_action_failed',
      '日历操作未完成，请稍后重试',
    );
  }

  String _idempotencyKey(CalendarActionInput input) {
    final value = input
        .toJson()
        .entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('&');
    return 'calendar-${value.hashCode.abs()}';
  }
}

class CalendarActionSkill
    implements PersonalSkill<CalendarActionInput, UserCalendarActionDraft> {
  CalendarActionSkill(this._source);

  static const String skillId = 'draft_calendar_action';

  final CalendarActionSource _source;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{};

  @override
  Future<SkillResult<UserCalendarActionDraft>> execute(
    CalendarActionInput input,
    SkillExecutionContext context,
  ) async {
    try {
      final draft = await _source.create(input);
      return SkillResult<UserCalendarActionDraft>(
        value: draft,
        status: SkillStatus.success,
        evidence: <SkillEvidence>[
          SkillEvidence(
            source: '神理校园个人日历',
            scope: '服务端生成的待确认日历操作草稿',
            fetchedAt: context.now(),
          ),
        ],
        warnings: const <String>[
          '这是待确认草稿，尚未修改日历；确认后服务端才会执行操作',
          '删除和加提醒同样需要再次确认，不会由模型直接写入个人日历',
        ],
        containsPersonalData: true,
      );
    } on CalendarActionException catch (error) {
      return SkillResult<UserCalendarActionDraft>(
        value: error.draft,
        status: SkillStatus.failed,
        warnings: <String>[error.message],
        containsPersonalData: false,
      );
    } on DioException {
      return SkillResult<UserCalendarActionDraft>(
        status: SkillStatus.unavailable,
        warnings: const <String>['个人日历操作服务暂不可用'],
        containsPersonalData: false,
      );
    } on FormatException {
      return SkillResult<UserCalendarActionDraft>(
        status: SkillStatus.failed,
        warnings: const <String>['日历操作草稿响应格式错误'],
        containsPersonalData: false,
      );
    }
  }
}
