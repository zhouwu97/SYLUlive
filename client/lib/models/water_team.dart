import 'post.dart';

// 兼容组队模型统一入口，帖子与组队申请可从同一模型文件导入。
export 'post.dart' show TeamRecruitmentMeta;
import 'user.dart';

/// 组队申请记录。
class WaterTeamApplication {
  final int id;
  final int recruitmentId;
  final int postId;
  final int applicantId;
  final int ownerId;
  final String message;
  final String availability;
  final String status;
  final DateTime? reviewedAt;
  final String ownerReply;
  final DateTime createdAt;
  final DateTime updatedAt;
  final User? applicant;
  final Post? post;

  const WaterTeamApplication({
    required this.id,
    required this.recruitmentId,
    required this.postId,
    required this.applicantId,
    required this.ownerId,
    this.message = '',
    this.availability = '',
    this.status = 'pending',
    this.reviewedAt,
    this.ownerReply = '',
    required this.createdAt,
    required this.updatedAt,
    this.applicant,
    this.post,
  });

  factory WaterTeamApplication.fromJson(Map<String, dynamic> json) {
    final applicantJson = json['applicant'];
    final postJson = json['post'];
    return WaterTeamApplication(
      id: (json['id'] as num?)?.toInt() ?? 0,
      recruitmentId: (json['recruitment_id'] as num?)?.toInt() ?? 0,
      postId: (json['post_id'] as num?)?.toInt() ?? 0,
      applicantId: (json['applicant_id'] as num?)?.toInt() ?? 0,
      ownerId: (json['owner_id'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      availability: json['availability']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      reviewedAt: DateTime.tryParse(json['reviewed_at']?.toString() ?? ''),
      ownerReply: json['owner_reply']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
      applicant: applicantJson is Map
          ? User.fromJson(applicantJson.cast<String, dynamic>())
          : null,
      post: postJson is Map
          ? Post.fromJson(postJson.cast<String, dynamic>())
          : null,
    );
  }
}
