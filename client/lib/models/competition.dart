class CompetitionCategory {
  final int id;
  final String name;
  final String slug;
  final String icon;

  CompetitionCategory({
    required this.id,
    required this.name,
    required this.slug,
    this.icon = '',
  });

  factory CompetitionCategory.fromJson(Map<String, dynamic> json) {
    return CompetitionCategory(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      slug: json['slug'] ?? '',
      icon: json['icon'] ?? '',
    );
  }
}

class CompetitionCatalogPackage {
  final int id;
  final String datasetVersion;
  final int revision;
  final String packageHash;
  final String lifecycleStatus;
  final String publishStatus;
  final bool productionLoadAllowed;
  final int itemCount;
  final String validationStatus;
  final String sourceFilename;
  final bool isActive;
  final int? previousPackageId;

  const CompetitionCatalogPackage({
    required this.id,
    required this.datasetVersion,
    required this.revision,
    required this.packageHash,
    required this.lifecycleStatus,
    required this.publishStatus,
    required this.productionLoadAllowed,
    required this.itemCount,
    required this.validationStatus,
    required this.sourceFilename,
    required this.isActive,
    this.previousPackageId,
  });

  factory CompetitionCatalogPackage.fromJson(Map<String, dynamic> json) {
    return CompetitionCatalogPackage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      datasetVersion: '${json['dataset_version'] ?? ''}',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      packageHash: '${json['package_hash'] ?? ''}',
      lifecycleStatus: '${json['lifecycle_status'] ?? ''}',
      publishStatus: '${json['publish_status'] ?? ''}',
      productionLoadAllowed: json['production_load_allowed'] == true,
      itemCount: (json['item_count'] as num?)?.toInt() ?? 0,
      validationStatus: '${json['validation_status'] ?? ''}',
      sourceFilename: '${json['source_filename'] ?? ''}',
      isActive: json['is_active'] == true,
      previousPackageId: (json['previous_package_id'] as num?)?.toInt(),
    );
  }
}

class CompetitionAdminCatalogSummary {
  final int activeCatalog;
  final int activePublished;
  final int displayEnabled;
  final int candidateEnabled;
  final int parentRelationships;
  final int manual;
  final int canonical;
  final int superseded;
  final int resolvedDuplicates;
  final int allDatabaseRows;

  const CompetitionAdminCatalogSummary({
    this.activeCatalog = 0,
    this.activePublished = 0,
    this.displayEnabled = 0,
    this.candidateEnabled = 0,
    this.parentRelationships = 0,
    this.manual = 0,
    this.canonical = 0,
    this.superseded = 0,
    this.resolvedDuplicates = 0,
    this.allDatabaseRows = 0,
  });

  factory CompetitionAdminCatalogSummary.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    int count(String key) => (value[key] as num?)?.toInt() ?? 0;
    return CompetitionAdminCatalogSummary(
      activeCatalog: count('active_catalog'),
      activePublished: count('active_published'),
      displayEnabled: count('display_enabled'),
      candidateEnabled: count('candidate_enabled'),
      parentRelationships: count('parent_relationships'),
      manual: count('manual'),
      canonical: count('canonical'),
      superseded: count('superseded'),
      resolvedDuplicates: count('resolved_duplicates'),
      allDatabaseRows: count('all_database_rows'),
    );
  }
}

class CompetitionMatchDimensions {
  final String eligibility;
  final String major;
  final String college;
  final String grade;
  final String goal;
  final String direction;
  final String skill;
  final String role;
  final String time;
  final String training;

  const CompetitionMatchDimensions({
    this.eligibility = 'unknown',
    this.major = 'unknown',
    this.college = 'unknown',
    this.grade = 'unknown',
    this.goal = 'unknown',
    this.direction = 'unknown',
    this.skill = 'unknown',
    this.role = 'unknown',
    this.time = 'unknown',
    this.training = 'unknown',
  });

  factory CompetitionMatchDimensions.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    return CompetitionMatchDimensions(
      eligibility: '${value['eligibility'] ?? 'unknown'}',
      major: '${value['major'] ?? 'unknown'}',
      college: '${value['college'] ?? 'unknown'}',
      grade: '${value['grade'] ?? 'unknown'}',
      goal: '${value['goal'] ?? 'unknown'}',
      direction: '${value['direction'] ?? 'unknown'}',
      skill: '${value['skill'] ?? 'unknown'}',
      role: '${value['role'] ?? 'unknown'}',
      time: '${value['time'] ?? 'unknown'}',
      training: '${value['training'] ?? 'unknown'}',
    );
  }
}

class CompetitionRecommendationGates {
  final bool candidatePoolAllowed;
  final bool personalizedRankingAllowed;
  final bool strongRecommendationEligible;
  final String permissionLevel;
  final String aiMode;

  const CompetitionRecommendationGates({
    this.candidatePoolAllowed = false,
    this.personalizedRankingAllowed = false,
    this.strongRecommendationEligible = false,
    this.permissionLevel = 'low',
    this.aiMode = 'disabled',
  });

  factory CompetitionRecommendationGates.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    return CompetitionRecommendationGates(
      candidatePoolAllowed: value['candidate_pool_allowed'] == true,
      personalizedRankingAllowed: value['personalized_ranking_allowed'] == true,
      strongRecommendationEligible:
          value['strong_recommendation_eligible'] == true,
      permissionLevel: '${value['recommendation_permission_level'] ?? 'low'}',
      aiMode: '${value['ai_mode'] ?? 'disabled'}',
    );
  }
}

class CompetitionEvent {
  final int id;
  final String competitionId;
  final int? catalogPackageId;
  final String parentCompetitionId;
  final int? parentEventId;
  final String title;
  final String summary;
  final CompetitionCategory? primaryCategory;
  final List<String> tags;
  final String competitionLevel;
  final String schoolRecognitionStatus;
  final String schoolRecognitionGrade;
  final String competitionRating;
  final String recommendationLevel;
  final int importanceScore;
  final String recommendationReason;
  final double? manualRating;
  final String evidenceStatus;
  final bool strongRecommendationReady;
  final String organizer;
  final String hostUnit;
  final String targetAudience;
  final List<String> eligibleEntryYears;
  final List<String> eligibleColleges;
  final List<String> eligibleMajors;
  final String fitLevel;
  final List<String> fitReasons;
  final int? personalizedScore;
  final String recommendationTier;
  final String participationType;
  final int? teamSizeMin;
  final int? teamSizeMax;
  final String registrationTimeText;
  final String eventTimeText;
  final DateTime? registrationStart;
  final DateTime? registrationEnd;
  final DateTime? eventStart;
  final DateTime? eventEnd;
  final String timePrecision;
  final String timeStatus;
  final String timeNote;
  final int sortMonth;
  final bool hasTimeStatus;
  final String sourceChannel;
  final String location;
  final bool isOnline;
  final String officialUrl;
  final String noticeUrl;
  final List<String> attachmentUrls;
  final String sourceNote;
  final String description;
  final String status;
  final DateTime? updatedAt;
  final String groupKey;
  final int ruleOrder;
  final bool hasPendingInformation;
  final CompetitionMatchDimensions matchDimensions;
  final String coreReason;
  final List<String> cautions;
  final List<String> questionsToConfirm;
  final String evidenceSubgrade;
  final String datasetVersion;
  final String recordHash;
  final String managementSource;
  final bool mutable;
  final bool searchDisplayAllowed;
  final bool candidatePoolAllowed;
  final bool personalizedRankingAllowed;
  final bool strongRecommendationEligible;
  final String recommendationPermissionLevel;
  final String aiMode;
  final CompetitionRecommendationGates gates;

  CompetitionEvent({
    required this.id,
    required this.title,
    this.competitionId = '',
    this.catalogPackageId,
    this.parentCompetitionId = '',
    this.parentEventId,
    this.summary = '',
    this.primaryCategory,
    this.tags = const [],
    this.competitionLevel = '',
    this.schoolRecognitionStatus = '',
    this.schoolRecognitionGrade = '',
    this.competitionRating = '',
    this.recommendationLevel = '',
    this.importanceScore = 0,
    this.recommendationReason = '',
    this.manualRating,
    this.evidenceStatus = 'pending',
    this.strongRecommendationReady = false,
    this.organizer = '',
    this.hostUnit = '',
    this.targetAudience = '',
    this.eligibleEntryYears = const [],
    this.eligibleColleges = const [],
    this.eligibleMajors = const [],
    this.fitLevel = '',
    this.fitReasons = const [],
    this.personalizedScore,
    this.recommendationTier = '',
    this.participationType = '',
    this.teamSizeMin,
    this.teamSizeMax,
    this.registrationTimeText = '',
    this.eventTimeText = '',
    this.registrationStart,
    this.registrationEnd,
    this.eventStart,
    this.eventEnd,
    this.timePrecision = 'unknown',
    this.timeStatus = 'pending',
    this.timeNote = '',
    this.sortMonth = 0,
    this.hasTimeStatus = false,
    this.sourceChannel = '',
    this.location = '',
    this.isOnline = false,
    this.officialUrl = '',
    this.noticeUrl = '',
    this.attachmentUrls = const [],
    this.sourceNote = '',
    this.description = '',
    this.status = 'published',
    this.updatedAt,
    this.groupKey = '',
    this.ruleOrder = 0,
    this.hasPendingInformation = false,
    this.matchDimensions = const CompetitionMatchDimensions(),
    this.coreReason = '',
    this.cautions = const [],
    this.questionsToConfirm = const [],
    this.evidenceSubgrade = '',
    this.datasetVersion = '',
    this.recordHash = '',
    this.managementSource = '',
    this.mutable = true,
    this.searchDisplayAllowed = false,
    this.candidatePoolAllowed = false,
    this.personalizedRankingAllowed = false,
    this.strongRecommendationEligible = false,
    this.recommendationPermissionLevel = 'low',
    this.aiMode = 'disabled',
    this.gates = const CompetitionRecommendationGates(),
  });

  factory CompetitionEvent.fromJson(Map<String, dynamic> json) {
    final rawTimeStatus = json['time_status'];
    final rawCompetitionRating = '${json['competition_rating'] ?? ''}'.trim();
    final rawRecommendationLevel =
        '${json['recommendation_level'] ?? ''}'.trim();
    final competitionRating = rawCompetitionRating.isNotEmpty
        ? rawCompetitionRating
        : rawRecommendationLevel;
    final recommendationLevel = rawRecommendationLevel.isNotEmpty
        ? rawRecommendationLevel
        : rawCompetitionRating;
    return CompetitionEvent(
      id: json['id'] ?? 0,
      competitionId: json['competition_id'] ?? '',
      catalogPackageId: (json['catalog_package_id'] as num?)?.toInt(),
      parentCompetitionId: json['parent_competition_id'] ?? '',
      parentEventId: (json['parent_event_id'] as num?)?.toInt(),
      title: json['title'] ?? '',
      summary: json['summary'] ?? '',
      primaryCategory: json['primary_category'] != null
          ? CompetitionCategory.fromJson(json['primary_category'])
          : null,
      tags: _stringList(json['tags']),
      competitionLevel: json['competition_level'] ?? '',
      schoolRecognitionStatus: json['school_recognition_status'] ?? '',
      schoolRecognitionGrade: json['school_recognition_grade'] ?? '',
      competitionRating: competitionRating,
      recommendationLevel: recommendationLevel,
      importanceScore: json['importance_score'] ?? 0,
      recommendationReason: json['recommendation_reason'] ?? '',
      manualRating: (json['manual_rating'] as num?)?.toDouble(),
      evidenceStatus: json['evidence_status'] ?? 'pending',
      strongRecommendationReady: json['strong_recommendation_ready'] == true,
      organizer: json['organizer'] ?? '',
      hostUnit: json['host_unit'] ?? '',
      targetAudience: json['target_audience'] ?? '',
      eligibleEntryYears: _stringList(json['eligible_entry_years']),
      eligibleColleges: _stringList(json['eligible_colleges']),
      eligibleMajors: _stringList(json['eligible_majors']),
      fitLevel: json['fit_level'] ?? '',
      fitReasons: _stringList(json['fit_reasons']),
      personalizedScore: (json['personalized_score'] as num?)?.toInt(),
      recommendationTier: json['recommendation_tier'] ?? '',
      participationType: json['participation_type'] ?? '',
      teamSizeMin: (json['team_size_min'] as num?)?.toInt(),
      teamSizeMax: (json['team_size_max'] as num?)?.toInt(),
      registrationTimeText: json['registration_time_text'] ?? '',
      eventTimeText: json['event_time_text'] ?? '',
      registrationStart: DateTime.tryParse(json['registration_start'] ?? ''),
      registrationEnd: DateTime.tryParse(json['registration_end'] ?? ''),
      eventStart: DateTime.tryParse(json['event_start'] ?? ''),
      eventEnd: DateTime.tryParse(json['event_end'] ?? ''),
      timePrecision: json['time_precision'] ?? 'unknown',
      timeStatus: rawTimeStatus ?? 'pending',
      timeNote: json['time_note'] ?? '',
      sortMonth: (json['sort_month'] as num?)?.toInt() ?? 0,
      hasTimeStatus: json.containsKey('time_status') &&
          '${rawTimeStatus ?? ''}'.trim().isNotEmpty,
      sourceChannel: json['source_channel'] ?? '',
      location: json['location'] ?? '',
      isOnline: json['is_online'] == true,
      officialUrl: json['official_url'] ?? '',
      noticeUrl: json['notice_url'] ?? '',
      attachmentUrls: _stringList(json['attachment_urls']),
      sourceNote: json['source_note'] ?? '',
      description: json['description'] ?? '',
      status: json['status'] ?? 'published',
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
      groupKey: json['group_key'] ?? '',
      ruleOrder: (json['rule_order'] as num?)?.toInt() ?? 0,
      hasPendingInformation: json['has_pending_information'] == true,
      matchDimensions: CompetitionMatchDimensions.fromJson(
        json['match_dimensions'] is Map
            ? Map<String, dynamic>.from(json['match_dimensions'] as Map)
            : null,
      ),
      coreReason: json['core_reason'] ?? '',
      cautions: _stringList(json['cautions']),
      questionsToConfirm: _stringList(json['questions_to_confirm']),
      evidenceSubgrade: json['evidence_subgrade'] ?? '',
      datasetVersion: json['dataset_version'] ?? '',
      recordHash: json['record_hash'] ?? '',
      managementSource: json['management_source'] ?? '',
      mutable: json.containsKey('mutable') ? json['mutable'] == true : true,
      searchDisplayAllowed: json['search_display_allowed'] == true,
      candidatePoolAllowed: json['candidate_pool_allowed'] == true,
      personalizedRankingAllowed: json['personalized_ranking_allowed'] == true,
      strongRecommendationEligible:
          json['strong_recommendation_eligible'] == true,
      recommendationPermissionLevel:
          json['recommendation_permission_level'] ?? 'low',
      aiMode: json['ai_mode'] ?? 'disabled',
      gates: CompetitionRecommendationGates.fromJson(
        json['gates'] is Map
            ? Map<String, dynamic>.from(json['gates'] as Map)
            : null,
      ),
    );
  }

  bool get hasExactDeadline => registrationEnd != null;

  bool get isTimeConfirmed => timeStatus == 'confirmed';

  String get timeStatusLabel {
    switch (timeStatus) {
      case 'confirmed':
        return '已确认';
      case 'estimated':
        return '预计时间';
      case 'historical':
        return '往年参考';
      default:
        return '时间待公布';
    }
  }

  String get timePrecisionLabel {
    switch (timePrecision) {
      case 'exact':
        return '精确到日';
      case 'month':
        return '按月份';
      case 'month_range':
        return '月份范围';
      case 'quarter':
        return '季度';
      case 'half_year':
        return '半年';
      case 'season':
        return '季节';
      default:
        return '不确定';
    }
  }

  String get displayTimeText {
    if (registrationEnd != null) {
      final dt = registrationEnd!;
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    if (registrationTimeText.trim().isNotEmpty) {
      return registrationTimeText.trim();
    }
    if (eventTimeText.trim().isNotEmpty) {
      return eventTimeText.trim();
    }
    if (sortMonth >= 1 && sortMonth <= 12) {
      return '$sortMonth 月左右';
    }
    return '时间待公布';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (competitionId.isNotEmpty) 'competition_id': competitionId,
      if (catalogPackageId != null) 'catalog_package_id': catalogPackageId,
      if (parentCompetitionId.isNotEmpty)
        'parent_competition_id': parentCompetitionId,
      if (parentEventId != null) 'parent_event_id': parentEventId,
      'title': title,
      'summary': summary,
      if (primaryCategory != null)
        'primary_category': {
          'id': primaryCategory!.id,
          'name': primaryCategory!.name,
          'slug': primaryCategory!.slug,
          'icon': primaryCategory!.icon,
        },
      if (primaryCategory != null) 'primary_category_id': primaryCategory!.id,
      if (primaryCategory != null)
        'primary_category_slug': primaryCategory!.slug,
      'tags': tags,
      'competition_level': competitionLevel,
      'school_recognition_status': schoolRecognitionStatus,
      'school_recognition_grade': schoolRecognitionGrade,
      'competition_rating': competitionRating,
      'recommendation_level': recommendationLevel,
      'importance_score': importanceScore,
      'recommendation_reason': recommendationReason,
      'organizer': organizer,
      'host_unit': hostUnit,
      'target_audience': targetAudience,
      'eligible_entry_years': eligibleEntryYears,
      'eligible_colleges': eligibleColleges,
      'eligible_majors': eligibleMajors,
      if (fitLevel.isNotEmpty) 'fit_level': fitLevel,
      if (fitReasons.isNotEmpty) 'fit_reasons': fitReasons,
      if (personalizedScore != null) 'personalized_score': personalizedScore,
      if (recommendationTier.isNotEmpty)
        'recommendation_tier': recommendationTier,
      'participation_type': participationType,
      'team_size_min': teamSizeMin,
      'team_size_max': teamSizeMax,
      'registration_time_text': registrationTimeText,
      'event_time_text': eventTimeText,
      if (registrationStart != null)
        'registration_start': registrationStart!.toIso8601String(),
      if (registrationEnd != null)
        'registration_end': registrationEnd!.toIso8601String(),
      if (eventStart != null) 'event_start': eventStart!.toIso8601String(),
      if (eventEnd != null) 'event_end': eventEnd!.toIso8601String(),
      'time_precision': timePrecision,
      'time_status': timeStatus,
      'time_note': timeNote,
      'sort_month': sortMonth,
      'source_channel': sourceChannel,
      'location': location,
      'is_online': isOnline,
      'official_url': officialUrl,
      'notice_url': noticeUrl,
      'attachment_urls': attachmentUrls,
      'description': description,
      'source_note': sourceNote,
      'status': status,
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      if (groupKey.isNotEmpty) 'group_key': groupKey,
      if (ruleOrder > 0) 'rule_order': ruleOrder,
      if (hasPendingInformation)
        'has_pending_information': hasPendingInformation,
      'match_dimensions': {
        'eligibility': matchDimensions.eligibility,
        'major': matchDimensions.major,
        'college': matchDimensions.college,
        'grade': matchDimensions.grade,
        'goal': matchDimensions.goal,
        'direction': matchDimensions.direction,
        'skill': matchDimensions.skill,
        'role': matchDimensions.role,
        'time': matchDimensions.time,
        'training': matchDimensions.training,
      },
      if (coreReason.isNotEmpty) 'core_reason': coreReason,
      if (cautions.isNotEmpty) 'cautions': cautions,
      if (questionsToConfirm.isNotEmpty)
        'questions_to_confirm': questionsToConfirm,
      if (evidenceSubgrade.isNotEmpty) 'evidence_subgrade': evidenceSubgrade,
      if (datasetVersion.isNotEmpty) 'dataset_version': datasetVersion,
      if (recordHash.isNotEmpty) 'record_hash': recordHash,
      if (managementSource.isNotEmpty) 'management_source': managementSource,
      'mutable': mutable,
      'search_display_allowed': searchDisplayAllowed,
      'candidate_pool_allowed': candidatePoolAllowed,
      'personalized_ranking_allowed': personalizedRankingAllowed,
      'strong_recommendation_eligible': strongRecommendationEligible,
      'recommendation_permission_level': recommendationPermissionLevel,
      'ai_mode': aiMode,
      if (datasetVersion.isNotEmpty) 'dataset_version': datasetVersion,
      if (recordHash.isNotEmpty) 'record_hash': recordHash,
      'gates': {
        'candidate_pool_allowed': gates.candidatePoolAllowed,
        'personalized_ranking_allowed': gates.personalizedRankingAllowed,
        'strong_recommendation_eligible': gates.strongRecommendationEligible,
        'recommendation_permission_level': gates.permissionLevel,
        'ai_mode': gates.aiMode,
      },
    };
  }
}

class CompetitionCandidateGroup {
  final String key;
  final String label;
  final int count;
  final List<CompetitionEvent> items;

  const CompetitionCandidateGroup({
    required this.key,
    required this.label,
    required this.count,
    required this.items,
  });

  factory CompetitionCandidateGroup.fromJson(Map<String, dynamic> json) {
    return CompetitionCandidateGroup(
      key: '${json['key'] ?? ''}',
      label: '${json['label'] ?? ''}',
      count: (json['count'] as num?)?.toInt() ?? 0,
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (item) =>
                CompetitionEvent.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
    );
  }
}

class CompetitionCatalogSummary {
  final String datasetVersion;
  final String packageHash;
  final String mode;
  final bool personalizedRankingAllowed;

  const CompetitionCatalogSummary({
    this.datasetVersion = 'legacy',
    this.packageHash = '',
    this.mode = 'candidate_explanation',
    this.personalizedRankingAllowed = false,
  });

  factory CompetitionCatalogSummary.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    return CompetitionCatalogSummary(
      datasetVersion: '${value['dataset_version'] ?? 'legacy'}',
      packageHash: '${value['package_hash'] ?? ''}',
      mode: '${value['mode'] ?? 'candidate_explanation'}',
      personalizedRankingAllowed: value['personalized_ranking_allowed'] == true,
    );
  }
}

List<String> _stringList(dynamic raw) {
  if (raw is List) {
    return raw
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return const [];
}
