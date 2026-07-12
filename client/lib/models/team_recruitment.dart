import 'post.dart';

/// 组队大厅使用的独立业务模型。
///
/// 底层仍关联水帖以复用作者、图片和审核能力，但页面不再依赖帖子列表模型。
class TeamRecruitment {
  final int id;
  final int postId;
  final String category;
  final String title;
  final String description;
  final TeamRecruitmentAuthor author;
  final List<PostImage> images;
  final String firstImageUrl;
  final int neededCount;
  final int acceptedCount;
  final int remainingCount;
  final List<String> roles;
  final DateTime? deadline;
  final String status;
  final String effectiveStatus;
  final int applicationCount;
  final String? myApplicationStatus;
  final bool isOwner;
  final bool canApply;
  final bool canManage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TeamRecruitment({
    required this.id,
    required this.postId,
    required this.category,
    required this.title,
    required this.description,
    required this.author,
    this.images = const [],
    this.firstImageUrl = '',
    required this.neededCount,
    required this.acceptedCount,
    required this.remainingCount,
    this.roles = const [],
    this.deadline,
    required this.status,
    required this.effectiveStatus,
    this.applicationCount = 0,
    this.myApplicationStatus,
    this.isOwner = false,
    this.canApply = false,
    this.canManage = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TeamRecruitment.fromJson(Map<String, dynamic> json) {
    final authorJson = json['author'];
    final imagesJson = json['images'];
    return TeamRecruitment(
      id: (json['id'] as num?)?.toInt() ?? 0,
      postId: (json['post_id'] as num?)?.toInt() ?? 0,
      category: json['category']?.toString() ?? 'other',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      author: authorJson is Map
          ? TeamRecruitmentAuthor.fromJson(authorJson.cast<String, dynamic>())
          : TeamRecruitmentAuthor(
              id: (json['author_id'] as num?)?.toInt() ?? 0,
              name: json['author_name']?.toString() ?? '校园用户',
              avatar: json['author_avatar']?.toString() ?? '',
              major: json['author_major']?.toString() ?? '',
            ),
      images: imagesJson is List
          ? imagesJson.whereType<Map>().map((item) {
              final image = item.cast<String, dynamic>();
              final url = image['url']?.toString() ?? '';
              return PostImage(
                id: (image['id'] as num?)?.toInt() ?? 0,
                postId: (json['post_id'] as num?)?.toInt() ?? 0,
                fileId: (image['file_id'] as num?)?.toInt() ?? 0,
                file: FileItem(
                  id: 0,
                  hash: '',
                  path: url,
                  size: 0,
                  mimeType: '',
                ),
              );
            }).toList(growable: false)
          : const [],
      firstImageUrl: json['first_image_url']?.toString() ?? '',
      neededCount: (json['needed_count'] as num?)?.toInt() ?? 0,
      acceptedCount: (json['accepted_count'] as num?)?.toInt() ?? 0,
      remainingCount: (json['remaining_count'] as num?)?.toInt() ?? 0,
      roles:
          (json['roles'] as List?)?.map((item) => item.toString()).toList() ??
              const [],
      deadline: DateTime.tryParse(json['deadline']?.toString() ?? ''),
      status: json['status']?.toString() ?? 'recruiting',
      effectiveStatus: json['effective_status']?.toString() ?? 'recruiting',
      applicationCount: (json['application_count'] as num?)?.toInt() ?? 0,
      myApplicationStatus: json['my_application_status']?.toString(),
      isOwner: json['is_owner'] == true,
      canApply: json['can_apply'] == true,
      canManage: json['can_manage'] == true,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  bool get isRecruiting => effectiveStatus == 'recruiting';
  bool get isFull => effectiveStatus == 'full';
  bool get isClosed => effectiveStatus == 'closed';
  bool get isExpired => effectiveStatus == 'expired';
}

class TeamRecruitmentAuthor {
  final int id;
  final String name;
  final String avatar;
  final String major;
  final String bio;

  const TeamRecruitmentAuthor({
    required this.id,
    required this.name,
    this.avatar = '',
    this.major = '',
    this.bio = '',
  });

  factory TeamRecruitmentAuthor.fromJson(Map<String, dynamic> json) {
    return TeamRecruitmentAuthor(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '校园用户',
      avatar: json['avatar']?.toString() ?? '',
      major: json['major']?.toString() ?? '',
      bio: json['bio']?.toString() ?? '',
    );
  }
}
