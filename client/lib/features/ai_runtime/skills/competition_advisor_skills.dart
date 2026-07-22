import 'package:dio/dio.dart';

import '../../../models/competition_capability_profile.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class EmptyCompetitionAdvisorInput {
  const EmptyCompetitionAdvisorInput();
}

class CompetitionCapabilityAccessDeniedException implements Exception {
  const CompetitionCapabilityAccessDeniedException();
}

abstract interface class CompetitionCapabilityProfileSource {
  Future<CompetitionCapabilityProfile> load();
}

class DioCompetitionCapabilityProfileSource
    implements CompetitionCapabilityProfileSource {
  DioCompetitionCapabilityProfileSource(this._dio);

  final Dio _dio;

  @override
  Future<CompetitionCapabilityProfile> load() async {
    try {
      final response = await _dio.get<dynamic>(
        '/ai/tools/competition-capability-profile',
      );
      if (response.data is! Map) {
        throw const FormatException('竞赛能力画像响应格式错误');
      }
      return CompetitionCapabilityProfile.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 403) {
        throw const CompetitionCapabilityAccessDeniedException();
      }
      rethrow;
    }
  }
}

class CompetitionCapabilityProfileSkill
    implements
        PersonalSkill<EmptyCompetitionAdvisorInput,
            CompetitionCapabilityProfile> {
  CompetitionCapabilityProfileSkill(this._source);

  static const String skillId = 'get_competition_capability_profile';

  final CompetitionCapabilityProfileSource _source;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{
        PersonalDataType.studentProfile,
      };

  @override
  Future<SkillResult<CompetitionCapabilityProfile>> execute(
    EmptyCompetitionAdvisorInput input,
    SkillExecutionContext context,
  ) async {
    try {
      final profile = await _source.load();
      return SkillResult<CompetitionCapabilityProfile>(
        value: profile,
        status: SkillStatus.success,
        evidence: <SkillEvidence>[
          SkillEvidence(
            source: '神理校园竞赛档案',
            scope: '用户授权的竞赛目标和结构化能力画像',
            dataType: PersonalDataType.studentProfile,
            fetchedAt: context.now(),
          ),
        ],
        warnings: const <String>['已核验与本人填写经历分开统计，不代表学校或教务认证'],
        containsPersonalData: true,
      );
    } on CompetitionCapabilityAccessDeniedException {
      return SkillResult<CompetitionCapabilityProfile>(
        status: SkillStatus.denied,
        warnings: const <String>['用户尚未授权读取竞赛能力画像'],
        containsPersonalData: false,
      );
    } on DioException {
      return _unavailable();
    } on FormatException {
      return _unavailable();
    } catch (_) {
      return _unavailable();
    }
  }

  SkillResult<CompetitionCapabilityProfile> _unavailable() =>
      SkillResult<CompetitionCapabilityProfile>(
        status: SkillStatus.unavailable,
        warnings: const <String>['竞赛能力画像服务暂不可用'],
        containsPersonalData: false,
      );
}
