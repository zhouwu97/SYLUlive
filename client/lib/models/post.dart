import 'dart:convert';

import 'user.dart';

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

// 帖子图片模型
class PostImage {
  final int id;
  final int postId;
  final int fileId;
  final int sortOrder;
  final FileItem? file;

  PostImage({
    required this.id,
    required this.postId,
    required this.fileId,
    this.sortOrder = 0,
    this.file,
  });

  factory PostImage.fromJson(Map<String, dynamic> json) {
    return PostImage(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      fileId: json['file_id'] ?? 0,
      sortOrder: json['sort_order'] ?? 0,
      file: json['file'] != null ? FileItem.fromJson(json['file']) : null,
    );
  }

  String get url => file?.url ?? '';
}

// 文件模型
class FileItem {
  final int id;
  final String hash;
  final String path;
  final int size;
  final String mimeType;

  FileItem({
    required this.id,
    required this.hash,
    required this.path,
    required this.size,
    required this.mimeType,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      id: json['id'] ?? 0,
      hash: json['hash'] ?? '',
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
      mimeType: json['mime_type'] ?? '',
    );
  }

  String get url => path;
}

// 帖子模型
class Post {
  final int id;
  final String title;
  final String content;
  final int boardId;
  final int authorId;
  final String postType;
  final double price;
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
  final WaterSectionAuthorMeta? waterSectionAuthorMeta;
  final List<PostImage> images;
  final User? author;
  final DateTime createdAt;
  final DateTime updatedAt;

  Post({
    required this.id,
    this.title = '',
    required this.content,
    required this.boardId,
    required this.authorId,
    this.postType = '',
    this.price = 0,
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
    this.waterSectionAuthorMeta,
    this.images = const [],
    this.author,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      boardId: json['board_id'] ?? 1,
      authorId: json['author_id'] ?? 0,
      postType: json['post_type'] ?? '',
      price: (json['price'] ?? 0).toDouble(),
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
      waterSectionAuthorMeta: json['water_section_author_meta'] != null
          ? WaterSectionAuthorMeta.fromJson(json['water_section_author_meta'])
          : null,
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => PostImage.fromJson(e))
              .toList() ??
          [],
      author: json['author'] != null ? User.fromJson(json['author']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
    );
  }

  String get firstImageUrl => images.isNotEmpty ? images.first.url : '';

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
    double? price,
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
    List<PostImage>? images,
    User? author,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Post(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      boardId: boardId ?? this.boardId,
      authorId: authorId ?? this.authorId,
      postType: postType ?? this.postType,
      price: price ?? this.price,
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
      waterSectionFeaturedId: waterSectionFeaturedId ?? this.waterSectionFeaturedId,
      images: images ?? this.images,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
