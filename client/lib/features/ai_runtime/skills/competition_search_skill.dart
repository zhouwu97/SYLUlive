import 'package:dio/dio.dart';

import '../../campus_data/storage/personal_snapshot_models.dart';
import '../../../models/competition.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class CompetitionSearchInput {
  const CompetitionSearchInput({
    required this.keyword,
    this.categorySlug,
    this.limit = 10,
  });

  final String keyword;
  final String? categorySlug;
  final int limit;
}

class CompetitionSearchPage {
  CompetitionSearchPage({
    required List<CompetitionEvent> events,
    required this.total,
    required this.fetchedAt,
    this.source = 'campus_competition_api',
  }) : events = List<CompetitionEvent>.unmodifiable(events);

  final List<CompetitionEvent> events;
  final int total;
  final DateTime fetchedAt;
  final String source;
}

abstract interface class CompetitionSearchSource {
  Future<CompetitionSearchPage> search(CompetitionSearchInput input);
}

/// 复用客户端认证 Dio，仅请求公开竞赛目录，不读取任何个人状态。
class DioCompetitionSearchSource implements CompetitionSearchSource {
  DioCompetitionSearchSource(this._dio, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _clock;

  @override
  Future<CompetitionSearchPage> search(CompetitionSearchInput input) async {
    final response = await _dio.get(
      '/competitions/events',
      queryParameters: <String, dynamic>{
        if (input.keyword.trim().isNotEmpty) 'keyword': input.keyword.trim(),
        if (input.categorySlug?.trim().isNotEmpty == true)
          'category_slug': input.categorySlug!.trim(),
        'page': 1,
        'page_size': input.limit,
      },
    );
    if (response.data is! Map) {
      throw const FormatException('公开竞赛响应格式错误');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('公开竞赛列表格式错误');
    }
    final events = rawItems
        .whereType<Map>()
        .map(
          (item) => CompetitionEvent.fromJson(Map<String, dynamic>.from(item)),
        )
        .take(input.limit)
        .toList(growable: false);
    return CompetitionSearchPage(
      events: events,
      total: (data['total'] as num?)?.toInt() ?? events.length,
      fetchedAt: _clock().toUtc(),
    );
  }
}

class CompetitionSearchItem {
  CompetitionSearchItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.category,
    required this.schoolRecognitionStatus,
    required this.registrationTimeText,
    required this.officialUrl,
    required List<String> tags,
  }) : tags = List<String>.unmodifiable(tags);

  final int id;
  final String title;
  final String summary;
  final String category;
  final String schoolRecognitionStatus;
  final String registrationTimeText;
  final String officialUrl;
  final List<String> tags;
}

class CompetitionSearchOutput {
  CompetitionSearchOutput({
    required this.keyword,
    required List<CompetitionSearchItem> items,
    required this.total,
    required this.dataUpdatedAt,
  }) : items = List<CompetitionSearchItem>.unmodifiable(items);

  final String keyword;
  final List<CompetitionSearchItem> items;
  final int total;
  final DateTime dataUpdatedAt;
}

class CompetitionSearchSkill
    implements PersonalSkill<CompetitionSearchInput, CompetitionSearchOutput> {
  CompetitionSearchSkill(this._source);

  static const String skillId = 'campus.competition.search';
  static const int maximumKeywordLength = 100;
  static const int maximumResultCount = 20;

  final CompetitionSearchSource _source;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.publicData;

  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{};

  @override
  Future<SkillResult<CompetitionSearchOutput>> execute(
    CompetitionSearchInput input,
    SkillExecutionContext context,
  ) async {
    final keyword = input.keyword.trim();
    final category = input.categorySlug?.trim() ?? '';
    if (keyword.isEmpty ||
        keyword.length > maximumKeywordLength ||
        input.limit < 1 ||
        input.limit > maximumResultCount ||
        category.length > 64) {
      return SkillResult<CompetitionSearchOutput>(
        status: SkillStatus.invalidInput,
        containsPersonalData: false,
        warnings: const <String>['检索词或结果数量超出允许范围'],
      );
    }

    try {
      final page = await _source.search(
        CompetitionSearchInput(
          keyword: keyword,
          categorySlug: category.isEmpty ? null : category,
          limit: input.limit,
        ),
      );
      final events = page.events.take(input.limit);
      final items = events
          .map(
            (event) => CompetitionSearchItem(
              id: event.id,
              title: event.title,
              summary: event.summary,
              category: event.primaryCategory?.name ?? '',
              schoolRecognitionStatus: event.schoolRecognitionStatus,
              registrationTimeText: event.displayTimeText,
              officialUrl: event.officialUrl,
              tags: event.tags.take(8).toList(growable: false),
            ),
          )
          .toList(growable: false);
      return SkillResult<CompetitionSearchOutput>(
        value: CompetitionSearchOutput(
          keyword: keyword,
          items: items,
          total: page.total,
          dataUpdatedAt: page.fetchedAt,
        ),
        status: SkillStatus.success,
        evidence: <SkillEvidence>[
          SkillEvidence(
            source: page.source,
            scope: '公开竞赛目录检索',
            fetchedAt: page.fetchedAt,
          ),
        ],
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

  SkillResult<CompetitionSearchOutput> _unavailable() =>
      SkillResult<CompetitionSearchOutput>(
        status: SkillStatus.unavailable,
        containsPersonalData: false,
        warnings: const <String>['公开竞赛服务暂不可用'],
      );
}
