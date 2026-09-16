class Teacher {
  final int id;
  final String name;
  final String course;
  final int ratingCount;
  final double averageStar;
  final DateTime createdAt;

  /// 标准学科归属。历史数据与服务端旧响应可能为空。
  final int? courseSubjectId;

  /// 教师治理状态字段
  final bool isMerged;
  final int? mergedIntoId;
  final String mergedIntoName;
  final String canonicalSource;
  final bool verified;

  Teacher({
    required this.id,
    required this.name,
    required this.course,
    this.ratingCount = 0,
    this.averageStar = 0,
    required this.createdAt,
    this.courseSubjectId,
    this.isMerged = false,
    this.mergedIntoId,
    this.mergedIntoName = '',
    this.canonicalSource = 'legacy',
    this.verified = false,
  });

  factory Teacher.fromJson(Map<String, dynamic> json) {
    final mergedInto = (json['merged_into_id'] as num?)?.toInt();
    return Teacher(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      course: json['course'] ?? '',
      ratingCount: json['rating_count'] ?? 0,
      averageStar: (json['average_star'] ?? 0).toDouble(),
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      courseSubjectId: (json['course_subject_id'] as num?)?.toInt(),
      isMerged: json['merged'] == true || mergedInto != null,
      mergedIntoId: mergedInto,
      mergedIntoName: json['merged_into_name']?.toString() ?? '',
      canonicalSource: json['canonical_source']?.toString() ?? 'legacy',
      verified: json['verified'] == true,
    );
  }
}

class TeacherRating {
  final int id;
  final int teacherId;
  final int userId;
  final int star;
  final String comment;
  final String userName;
  final String userAvatar;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote;
  final bool isOwn;

  TeacherRating({
    required this.id,
    required this.teacherId,
    required this.userId,
    required this.star,
    required this.comment,
    this.userName = '',
    this.userAvatar = '',
    this.createdAt,
    this.updatedAt,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    this.myVote,
    this.isOwn = false,
  });

  factory TeacherRating.fromJson(Map<String, dynamic> json) {
    return TeacherRating(
      id: json['id'] ?? 0,
      teacherId: json['teacher_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      star: json['star'] ?? 0,
      comment: json['comment'] ?? '',
      userName: json['user_name'] ?? '',
      userAvatar: json['user_avatar'] ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'])
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'])
          : null,
      helpfulCount: json['helpful_count'] ?? 0,
      unhelpfulCount: json['unhelpful_count'] ?? 0,
      myVote: json['my_vote'],
      isOwn: json['is_own'] ?? false,
    );
  }
}
