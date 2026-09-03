/// 课程评价相关 DTO。
///
/// 字段与服务端 `internal/services` 的视图结构一一对应，
/// 刻意不包含教室、周次、节次等课表私有信息。

/// 课程评价提交状态。取值与服务端 models 包保持一致。
enum CourseEvaluationStatus {
  /// 待管理员审核。
  pending,

  /// 已审核通过并发布到公开榜单。
  published,

  /// 被管理员驳回，需修改后重新提交。
  needsEdit,
}

CourseEvaluationStatus courseEvaluationStatusFromString(String? value) {
  switch (value) {
    case 'published':
      return CourseEvaluationStatus.published;
    case 'needs_edit':
      return CourseEvaluationStatus.needsEdit;
    case 'pending':
    default:
      return CourseEvaluationStatus.pending;
  }
}

String courseEvaluationStatusToString(CourseEvaluationStatus status) {
  switch (status) {
    case CourseEvaluationStatus.published:
      return 'published';
    case CourseEvaluationStatus.needsEdit:
      return 'needs_edit';
    case CourseEvaluationStatus.pending:
      return 'pending';
  }
}

extension CourseEvaluationStatusLabel on CourseEvaluationStatus {
  String get label {
    switch (this) {
      case CourseEvaluationStatus.published:
        return '已发布';
      case CourseEvaluationStatus.needsEdit:
        return '需修改';
      case CourseEvaluationStatus.pending:
        return '待审核';
    }
  }

  /// 是否还能打开表单编辑原记录。
  bool get editable => true;
}

/// 稳定业务错误码，与服务端保持一致。
abstract final class CourseEvaluationErrorCodes {
  static const String invalidInput = 'invalid_course_evaluation_input';
  static const String candidateRequired = 'course_subject_candidate_required';
  static const String revisionConflict = 'course_evaluation_revision_conflict';
  static const String forbidden = 'course_evaluation_forbidden';
  static const String reasonRequired =
      'course_evaluation_rejection_reason_required';
  static const String notFound = 'course_evaluation_not_found';
  static const String notPending = 'course_evaluation_not_pending';
  static const String unavailable = 'course_evaluation_subject_unavailable';

  /// 网络或服务不可用。客户端据此展示可重试错误，不破坏课表主体。
  static const String networkUnavailable =
      'course_evaluation_network_unavailable';
}

/// 课程评价请求失败。携带稳定业务码，供上层映射到已有状态。
class CourseEvaluationException implements Exception {
  final String code;
  final String message;

  const CourseEvaluationException(this.code, this.message);

  bool get isRevisionConflict => code == CourseEvaluationErrorCodes.revisionConflict;
  bool get isCandidateRequired =>
      code == CourseEvaluationErrorCodes.candidateRequired;
  bool get isForbidden => code == CourseEvaluationErrorCodes.forbidden;
  bool get isNetwork =>
      code == CourseEvaluationErrorCodes.networkUnavailable ||
      code == CourseEvaluationErrorCodes.unavailable;

  @override
  String toString() => message;
}

/// 标准学科。学科本身不承载评分，统计由教师评价聚合而来。
class CourseSubject {
  final int id;
  final String name;
  final int teacherCount;
  final double averageStar;
  final int ratingCount;

  const CourseSubject({
    required this.id,
    required this.name,
    this.teacherCount = 0,
    this.averageStar = 0,
    this.ratingCount = 0,
  });

  factory CourseSubject.fromJson(Map<String, dynamic> json) => CourseSubject(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        teacherCount: (json['teacher_count'] as num?)?.toInt() ?? 0,
        averageStar: (json['average_star'] as num?)?.toDouble() ?? 0,
        ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      );
}

/// 学科下的授课教师。
class CourseSubjectTeacher {
  final int id;
  final String name;
  final int ratingCount;
  final double averageStar;

  const CourseSubjectTeacher({
    required this.id,
    required this.name,
    this.ratingCount = 0,
    this.averageStar = 0,
  });

  factory CourseSubjectTeacher.fromJson(Map<String, dynamic> json) =>
      CourseSubjectTeacher(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
        averageStar: (json['average_star'] as num?)?.toDouble() ?? 0,
      );
}

/// 学科详情（含已审核教师列表）。
class CourseSubjectDetail {
  final int id;
  final String name;
  final int teacherCount;
  final double averageStar;
  final int ratingCount;
  final List<CourseSubjectTeacher> teachers;

  const CourseSubjectDetail({
    required this.id,
    required this.name,
    this.teacherCount = 0,
    this.averageStar = 0,
    this.ratingCount = 0,
    this.teachers = const [],
  });

  factory CourseSubjectDetail.fromJson(Map<String, dynamic> json) {
    final rawTeachers = json['teachers'];
    return CourseSubjectDetail(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      teacherCount: (json['teacher_count'] as num?)?.toInt() ?? 0,
      averageStar: (json['average_star'] as num?)?.toDouble() ?? 0,
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      teachers: rawTeachers is List
          ? rawTeachers
              .whereType<Map<String, dynamic>>()
              .map(CourseSubjectTeacher.fromJson)
              .toList()
          : const [],
    );
  }
}

/// 名称候选的匹配方式。
class CourseSubjectMatchKind {
  static const String exact = 'exact';
  static const String alias = 'alias';
  static const String contains = 'contains';
}

/// 学科候选。
class CourseSubjectCandidate {
  final int id;
  final String name;
  final bool verified;
  final String match;

  const CourseSubjectCandidate({
    required this.id,
    required this.name,
    this.verified = false,
    this.match = CourseSubjectMatchKind.exact,
  });

  bool get isExact => match == CourseSubjectMatchKind.exact;

  factory CourseSubjectCandidate.fromJson(Map<String, dynamic> json) =>
      CourseSubjectCandidate(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        verified: json['verified'] == true,
        match: json['match']?.toString() ?? CourseSubjectMatchKind.exact,
      );
}

/// 教师候选。
class CourseEvaluationTeacherCandidate {
  final int id;
  final String name;
  final bool verified;
  final String match;

  const CourseEvaluationTeacherCandidate({
    required this.id,
    required this.name,
    this.verified = false,
    this.match = CourseSubjectMatchKind.exact,
  });

  factory CourseEvaluationTeacherCandidate.fromJson(
          Map<String, dynamic> json) =>
      CourseEvaluationTeacherCandidate(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        verified: json['verified'] == true,
        match: json['match']?.toString() ?? CourseSubjectMatchKind.exact,
      );
}

/// 解析结果。requiresConfirmation 为 true 时必须由用户选择候选后再提交。
class CourseEvaluationResolveResult {
  final String courseName;
  final String teacherName;
  final List<CourseSubjectCandidate> courseSubjects;
  final List<CourseEvaluationTeacherCandidate> teachers;
  final int? selectedCourseSubjectId;
  final int? selectedTeacherId;
  final bool requiresConfirmation;
  final String? code;
  final CourseEvaluationSubmission? submission;

  const CourseEvaluationResolveResult({
    this.courseName = '',
    this.teacherName = '',
    this.courseSubjects = const [],
    this.teachers = const [],
    this.selectedCourseSubjectId,
    this.selectedTeacherId,
    this.requiresConfirmation = false,
    this.code,
    this.submission,
  });

  factory CourseEvaluationResolveResult.fromJson(Map<String, dynamic> json) {
    final rawSubjects = json['course_subjects'];
    final rawTeachers = json['teachers'];
    final rawSubmission = json['submission'];
    return CourseEvaluationResolveResult(
      courseName: json['course_name']?.toString() ?? '',
      teacherName: json['teacher_name']?.toString() ?? '',
      courseSubjects: rawSubjects is List
          ? rawSubjects
              .whereType<Map<String, dynamic>>()
              .map(CourseSubjectCandidate.fromJson)
              .toList()
          : const [],
      teachers: rawTeachers is List
          ? rawTeachers
              .whereType<Map<String, dynamic>>()
              .map(CourseEvaluationTeacherCandidate.fromJson)
              .toList()
          : const [],
      selectedCourseSubjectId:
          (json['selected_course_subject_id'] as num?)?.toInt(),
      selectedTeacherId: (json['selected_teacher_id'] as num?)?.toInt(),
      requiresConfirmation: json['requires_confirmation'] == true,
      code: json['code']?.toString(),
      submission: rawSubmission is Map<String, dynamic>
          ? CourseEvaluationSubmission.fromJson(rawSubmission)
          : null,
    );
  }
}

/// 一次课程评价提交记录。
class CourseEvaluationSubmission {
  final int id;
  final int userId;
  final String courseName;
  final int? courseSubjectId;
  final String courseSubjectName;
  final String teacherName;
  final int? teacherId;
  final int star;
  final String comment;
  final CourseEvaluationStatus status;
  final String source;
  final int revision;
  final String reviewReason;
  final int? teacherRatingId;
  final String proposedCourseName;
  final String proposedTeacherName;
  final bool willCreateSubject;
  final String reviewerName;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const CourseEvaluationSubmission({
    required this.id,
    this.userId = 0,
    this.courseName = '',
    this.courseSubjectId,
    this.courseSubjectName = '',
    this.teacherName = '',
    this.teacherId,
    this.star = 0,
    this.comment = '',
    this.status = CourseEvaluationStatus.pending,
    this.source = 'schedule',
    this.revision = 1,
    this.reviewReason = '',
    this.teacherRatingId,
    this.proposedCourseName = '',
    this.proposedTeacherName = '',
    this.willCreateSubject = false,
    this.reviewerName = '',
    this.createdAt,
    this.updatedAt,
  });

  /// 展示用的学科名：已归属取学科名，未归属取用户提议，最后回退原始课程名。
  String get subjectDisplayName {
    if (courseSubjectName.trim().isNotEmpty) return courseSubjectName;
    if (proposedCourseName.trim().isNotEmpty) return proposedCourseName;
    return courseName;
  }

  /// 展示用的教师名：已关联取教师名，否则取用户提议。
  String get teacherDisplayName {
    if (teacherName.trim().isNotEmpty) return teacherName;
    return proposedTeacherName;
  }

  factory CourseEvaluationSubmission.fromJson(Map<String, dynamic> json) =>
      CourseEvaluationSubmission(
        id: (json['id'] as num?)?.toInt() ?? 0,
        userId: (json['user_id'] as num?)?.toInt() ?? 0,
        courseName: json['course_name']?.toString() ?? '',
        courseSubjectId: (json['course_subject_id'] as num?)?.toInt(),
        courseSubjectName: json['course_subject_name']?.toString() ?? '',
        teacherName: json['teacher_name']?.toString() ?? '',
        teacherId: (json['teacher_id'] as num?)?.toInt(),
        star: (json['star'] as num?)?.toInt() ?? 0,
        comment: json['comment']?.toString() ?? '',
        status: courseEvaluationStatusFromString(json['status']?.toString()),
        source: json['source']?.toString() ?? 'schedule',
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        reviewReason: json['review_reason']?.toString() ?? '',
        teacherRatingId: (json['teacher_rating_id'] as num?)?.toInt(),
        proposedCourseName: json['proposed_course_name']?.toString() ?? '',
        proposedTeacherName: json['proposed_teacher_name']?.toString() ?? '',
        willCreateSubject: json['will_create_subject'] == true,
        reviewerName: json['reviewer_name']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      );
}

/// 游标分页结果。
class CourseEvaluationPage {
  final List<CourseEvaluationSubmission> items;
  final String nextCursor;
  final bool hasMore;

  const CourseEvaluationPage({
    this.items = const [],
    this.nextCursor = '',
    this.hasMore = false,
  });

  factory CourseEvaluationPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return CourseEvaluationPage(
      items: rawItems is List
          ? rawItems
              .whereType<Map<String, dynamic>>()
              .map(CourseEvaluationSubmission.fromJson)
              .toList()
          : const [],
      nextCursor: json['next_cursor']?.toString() ?? '',
      hasMore: json['has_more'] == true,
    );
  }
}

/// 评论长度上限，与服务端 CourseEvaluationCommentMaxRunes 一致。
const int kCourseEvaluationCommentMaxLength = 200;
