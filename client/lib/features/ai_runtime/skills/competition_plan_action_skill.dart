import 'package:dio/dio.dart';

import '../../../models/competition_action_draft.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import '../../../services/async_action_guard.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class DraftAddCompetitionToPlanInput {
  const DraftAddCompetitionToPlanInput(this.eventId);

  final int eventId;
}

class CompetitionPlanActionException implements Exception {
  const CompetitionPlanActionException(this.code, this.message, {this.draft});

  final String code;
  final String message;
  final CompetitionPlanActionDraft? draft;

  @override
  String toString() => message;
}

abstract interface class CompetitionPlanActionSource {
  Future<CompetitionPlanActionDraft> create(int eventId);

  Future<CompetitionPlanActionDraft> confirm(int draftId);

  Future<CompetitionPlanActionDraft> cancel(int draftId);
}

class DioCompetitionPlanActionSource implements CompetitionPlanActionSource {
  DioCompetitionPlanActionSource(this._dio);

  final Dio _dio;
  final AsyncActionGuard _actionGuard = AsyncActionGuard();

  @override
  Future<CompetitionPlanActionDraft> create(int eventId) async {
    final response = await _dio.post<dynamic>(
      '/ai/action-drafts/competition-plan',
      data: <String, dynamic>{'event_id': eventId},
    );
    return _parse(response.data);
  }

  @override
  Future<CompetitionPlanActionDraft> confirm(int draftId) =>
      _actionGuard.run<CompetitionPlanActionDraft>(
        'competition-confirm:$draftId',
        () async {
          try {
            final response = await _dio.post<dynamic>(
              '/user/ai-action-drafts/$draftId/confirm',
              data: const <String, dynamic>{},
              options: Options(headers: <String, dynamic>{
                'Idempotency-Key': 'agent-competition-confirm-$draftId',
              }),
            );
            return _parse(response.data);
          } on DioException catch (error) {
            throw _actionError(error);
          }
        },
      );

  @override
  Future<CompetitionPlanActionDraft> cancel(int draftId) =>
      _actionGuard.run<CompetitionPlanActionDraft>(
        'competition-cancel:$draftId',
        () async {
          final response = await _dio.post<dynamic>(
            '/user/ai-action-drafts/$draftId/cancel',
            data: const <String, dynamic>{},
            options: Options(headers: <String, dynamic>{
              'Idempotency-Key': 'agent-competition-cancel-$draftId',
            }),
          );
          return _parse(response.data);
        },
      );

  CompetitionPlanActionDraft _parse(Object? value) {
    if (value is! Map) throw const FormatException('竞赛操作草稿响应格式错误');
    final data = Map<String, dynamic>.from(value);
    final draft = data['draft'];
    return CompetitionPlanActionDraft.fromJson(
      Map<String, dynamic>.from(draft is Map ? draft : data),
    );
  }

  CompetitionPlanActionException _actionError(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      CompetitionPlanActionDraft? draft;
      if (map['draft'] is Map) {
        try {
          draft = CompetitionPlanActionDraft.fromJson(
            Map<String, dynamic>.from(map['draft'] as Map),
          );
        } catch (_) {
          draft = null;
        }
      }
      return CompetitionPlanActionException(
        '${map['code'] ?? 'action_draft_failed'}',
        '${map['message'] ?? '竞赛计划操作未完成'}',
        draft: draft,
      );
    }
    return const CompetitionPlanActionException(
      'action_draft_failed',
      '竞赛计划操作未完成，请稍后重试',
    );
  }
}

class DraftAddCompetitionToPlanSkill
    implements
        PersonalSkill<DraftAddCompetitionToPlanInput,
            CompetitionPlanActionDraft> {
  DraftAddCompetitionToPlanSkill(this._source);

  static const String skillId = 'draft_add_competition_to_plan';

  final CompetitionPlanActionSource _source;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.studentProfile};

  @override
  Future<SkillResult<CompetitionPlanActionDraft>> execute(
    DraftAddCompetitionToPlanInput input,
    SkillExecutionContext context,
  ) async {
    try {
      final draft = await _source.create(input.eventId);
      return SkillResult<CompetitionPlanActionDraft>(
        value: draft,
        status: SkillStatus.success,
        evidence: <SkillEvidence>[
          SkillEvidence(
            source: '神理校园竞赛计划',
            scope: '服务端确定性推荐的待确认计划操作草稿',
            dataType: PersonalDataType.studentProfile,
            fetchedAt: context.now(),
          ),
        ],
        warnings: const <String>[
          '这是待确认草稿，尚未加入计划；确认时服务端会重新校验赛事状态和推荐结果',
          '不会自动报名，也不代表学校确认参赛资格或政策收益',
        ],
        containsPersonalData: true,
      );
    } on CompetitionPlanActionException catch (error) {
      return SkillResult<CompetitionPlanActionDraft>(
        value: error.draft,
        status: SkillStatus.failed,
        warnings: <String>[error.message],
        containsPersonalData: false,
      );
    } on DioException {
      return SkillResult<CompetitionPlanActionDraft>(
        status: SkillStatus.unavailable,
        warnings: const <String>['竞赛计划草稿服务暂不可用'],
        containsPersonalData: false,
      );
    } on FormatException {
      return SkillResult<CompetitionPlanActionDraft>(
        status: SkillStatus.failed,
        warnings: const <String>['竞赛计划草稿响应格式错误'],
        containsPersonalData: false,
      );
    }
  }
}
