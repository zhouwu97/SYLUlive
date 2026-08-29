import 'dart:convert';

import 'user.dart';
import 'poll.dart';
import 'topic.dart';

// 水帖版块内作者称号及等级
class WaterSectionAuthorMeta {
  final int sectionId;
  final String sectionSlug;
  final String sectionTitle;
  final int level;
  final int exp;
  final String title;

  WaterSectionAuthorMeta({
    required this.sectionId,
    required this.sectionSlug,
    required this.sectionTitle,
    required this.level,
    required this.exp,
    required this.title,
  });

  factory WaterSectionAuthorMeta.fromJson(Map<String, dynamic> json) {
    return WaterSectionAuthorMeta(
      sectionId: json['section_id'] ?? 0,
      sectionSlug: json['section_slug'] ?? '',
      sectionTitle: json['section_title'] ?? '',
      level: json['level'] ?? 1,
      exp: json['exp'] ?? 0,
      title: json['title'] ?? '',
    );
  }
}

// 经验奖励结果：发帖/回复成功后用于展示本次获得的全站与版块经验。
class ExpAward {
  final String scope;
  final int exp;
  final String action;
  final int levelBefore;
  final int levelAfter;
  final bool levelUp;
  final int? sectionId;
  final String sectionSlug;
  final String sectionTitle;
  final String titleBefore;
  final String titleAfter;

  const ExpAward({
    required this.scope,
    required this.exp,
    required this.action,
    this.levelBefore = 1,
    this.levelAfter = 1,
    this.levelUp = false,
    this.sectionId,
    this.sectionSlug = '',
    this.sectionTitle = '',
    this.titleBefore = '',
    this.titleAfter = '',
  });

  factory ExpAward.fromJson(Map<String, dynamic> json) {
    return ExpAward(
      scope: json['scope'] ?? '',
      exp: (json['exp'] as num?)?.toInt() ?? 0,
      action: json['action'] ?? '',
      levelBefore: (json['level_before'] as num?)?.toInt() ?? 1,
      levelAfter: (json['level_after'] as num?)?.toInt() ?? 1,
      levelUp: json['level_up'] == true,
      sectionId: json['section_id'] != null
          ? (json['section_id'] as num).toInt()
          : null,
      sectionSlug: json['section_slug'] ?? '',
      sectionTitle: json['section_title'] ?? '',
      titleBefore: json['title_before'] ?? '',
      titleAfter: json['title_after'] ?? '',
    );
  }
}

// 帖子图片模型
class PostImage {
  final int id;
  final int postId;
  final int fileId;
  final int sortOrder;
  final FileItem? file;
  final String thumbUrl;
  final String mediumUrl;
  final String viewerUrl;
  final String originUrl;

  PostImage({
    required this.id,
    required this.postId,
    required this.fileId,
    this.sortOrder = 0,
    this.file,
    this.thumbUrl = '',
    this.mediumUrl = '',
    this.viewerUrl = '',
    this.originUrl = '',
  });

  factory PostImage.fromJson(Map<String, dynamic> json) {
    final fileJson = json['file'];
    return PostImage(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      fileId: json['file_id'] ?? 0,
      sortOrder: json['sort_order'] ?? 0,
      file: fileJson != null ? FileItem.fromJson(fileJson) : null,
      thumbUrl: json['thumb_url']?.toString() ??
          (fileJson is Map ? fileJson['thumb_url']?.toString() : null) ??
          '',
      mediumUrl: json['medium_url']?.toString() ??
          (fileJson is Map ? fileJson['medium_url']?.toString() : null) ??
          '',
      viewerUrl: json['viewer_url']?.toString() ??
          (fileJson is Map ? fileJson['viewer_url']?.toString() : null) ??
          '',
      originUrl: json['origin_url']?.toString() ??
          (fileJson is Map ? fileJson['origin_url']?.toString() : null) ??
          '',
    );
  }

  String get url => file?.url ?? '';
  String get resolvedThumbUrl => thumbUrl.isNotEmpty ? thumbUrl : url;
  String get resolvedMediumUrl => mediumUrl.isNotEmpty ? mediumUrl : url;
  String get resolvedViewerUrl => viewerUrl.isNotEmpty ? viewerUrl : url;
  String get resolvedOriginUrl => originUrl.isNotEmpty ? originUrl : url;
}

// 文件模型
class FileItem {
  final int id;
  final String hash;
  final String path;
  final int size;
  final String mimeType;
  final int width;
  final int height;

  FileItem({
    required this.id,
    required this.hash,
    required this.path,
    required this.size,
    required this.mimeType,
    this.width = 0,
    this.height = 0,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      id: json['id'] ?? 0,
      hash: json['hash'] ?? '',
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
      mimeType: json['mime_type'] ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );
  }

  String get url => path;
}

// 帖子模型

class TeamRecruitmentMeta {
  final int recruitmentId;
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

  TeamRecruitmentMeta({
    required this.recruitmentId,
    required this.neededCount,
    required this.acceptedCount,
    required this.remainingCount,
    required this.roles,
    this.deadline,
    required this.status,
    required this.effectiveStatus,
    required this.applicationCount,
    this.myApplicationStatus,
    required this.isOwner,
    required this.canApply,
    required this.canManage,
  });

  /// 服务端返回的 effective_status 是按钮矩阵的唯一状态依据。
  bool get isRecruiting => effectiveStatus == 'recruiting';
  bool get isFull => effectiveStatus == 'full';
  bool get isClosed => effectiveStatus == 'closed';
  bool get isExpired => effectiveStatus == 'expired';
  bool get isPending => myApplicationStatus == 'pending';
  bool get isAccepted => myApplicationStatus == 'accepted';
  bool get isRejected => myApplicationStatus == 'rejected';
  bool get isCancelled => myApplicationStatus == 'cancelled';

  factory TeamRecruitmentMeta.fromJson(Map<String, dynamic> json) {
    return TeamRecruitmentMeta(
      recruitmentId: json['recruitment_id'] ?? 0,
      neededCount: json['needed_count'] ?? 0,
      acceptedCount: json['accepted_count'] ?? 0,
      remainingCount: json['remaining_count'] ?? 0,
      roles: (json['roles'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      deadline: DateTime.tryParse(json['deadline'] ?? ''),
      status: json['status'] ?? '',
      effectiveStatus: json['effective_status'] ?? '',
      applicationCount: json['application_count'] ?? 0,
      myApplicationStatus: json['my_application_status'],
      isOwner: json['is_owner'] == true,
      canApply: json['can_apply'] == true,
      canManage: json['can_manage'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'recruitment_id': recruitmentId,
      'needed_count': neededCount,
      'accepted_count': acceptedCount,
      'remaining_count': remainingCount,
      'roles': roles,
      if (deadline != null) 'deadline': deadline!.toIso8601String(),
      'status': status,
      'effective_status': effectiveStatus,
      'application_count': applicationCount,
      if (myApplicationStatus != null)
        'my_application_status': myApplicationStatus,
      'is_owner': isOwner,
      'can_apply': canApply,
      'can_manage': canManage,
    };
  }
}

class Post {
  final int id;
  final String title;
  final String content;
  final int boardId;
  final int authorId;
  final String postType;
  final String contentKind;
  final double price;
  final String contactType;
  final String contact;
  final List<String> marketTags;
  final int? waterTagId;
  final String status;
  final int viewCount;
  final int replyCount;
  final int likeCount;
  final bool isLiked;
  final bool isPinned;
  final DateTime? pinnedAt;
  final DateTime? pinnedUntil;
  final int pinnedBy;
  final int pinnedWeight;
  final String pinnedReason;
  final bool isFeatured;
  final DateTime? featuredAt;
  final int featuredBy;
  final String featuredReason;
  final bool waterSectionPinned;
  final int? waterSectionPinId;
  final bool waterSectionFeatured;
  final int? waterSectionFeaturedId;
  final bool homeFeaturedPending;
  final WaterSectionAuthorMeta? waterSectionAuthorMeta;
  final TeamRecruitmentMeta? teamRecruitment;
  final PollMeta? pollMeta;
  final List<Topic> topics;
  final int? expEarned; // 发帖/评论成功时服务端返回的本次经验值，null=无奖励
  final List<ExpAward> expAwards;
  final List<PostImage> images;
  final User? author;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastActivityAt;

  Post({
    required this.id,
    this.title = '',
    required this.content,
    required this.boardId,
    required this.authorId,
    this.postType = '',
    this.contentKind = 'normal',
    this.price = 0,
    this.contactType = '',
    this.contact = '',
    this.marketTags = const [],
    this.waterTagId,
    this.status = 'normal',
    this.viewCount = 0,
    this.replyCount = 0,
    this.likeCount = 0,
    this.isLiked = false,
    this.isPinned = false,
    this.pinnedAt,
    this.pinnedUntil,
    this.pinnedBy = 0,
    this.pinnedWeight = 0,
    this.pinnedReason = '',
    this.isFeatured = false,
    this.featuredAt,
    this.featuredBy = 0,
    this.featuredReason = '',
    this.waterSectionPinned = false,
    this.waterSectionPinId,
    this.waterSectionFeatured = false,
    this.waterSectionFeaturedId,
    this.homeFeaturedPending = false,
    this.waterSectionAuthorMeta,
    this.teamRecruitment,
    this.pollMeta,
    this.topics = const [],
    this.expEarned,
    this.expAwards = const [],
    this.images = const [],
    this.author,
    required this.createdAt,
    DateTime? updatedAt,
    DateTime? lastActivityAt,
  })  : updatedAt = updatedAt ?? createdAt,
        lastActivityAt = lastActivityAt ?? createdAt;

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      boardId: json['board_id'] ?? 1,
      authorId: json['author_id'] ?? 0,
      postType: json['post_type'] ?? '',
      contentKind: json['content_kind'] ?? 'normal',
      price: (json['price'] ?? 0).toDouble(),
      contactType: json['contact_type'] ?? '',
      contact: json['contact'] ?? '',
      marketTags: _parseStringList(json['market_tags']),
      waterTagId: json['water_tag_id'] != null
          ? (json['water_tag_id'] as num).toInt()
          : null,
      status: json['status'] ?? 'normal',
      viewCount: json['view_count'] ?? 0,
      replyCount: json['reply_count'] ?? 0,
      likeCount: json['like_count'] ?? 0,
      isLiked: json['is_liked'] == true,
      isPinned: json['is_pinned'] == true,
      pinnedAt: DateTime.tryParse(json['pinned_at'] ?? ''),
      pinnedUntil: DateTime.tryParse(json['pinned_until'] ?? ''),
      pinnedBy: json['pinned_by'] ?? 0,
      pinnedWeight: json['pinned_weight'] ?? 0,
      pinnedReason: json['pinned_reason'] ?? '',
      isFeatured: json['is_featured'] == true,
      featuredAt: DateTime.tryParse(json['featured_at'] ?? ''),
      featuredBy: json['featured_by'] ?? 0,
      featuredReason: json['featured_reason'] ?? '',
      waterSectionPinned: json['water_section_pinned'] == true,
      waterSectionPinId: json['water_section_pin_id'] != null
          ? (json['water_section_pin_id'] as num).toInt()
          : null,
      waterSectionFeatured: json['water_section_featured'] == true,
      waterSectionFeaturedId: json['water_section_featured_id'] != null
          ? (json['water_section_featured_id'] as num).toInt()
          : null,
      homeFeaturedPending: json['home_featured_pending'] == true,
      waterSectionAuthorMeta: json['water_section_author_meta'] != null
          ? WaterSectionAuthorMeta.fromJson(json['water_section_author_meta'])
          : null,
      teamRecruitment: json['team_recruitment_meta'] != null
          ? TeamRecruitmentMeta.fromJson(json['team_recruitment_meta'])
          : null,
      pollMeta: json['poll_meta'] != null
          ? PollMeta.fromJson(json['poll_meta'] as Map<String, dynamic>)
          : null,
      topics: (json['topics'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((e) => Topic.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false) ??
          const [],
      expEarned: json['exp_earned'] != null
          ? (json['exp_earned'] as num).toInt()
          : null,
      expAwards: (json['exp_awards'] as List<dynamic>?)
              ?.map((e) => ExpAward.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => PostImage.fromJson(e))
              .toList() ??
          [],
      author: json['author'] != null ? User.fromJson(json['author']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
      lastActivityAt: DateTime.tryParse(json['last_activity_at'] ?? '') ??
          DateTime.tryParse(json['created_at'] ?? '') ??
          DateTime.now(),
    );
  }

  String get firstImageUrl => images.isNotEmpty ? images.first.url : '';

  bool get isPoll => contentKind == 'poll' && pollMeta != null;

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return const [];
      if (trimmed.startsWith('[')) {
        try {
          return _parseStringList(jsonDecode(trimmed));
        } catch (_) {
          // 兼容旧接口偶发返回普通字符串的情况，继续按逗号切分。
        }
      }
      return trimmed
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  bool get isActivePinned {
    if (!isPinned) return false;
    if (pinnedUntil == null) return true;
    return pinnedUntil!.isAfter(DateTime.now());
  }

  Post copyWith({
    int? id,
    String? title,
    String? content,
    int? boardId,
    int? authorId,
    String? postType,
    String? contentKind,
    double? price,
    String? contactType,
    String? contact,
    List<String>? marketTags,
    int? waterTagId,
    String? status,
    int? viewCount,
    int? replyCount,
    int? likeCount,
    bool? isLiked,
    bool? isPinned,
    DateTime? pinnedAt,
    DateTime? pinnedUntil,
    int? pinnedBy,
    int? pinnedWeight,
    String? pinnedReason,
    bool clearPinnedAt = false,
    bool clearPinnedUntil = false,
    bool? isFeatured,
    DateTime? featuredAt,
    int? featuredBy,
    String? featuredReason,
    bool? waterSectionPinned,
    int? waterSectionPinId,
    bool? waterSectionFeatured,
    int? waterSectionFeaturedId,
    bool? homeFeaturedPending,
    WaterSectionAuthorMeta? waterSectionAuthorMeta,
    TeamRecruitmentMeta? teamRecruitment,
    PollMeta? pollMeta,
    List<Topic>? topics,
    bool clearPollMeta = false,
    bool clearTeamRecruitment = false,
    bool clearTeamRecruitmentMeta = false,
    int? expEarned,
    List<ExpAward>? expAwards,
    List<PostImage>? images,
    User? author,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastActivityAt,
  }) {
    return Post(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      boardId: boardId ?? this.boardId,
      authorId: authorId ?? this.authorId,
      postType: postType ?? this.postType,
      contentKind: contentKind ?? this.contentKind,
      price: price ?? this.price,
      contactType: contactType ?? this.contactType,
      contact: contact ?? this.contact,
      marketTags: marketTags ?? this.marketTags,
      waterTagId: waterTagId ?? this.waterTagId,
      status: status ?? this.status,
      viewCount: viewCount ?? this.viewCount,
      replyCount: replyCount ?? this.replyCount,
      likeCount: likeCount ?? this.likeCount,
      isLiked: isLiked ?? this.isLiked,
      isPinned: isPinned ?? this.isPinned,
      pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
      pinnedUntil: clearPinnedUntil ? null : (pinnedUntil ?? this.pinnedUntil),
      pinnedBy: pinnedBy ?? this.pinnedBy,
      pinnedWeight: pinnedWeight ?? this.pinnedWeight,
      pinnedReason: pinnedReason ?? this.pinnedReason,
      isFeatured: isFeatured ?? this.isFeatured,
      featuredAt: featuredAt ?? this.featuredAt,
      featuredBy: featuredBy ?? this.featuredBy,
      featuredReason: featuredReason ?? this.featuredReason,
      waterSectionPinned: waterSectionPinned ?? this.waterSectionPinned,
      waterSectionPinId: waterSectionPinId ?? this.waterSectionPinId,
      waterSectionFeatured: waterSectionFeatured ?? this.waterSectionFeatured,
      waterSectionFeaturedId:
          waterSectionFeaturedId ?? this.waterSectionFeaturedId,
      homeFeaturedPending: homeFeaturedPending ?? this.homeFeaturedPending,
      waterSectionAuthorMeta:
          waterSectionAuthorMeta ?? this.waterSectionAuthorMeta,
      teamRecruitment: (clearTeamRecruitment || clearTeamRecruitmentMeta)
          ? null
          : (teamRecruitment ?? this.teamRecruitment),
      pollMeta: clearPollMeta ? null : (pollMeta ?? this.pollMeta),
      topics: topics ?? this.topics,
      expEarned: expEarned ?? this.expEarned,
      expAwards: expAwards ?? this.expAwards,
      images: images ?? this.images,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    );
  }
}
