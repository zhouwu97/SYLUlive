/// 治理候选置信度
enum GovernanceConfidence {
  high,
  suspected,
  hint;

  static GovernanceConfidence fromString(String? val) {
    switch (val) {
      case 'high':
        return GovernanceConfidence.high;
      case 'suspected':
        return GovernanceConfidence.suspected;
      case 'hint':
      default:
        return GovernanceConfidence.hint;
    }
  }

  String get label {
    switch (this) {
      case GovernanceConfidence.high:
        return '高置信';
      case GovernanceConfidence.suspected:
        return '疑似重复';
      case GovernanceConfidence.hint:
        return '仅作提示';
    }
  }
}

/// 治理教师项视图
class TeacherGovernanceTeacherItem {
  final int id;
  final String name;
  final String course;
  final int? subjectId;
  final String subjectName;
  final bool subjectVerified;
  final bool verified;
  final String canonicalSource;
  final int ratingCount;
  final int pendingCount;
  final int aliasCount;
  final int? mergedIntoId;
  final DateTime? createdAt;

  const TeacherGovernanceTeacherItem({
    required this.id,
    required this.name,
    this.course = '',
    this.subjectId,
    this.subjectName = '',
    this.subjectVerified = false,
    this.verified = false,
    this.canonicalSource = 'legacy',
    this.ratingCount = 0,
    this.pendingCount = 0,
    this.aliasCount = 0,
    this.mergedIntoId,
    this.createdAt,
  });

  bool get isMerged => mergedIntoId != null;

  factory TeacherGovernanceTeacherItem.fromJson(Map<String, dynamic> json) {
    return TeacherGovernanceTeacherItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      course: json['course']?.toString() ?? '',
      subjectId: (json['course_subject_id'] ?? json['subject_id'] as num?)?.toInt(),
      subjectName: json['course_subject_name']?.toString() ?? json['subject_name']?.toString() ?? '',
      subjectVerified: json['subject_verified'] == true,
      verified: json['verified'] == true,
      canonicalSource: json['canonical_source']?.toString() ?? 'legacy',
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      pendingCount: (json['pending_submission_count'] ?? json['pending_count'] as num?)?.toInt() ?? 0,
      aliasCount: (json['alias_count'] as num?)?.toInt() ?? 0,
      mergedIntoId: (json['merged_into_id'] as num?)?.toInt(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}

/// 重复候选分组
class TeacherGovernanceCandidateGroup {
  final String id;
  final String courseName;
  final GovernanceConfidence confidence;
  final List<String> reasons;
  final bool mergeAllowed;
  final String mergeBlockReason;
  final int suggestedKeeperId;
  final List<TeacherGovernanceTeacherItem> teachers;
  final List<String> teacherAliasSuggestions;
  final List<String> courseAliasSuggestions;

  const TeacherGovernanceCandidateGroup({
    required this.id,
    this.courseName = '',
    this.confidence = GovernanceConfidence.hint,
    this.reasons = const [],
    this.mergeAllowed = true,
    this.mergeBlockReason = '',
    this.suggestedKeeperId = 0,
    this.teachers = const [],
    this.teacherAliasSuggestions = const [],
    this.courseAliasSuggestions = const [],
  });

  factory TeacherGovernanceCandidateGroup.fromJson(Map<String, dynamic> json) {
    final rawTeachers = json['teachers'] as List? ?? [];
    final bool isMergeable;
    if (json.containsKey('mergeable')) {
      isMergeable = json['mergeable'] == true;
    } else if (json.containsKey('merge_allowed')) {
      isMergeable = json['merge_allowed'] == true;
    } else {
      isMergeable = false;
    }

    final rawReasons = json['reasons'] as List? ??
        (json['note'] != null && json['note'].toString().isNotEmpty ? [json['note']] : null) ??
        [];

    final List<String> aliasSuggestions;
    if (json['teacher_alias_suggestions'] is List) {
      aliasSuggestions = (json['teacher_alias_suggestions'] as List).map((e) => e.toString()).toList();
    } else if (json['teacher_aliases'] is List) {
      aliasSuggestions = (json['teacher_aliases'] as List)
          .map((e) => e is Map ? (e['alias']?.toString() ?? '') : e.toString())
          .where((s) => s.isNotEmpty)
          .toList();
    } else {
      aliasSuggestions = const [];
    }

    return TeacherGovernanceCandidateGroup(
      id: json['id']?.toString() ?? json['key']?.toString() ?? '',
      courseName: json['course_name']?.toString() ?? '',
      confidence: GovernanceConfidence.fromString(json['confidence']?.toString()),
      reasons: rawReasons.map((e) => e.toString()).toList(),
      mergeAllowed: isMergeable,
      mergeBlockReason: json['merge_block_reason']?.toString() ?? json['block_reason']?.toString() ?? (isMergeable ? '' : json['note']?.toString() ?? ''),
      suggestedKeeperId: (json['suggested_keeper_id'] as num?)?.toInt() ?? 0,
      teachers: rawTeachers
          .whereType<Map<String, dynamic>>()
          .map(TeacherGovernanceTeacherItem.fromJson)
          .toList(),
      teacherAliasSuggestions: aliasSuggestions,
      courseAliasSuggestions:
          (json['course_alias_suggestions'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
    );
  }
}

/// 评价冲突详情
class RatingConflictItem {
  final int userId;
  final String userNickname;
  final int winnerRatingId;
  final int winnerRatingStar;
  final DateTime? winnerCreatedAt;
  final List<Map<String, dynamic>> loserRatings;

  const RatingConflictItem({
    required this.userId,
    this.userNickname = '',
    required this.winnerRatingId,
    this.winnerRatingStar = 0,
    this.winnerCreatedAt,
    this.loserRatings = const [],
  });

  factory RatingConflictItem.fromJson(Map<String, dynamic> json) {
    return RatingConflictItem(
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      userNickname: json['user_nickname']?.toString() ?? json['nickname']?.toString() ?? '',
      winnerRatingId: (json['winner_rating_id'] as num?)?.toInt() ?? 0,
      winnerRatingStar: (json['winner_rating_star'] as num?)?.toInt() ?? 0,
      winnerCreatedAt: DateTime.tryParse(json['winner_created_at']?.toString() ?? ''),
      loserRatings: (json['loser_ratings'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
    );
  }
}

/// 合并预览结果
class GovernanceMergePreviewResult {
  final int keeperId;
  final String keeperName;
  final List<int> loserIds;
  final String snapshotToken;
  final bool mergeAllowed;
  final String blockReason;
  final List<String> conflicts;
  final int ratingsMigrated;
  final int ratingsSoftDeleted;
  final int votesMigrated;
  final int votesDeduped;
  final int submissionsMigrated;
  final int submissionsSuperseded;
  final List<RatingConflictItem> ratingConflicts;
  final List<Map<String, dynamic>> teacherAliases;
  final List<Map<String, dynamic>> courseAliases;
  final List<Map<String, dynamic>> subjectMerges;

  const GovernanceMergePreviewResult({
    required this.keeperId,
    this.keeperName = '',
    this.loserIds = const [],
    this.snapshotToken = '',
    this.mergeAllowed = true,
    this.blockReason = '',
    this.conflicts = const [],
    this.ratingsMigrated = 0,
    this.ratingsSoftDeleted = 0,
    this.votesMigrated = 0,
    this.votesDeduped = 0,
    this.submissionsMigrated = 0,
    this.submissionsSuperseded = 0,
    this.ratingConflicts = const [],
    this.teacherAliases = const [],
    this.courseAliases = const [],
    this.subjectMerges = const [],
  });

  factory GovernanceMergePreviewResult.fromJson(Map<String, dynamic> json) {
    final keeper = json['keeper'] as Map? ?? {};
    final conflictsList = (json['conflicts'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final rawRatingConflicts = (json['rating_conflict_details'] ?? json['rating_conflicts']) as List? ?? [];
    final rawLosers = (json['loser_ids'] ?? json['losers']) as List? ?? const [];
    final bool isMergeAllowed;
    if (json.containsKey('merge_allowed')) {
      isMergeAllowed = json['merge_allowed'] == true;
    } else if (json.containsKey('mergeable')) {
      isMergeAllowed = json['mergeable'] == true;
    } else {
      isMergeAllowed = true;
    }

    return GovernanceMergePreviewResult(
      keeperId: (keeper['id'] as num?)?.toInt() ?? (json['keeper_id'] as num?)?.toInt() ?? 0,
      keeperName: keeper['name']?.toString() ?? json['keeper_name']?.toString() ?? '',
      loserIds: rawLosers.map((e) => (e as num).toInt()).toList(),
      snapshotToken: json['snapshot_token']?.toString() ?? '',
      mergeAllowed: isMergeAllowed,
      blockReason: json['block_reason']?.toString() ?? json['merge_block_reason']?.toString() ?? '',
      conflicts: conflictsList,
      ratingsMigrated: (json['ratings_migrated'] as num?)?.toInt() ?? 0,
      ratingsSoftDeleted: (json['ratings_soft_deleted'] as num?)?.toInt() ?? 0,
      votesMigrated: (json['votes_migrated'] as num?)?.toInt() ?? 0,
      votesDeduped: (json['votes_deduped'] ?? json['vote_conflicts_deduped'] as num?)?.toInt() ?? 0,
      submissionsMigrated: (json['submissions_migrated'] as num?)?.toInt() ?? 0,
      submissionsSuperseded: (json['submissions_superseded'] as num?)?.toInt() ?? 0,
      ratingConflicts: rawRatingConflicts
          .whereType<Map<String, dynamic>>()
          .map(RatingConflictItem.fromJson)
          .toList(),
      teacherAliases: (json['teacher_aliases'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      courseAliases: (json['course_aliases'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      subjectMerges: (json['subject_merges'] ?? json['course_merges'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
    );
  }
}

/// 别名项（教师或课程别名）
class GovernanceAliasItem {
  final int id;
  final String alias;
  final String normalizedAlias;
  final String type; // "teacher" | "course"
  final int targetId;
  final String targetName;
  final int? subjectId;
  final String subjectName;
  final String source;
  final int? createdBy;
  final String creatorName;
  final DateTime? createdAt;

  const GovernanceAliasItem({
    required this.id,
    required this.alias,
    this.normalizedAlias = '',
    this.type = 'teacher',
    required this.targetId,
    this.targetName = '',
    this.subjectId,
    this.subjectName = '',
    this.source = 'admin',
    this.createdBy,
    this.creatorName = '',
    this.createdAt,
  });

  factory GovernanceAliasItem.fromJson(Map<String, dynamic> json, {String defaultType = 'teacher'}) {
    return GovernanceAliasItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      alias: json['alias']?.toString() ?? '',
      normalizedAlias: json['normalized_alias']?.toString() ?? '',
      type: json['type']?.toString() ?? defaultType,
      targetId: (json['target_id'] ?? json['teacher_id'] ?? json['course_subject_id'] as num?)?.toInt() ?? 0,
      targetName: json['target_name']?.toString() ?? json['teacher_name']?.toString() ?? json['subject_name']?.toString() ?? '',
      subjectId: (json['course_subject_id'] ?? json['subject_id'] as num?)?.toInt(),
      subjectName: json['subject_name']?.toString() ?? '',
      source: json['source']?.toString() ?? 'admin',
      createdBy: (json['created_by'] as num?)?.toInt(),
      creatorName: json['creator_name']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}

/// 合并记录项
class TeacherMergeRecordItem {
  final int id;
  final String batchId;
  final int keeperId;
  final int loserId;
  final String keeperName;
  final String loserName;
  final String keeperSubject;
  final String loserSubject;
  final int migratedRatings;
  final int softDeletedRatings;
  final int migratedVotes;
  final int migratedSubmissions;
  final int supersededSubmissions;
  final int teacherAliasesAdded;
  final int courseAliasesAdded;
  final int adminId;
  final String adminName;
  final DateTime? createdAt;

  const TeacherMergeRecordItem({
    required this.id,
    required this.batchId,
    required this.keeperId,
    required this.loserId,
    this.keeperName = '',
    this.loserName = '',
    this.keeperSubject = '',
    this.loserSubject = '',
    this.migratedRatings = 0,
    this.softDeletedRatings = 0,
    this.migratedVotes = 0,
    this.migratedSubmissions = 0,
    this.supersededSubmissions = 0,
    this.teacherAliasesAdded = 0,
    this.courseAliasesAdded = 0,
    this.adminId = 0,
    this.adminName = '',
    this.createdAt,
  });

  factory TeacherMergeRecordItem.fromJson(Map<String, dynamic> json) {
    return TeacherMergeRecordItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      batchId: json['batch_id']?.toString() ?? '',
      keeperId: (json['keeper_id'] as num?)?.toInt() ?? 0,
      loserId: (json['loser_id'] as num?)?.toInt() ?? 0,
      keeperName: json['keeper_name_snapshot']?.toString() ?? json['keeper_name']?.toString() ?? '',
      loserName: json['loser_name_snapshot']?.toString() ?? json['loser_name']?.toString() ?? '',
      keeperSubject: json['keeper_subject_name_snapshot']?.toString() ?? json['keeper_subject']?.toString() ?? '',
      loserSubject: json['loser_subject_name_snapshot']?.toString() ?? json['loser_subject']?.toString() ?? '',
      migratedRatings: (json['migrated_ratings'] as num?)?.toInt() ?? 0,
      softDeletedRatings: (json['soft_deleted_ratings'] as num?)?.toInt() ?? 0,
      migratedVotes: (json['migrated_votes'] as num?)?.toInt() ?? 0,
      migratedSubmissions: (json['migrated_submissions'] as num?)?.toInt() ?? 0,
      supersededSubmissions: (json['superseded_submissions'] as num?)?.toInt() ?? 0,
      teacherAliasesAdded: (json['teacher_aliases_added'] as num?)?.toInt() ?? 0,
      courseAliasesAdded: (json['course_aliases_added'] as num?)?.toInt() ?? 0,
      adminId: (json['admin_id'] as num?)?.toInt() ?? 0,
      adminName: json['admin_name']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
