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

/// 课程学科归并计划（跨学科教师合并决策）
class GovernanceCourseMergePlan {
  final int loserSubjectId;
  final String loserSubjectName;
  final int keeperSubjectId;
  final String keeperSubjectName;
  final bool mergeSubjectEntity;
  final int rehungTeachers;
  final int collisionTeachers;
  final int relinkedSubmissions;
  final String courseAlias;
  final String courseAliasStatus;

  const GovernanceCourseMergePlan({
    required this.loserSubjectId,
    this.loserSubjectName = '',
    required this.keeperSubjectId,
    this.keeperSubjectName = '',
    this.mergeSubjectEntity = false,
    this.rehungTeachers = 0,
    this.collisionTeachers = 0,
    this.relinkedSubmissions = 0,
    this.courseAlias = '',
    this.courseAliasStatus = '',
  });

  factory GovernanceCourseMergePlan.fromJson(Map<String, dynamic> json) {
    return GovernanceCourseMergePlan(
      loserSubjectId: (json['loser_subject_id'] as num?)?.toInt() ?? 0,
      loserSubjectName: json['loser_subject_name']?.toString() ?? '',
      keeperSubjectId: (json['keeper_subject_id'] as num?)?.toInt() ?? 0,
      keeperSubjectName: json['keeper_subject_name']?.toString() ?? '',
      mergeSubjectEntity: json['merge_subject_entity'] == true,
      rehungTeachers: (json['rehung_teachers'] as num?)?.toInt() ?? 0,
      collisionTeachers: (json['collision_teachers'] as num?)?.toInt() ?? 0,
      relinkedSubmissions: (json['relinked_submissions'] as num?)?.toInt() ?? 0,
      courseAlias: json['course_alias']?.toString() ?? '',
      courseAliasStatus: json['course_alias_status']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson({bool? overrideMergeSubjectEntity}) {
    return {
      'loser_subject_id': loserSubjectId,
      'keeper_subject_id': keeperSubjectId,
      'merge_subject_entity': overrideMergeSubjectEntity ?? mergeSubjectEntity,
    };
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
  final List<GovernanceCourseMergePlan> courseMerges;
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
    this.courseMerges = const [],
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

    final rawCourseMerges = (json['course_merges'] ?? json['subject_merges']) as List? ?? [];
    final courseMergesList = rawCourseMerges
        .whereType<Map>()
        .map((e) => GovernanceCourseMergePlan.fromJson(Map<String, dynamic>.from(e)))
        .toList();

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
      courseMerges: courseMergesList,
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

/// 别名目标搜索项（学科 / 教师）
class AliasTargetItem {
  final int id;
  final String name;
  final int? subjectId;
  final bool verified;

  const AliasTargetItem({
    required this.id,
    this.name = '',
    this.subjectId,
    this.verified = false,
  });

  factory AliasTargetItem.fromJson(Map<String, dynamic> json) {
    return AliasTargetItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      subjectId: (json['course_subject_id'] as num?)?.toInt(),
      verified: json['verified'] == true,
    );
  }

  String get label => verified ? '$name（已审核）' : name;
}

/// 合并记录项
class TeacherMergeRecordItem {
  final int id;
  final String batchId;
  final String action;
  final String reason;
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
    this.action = 'teacher_merge',
    this.reason = '',
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
      action: json['action']?.toString() ?? 'teacher_merge',
      reason: json['reason']?.toString() ?? '',
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

/// 课程合并中配对的教师
class CourseMergeTeacherPair {
  final int loserTeacherId;
  final int keeperTeacherId;
  final String finalTeacherName;

  const CourseMergeTeacherPair({
    required this.loserTeacherId,
    required this.keeperTeacherId,
    this.finalTeacherName = '',
  });

  Map<String, dynamic> toJson() => {
    'loser_teacher_id': loserTeacherId,
    'keeper_teacher_id': keeperTeacherId,
    'final_teacher_name': finalTeacherName,
  };

  factory CourseMergeTeacherPair.fromJson(Map<String, dynamic> json) =>
      CourseMergeTeacherPair(
        loserTeacherId: (json['loser_teacher_id'] as num?)?.toInt() ?? 0,
        keeperTeacherId: (json['keeper_teacher_id'] as num?)?.toInt() ?? 0,
        finalTeacherName: json['final_teacher_name']?.toString() ?? '',
      );
}

/// 课程概览信息
class CourseSubjectSummary {
  final int id;
  final String name;
  final bool verified;
  final int teacherCount;
  final int ratingCount;
  final double averageStar;

  const CourseSubjectSummary({
    required this.id,
    required this.name,
    this.verified = false,
    this.teacherCount = 0,
    this.ratingCount = 0,
    this.averageStar = 0,
  });

  factory CourseSubjectSummary.fromJson(Map<String, dynamic> json) =>
      CourseSubjectSummary(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        verified: json['verified'] == true,
        teacherCount: (json['teacher_count'] as num?)?.toInt() ?? 0,
        ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
        averageStar: (json['average_star'] as num?)?.toDouble() ?? 0,
      );
}

/// 迁入教师摘要
class MigratingTeacherSummary {
  final int teacherId;
  final String teacherName;
  final String fromSubject;
  final String toSubject;
  final int ratingCount;

  const MigratingTeacherSummary({
    required this.teacherId,
    required this.teacherName,
    this.fromSubject = '',
    this.toSubject = '',
    this.ratingCount = 0,
  });

  factory MigratingTeacherSummary.fromJson(Map<String, dynamic> json) =>
      MigratingTeacherSummary(
        teacherId: (json['teacher_id'] as num?)?.toInt() ?? 0,
        teacherName: json['teacher_name']?.toString() ?? '',
        fromSubject: json['from_subject']?.toString() ?? '',
        toSubject: json['to_subject']?.toString() ?? '',
        ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      );
}

/// 配对合并教师摘要
class PairedTeacherMergeSummary {
  final int loserTeacherId;
  final String loserTeacherName;
  final int keeperTeacherId;
  final String keeperTeacherName;
  final String finalTeacherName;
  final int migratedRatings;
  final int softDeletedRatings;
  final int migratedVotes;

  const PairedTeacherMergeSummary({
    required this.loserTeacherId,
    required this.loserTeacherName,
    required this.keeperTeacherId,
    required this.keeperTeacherName,
    required this.finalTeacherName,
    this.migratedRatings = 0,
    this.softDeletedRatings = 0,
    this.migratedVotes = 0,
  });

  factory PairedTeacherMergeSummary.fromJson(Map<String, dynamic> json) =>
      PairedTeacherMergeSummary(
        loserTeacherId: (json['loser_teacher_id'] as num?)?.toInt() ?? 0,
        loserTeacherName: json['loser_teacher_name']?.toString() ?? '',
        keeperTeacherId: (json['keeper_teacher_id'] as num?)?.toInt() ?? 0,
        keeperTeacherName: json['keeper_teacher_name']?.toString() ?? '',
        finalTeacherName: json['final_teacher_name']?.toString() ?? '',
        migratedRatings: (json['migrated_ratings'] as num?)?.toInt() ?? 0,
        softDeletedRatings: (json['soft_deleted_ratings'] as num?)?.toInt() ?? 0,
        migratedVotes: (json['migrated_votes'] as num?)?.toInt() ?? 0,
      );
}

/// 独立课程合并预览结果
class CourseMergePreviewResult {
  final String snapshotToken;
  final bool mergeAllowed;
  final String blockReason;
  final List<String> conflicts;
  final CourseSubjectSummary keeperSubject;
  final List<CourseSubjectSummary> loserSubjects;
  final String finalCourseName;
  final List<MigratingTeacherSummary> migratingTeachers;
  final List<PairedTeacherMergeSummary> pairedTeacherMerges;
  final int totalRatingsMigrating;
  final int totalRatingsDeduped;
  final int totalVotesMigrating;
  final int totalSubmissionsRelinked;
  final List<String> courseAliasesToCreate;

  const CourseMergePreviewResult({
    this.snapshotToken = '',
    this.mergeAllowed = true,
    this.blockReason = '',
    this.conflicts = const [],
    this.keeperSubject = const CourseSubjectSummary(id: 0, name: ''),
    this.loserSubjects = const [],
    this.finalCourseName = '',
    this.migratingTeachers = const [],
    this.pairedTeacherMerges = const [],
    this.totalRatingsMigrating = 0,
    this.totalRatingsDeduped = 0,
    this.totalVotesMigrating = 0,
    this.totalSubmissionsRelinked = 0,
    this.courseAliasesToCreate = const [],
  });

  factory CourseMergePreviewResult.fromJson(Map<String, dynamic> json) {
    final rawConflicts = (json['conflicts'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final rawLosers = (json['loser_subjects'] as List?) ?? [];
    final rawMigrating = (json['migrating_teachers'] as List?) ?? [];
    final rawPaired = (json['paired_teacher_merges'] as List?) ?? [];
    final rawAliases = (json['course_aliases_to_create'] as List?)?.map((e) => e.toString()).toList() ?? const [];

    return CourseMergePreviewResult(
      snapshotToken: json['snapshot_token']?.toString() ?? '',
      mergeAllowed: json['merge_allowed'] == true,
      blockReason: json['block_reason']?.toString() ?? '',
      conflicts: rawConflicts,
      keeperSubject: json['keeper_subject'] is Map
          ? CourseSubjectSummary.fromJson(Map<String, dynamic>.from(json['keeper_subject'] as Map))
          : const CourseSubjectSummary(id: 0, name: ''),
      loserSubjects: rawLosers
          .whereType<Map>()
          .map((e) => CourseSubjectSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      finalCourseName: json['final_course_name']?.toString() ?? '',
      migratingTeachers: rawMigrating
          .whereType<Map>()
          .map((e) => MigratingTeacherSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      pairedTeacherMerges: rawPaired
          .whereType<Map>()
          .map((e) => PairedTeacherMergeSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      totalRatingsMigrating: (json['total_ratings_migrating'] as num?)?.toInt() ?? 0,
      totalRatingsDeduped: (json['total_ratings_deduped'] as num?)?.toInt() ?? 0,
      totalVotesMigrating: (json['total_votes_migrating'] as num?)?.toInt() ?? 0,
      totalSubmissionsRelinked: (json['total_submissions_relinked'] as num?)?.toInt() ?? 0,
      courseAliasesToCreate: rawAliases,
    );
  }

  int get ratingsMigrated => totalRatingsMigrating;
  int get ratingsSoftDeleted => totalRatingsDeduped;
  int get votesMigrated => totalVotesMigrating;
  int get submissionsSuperseded => totalSubmissionsRelinked;
  int get courseAliasesAdded => courseAliasesToCreate.length;
  int get teacherAliasesAdded => pairedTeacherMerges.length;
  List<String> get ratingConflicts => conflicts;
}

/// 课程治理项（供课程搜索列表）
class GovernanceCourseItem {
  final int id;
  final String name;
  final bool verified;
  final int teacherCount;
  final int ratingCount;
  final double averageStar;
  final bool isMerged;
  final int? mergedIntoId;

  const GovernanceCourseItem({
    required this.id,
    required this.name,
    this.verified = false,
    this.teacherCount = 0,
    this.ratingCount = 0,
    this.averageStar = 0,
    this.isMerged = false,
    this.mergedIntoId,
  });

  factory GovernanceCourseItem.fromJson(Map<String, dynamic> json) =>
      GovernanceCourseItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        verified: json['verified'] == true,
        teacherCount: (json['teacher_count'] as num?)?.toInt() ?? 0,
        ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
        averageStar: (json['average_star'] as num?)?.toDouble() ?? 0,
        isMerged: json['is_merged'] == true || json['merged_into_id'] != null,
        mergedIntoId: (json['merged_into_id'] as num?)?.toInt(),
      );
}
