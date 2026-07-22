import 'package:dio/dio.dart';

import '../../../models/competition_capability_profile.dart';
import '../../../models/competition.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class EmptyCompetitionAdvisorInput {
  const EmptyCompetitionAdvisorInput();
}

const Set<String> competitionAdvisorAccountIndependentSkillIds = <String>{
  CompetitionCapabilityProfileSkill.skillId,
  ExplainCompetitionMatchesSkill.skillId,
};

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

class CompetitionMatchExplanationItem {
  CompetitionMatchExplanationItem.fromEvent(CompetitionEvent event)
      : id = event.id,
        title = event.title,
        personalizedScore = event.personalizedScore,
        recommendationTier = event.recommendationTier,
        fitReasons = List<String>.unmodifiable(event.fitReasons),
        competitionRating = event.competitionRating,
        manualRating = event.manualRating,
        schoolRecognitionStatus = event.schoolRecognitionStatus,
        schoolRecognitionGrade = event.schoolRecognitionGrade,
        timeStatus = event.timeStatus,
        registrationTimeText = event.registrationTimeText;

  final int id;
  final String title;
  final int? personalizedScore;
  final String recommendationTier;
  final List<String> fitReasons;
  final String competitionRating;
  final double? manualRating;
  final String schoolRecognitionStatus;
  final String schoolRecognitionGrade;
  final String timeStatus;
  final String registrationTimeText;
}

class CompetitionMatchExplanationPage {
  CompetitionMatchExplanationPage({
    required this.profileReady,
    required this.preferenceConfigured,
    required List<CompetitionMatchExplanationItem> items,
    required this.total,
    required this.fetchedAt,
  }) : items = List<CompetitionMatchExplanationItem>.unmodifiable(items);

  final bool profileReady;
  final bool preferenceConfigured;
  final List<CompetitionMatchExplanationItem> items;
  final int total;
  final DateTime fetchedAt;
}

abstract interface class CompetitionMatchExplanationSource {
  Future<CompetitionMatchExplanationPage> load();
}

class DioCompetitionMatchExplanationSource
    implements CompetitionMatchExplanationSource {
  DioCompetitionMatchExplanationSource(this._dio, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _clock;

  @override
  Future<CompetitionMatchExplanationPage> load() async {
    final response = await _dio.get<dynamic>(
      '/user/competitions/fit',
      queryParameters: const <String, dynamic>{'page': 1, 'page_size': 20},
    );
    if (response.data is! Map) {
      throw const FormatException('个性化竞赛响应格式错误');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('个性化竞赛列表格式错误');
    }
    final items = rawItems
        .whereType<Map>()
        .map(
          (item) => CompetitionMatchExplanationItem.fromEvent(
            CompetitionEvent.fromJson(Map<String, dynamic>.from(item)),
          ),
        )
        .take(20)
        .toList(growable: false);
    return CompetitionMatchExplanationPage(
      profileReady: data['profile_ready'] == true,
      preferenceConfigured: data['preference_configured'] == true,
      items: items,
      total: (data['total'] as num?)?.toInt() ?? items.length,
      fetchedAt: _clock().toUtc(),
    );
  }
}

class ExplainCompetitionMatchesSkill
    implements
        PersonalSkill<EmptyCompetitionAdvisorInput,
            CompetitionMatchExplanationPage> {
  ExplainCompetitionMatchesSkill(this._source);

  static const String skillId = 'explain_competition_matches';

  final CompetitionMatchExplanationSource _source;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.studentProfile};

  @override
  Future<SkillResult<CompetitionMatchExplanationPage>> execute(
    EmptyCompetitionAdvisorInput input,
    SkillExecutionContext context,
  ) async {
    try {
      final page = await _source.load();
      final warnings = <String>[
        '结果沿用平台确定性排序，AI 只负责解释，不重新评分或调整顺序',
        '赛事认定、报名资格及政策收益须以学校和主办方最新正式文件为准',
        if (!page.profileReady) '基础画像尚未就绪，当前无法生成个性化赛事结果',
        if (page.profileReady && !page.preferenceConfigured)
          '尚未设置竞赛偏好，当前结果不包含目标和投入时间的个性化权重',
      ];
      return SkillResult<CompetitionMatchExplanationPage>(
        value: page,
        status: page.profileReady ? SkillStatus.success : SkillStatus.partial,
        evidence: <SkillEvidence>[
          SkillEvidence(
            source: '神理校园确定性竞赛推荐',
            scope: '服务端现有适合我排序及其评分、理由、认定和报名时间状态',
            dataType: PersonalDataType.studentProfile,
            fetchedAt: page.fetchedAt,
          ),
        ],
        warnings: warnings,
        containsPersonalData: true,
      );
    } on DioException {
      return _unavailable();
    } on FormatException {
      return _unavailable();
    } catch (_) {
      return _unavailable();
    }
  }

  SkillResult<CompetitionMatchExplanationPage> _unavailable() =>
      SkillResult<CompetitionMatchExplanationPage>(
        status: SkillStatus.unavailable,
        warnings: const <String>['个性化竞赛结果服务暂不可用'],
        containsPersonalData: false,
      );
}
