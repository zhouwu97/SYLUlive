import 'dart:convert';

/// 草稿图片状态类型
enum ReviewDraftImageType {
  /// 已发布的远端图片（编辑已有评价时的历史图片）
  publishedRemote,

  /// 本地待上传的图片（存放在沙盒草稿目录中）
  localPending,

  /// 上传成功但整个评价尚未成功提交的图片（断网重试时复用 fileId 与 url）
  uploadedPending,
}

/// 单张草稿图片模型
class CanteenReviewDraftImage {
  final ReviewDraftImageType type;
  final String? localPath;
  final int? fileId;
  final String? url;

  const CanteenReviewDraftImage({
    required this.type,
    this.localPath,
    this.fileId,
    this.url,
  });

  CanteenReviewDraftImage copyWith({
    ReviewDraftImageType? type,
    String? localPath,
    int? fileId,
    String? url,
  }) {
    return CanteenReviewDraftImage(
      type: type ?? this.type,
      localPath: localPath ?? this.localPath,
      fileId: fileId ?? this.fileId,
      url: url ?? this.url,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'local_path': localPath,
        'file_id': fileId,
        'url': url,
      };

  factory CanteenReviewDraftImage.fromJson(Map<String, dynamic> json) {
    final typeName = json['type']?.toString();
    final type = ReviewDraftImageType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => ReviewDraftImageType.localPending,
    );
    return CanteenReviewDraftImage(
      type: type,
      localPath: json['local_path']?.toString(),
      fileId: (json['file_id'] as num?)?.toInt(),
      url: json['url']?.toString(),
    );
  }
}

/// 食堂评价草稿
class CanteenReviewDraft {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final int userId;
  final int canteenId;
  final int star;
  final String comment;
  final List<String> tags;
  final List<int> recommendedDishIds;
  final List<CanteenReviewDraftImage> images;
  final DateTime updatedAt;

  /// 用户开始修改时，服务端对应已发布评价的更新时间（用于检测是否在其他设备被覆盖更新）
  final DateTime? baseRatingUpdatedAt;

  const CanteenReviewDraft({
    this.schemaVersion = currentSchemaVersion,
    required this.userId,
    required this.canteenId,
    this.star = 0,
    this.comment = '',
    this.tags = const [],
    this.recommendedDishIds = const [],
    this.images = const [],
    required this.updatedAt,
    this.baseRatingUpdatedAt,
  });

  /// 是否为没有任何有效内容的空草稿
  bool get isEmpty =>
      star == 0 &&
      comment.trim().isEmpty &&
      tags.isEmpty &&
      recommendedDishIds.isEmpty &&
      images.isEmpty;

  CanteenReviewDraft copyWith({
    int? schemaVersion,
    int? userId,
    int? canteenId,
    int? star,
    String? comment,
    List<String>? tags,
    List<int>? recommendedDishIds,
    List<CanteenReviewDraftImage>? images,
    DateTime? updatedAt,
    DateTime? baseRatingUpdatedAt,
  }) {
    return CanteenReviewDraft(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      userId: userId ?? this.userId,
      canteenId: canteenId ?? this.canteenId,
      star: star ?? this.star,
      comment: comment ?? this.comment,
      tags: tags ?? this.tags,
      recommendedDishIds: recommendedDishIds ?? this.recommendedDishIds,
      images: images ?? this.images,
      updatedAt: updatedAt ?? this.updatedAt,
      baseRatingUpdatedAt: baseRatingUpdatedAt ?? this.baseRatingUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'user_id': userId,
        'canteen_id': canteenId,
        'star': star,
        'comment': comment,
        'tags': tags,
        'recommended_dish_ids': recommendedDishIds,
        'images': images.map((e) => e.toJson()).toList(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'base_rating_updated_at':
            baseRatingUpdatedAt?.toUtc().toIso8601String(),
      };

  factory CanteenReviewDraft.fromJson(Map<String, dynamic> json) {
    return CanteenReviewDraft(
      schemaVersion:
          (json['schema_version'] as num?)?.toInt() ?? currentSchemaVersion,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      canteenId: (json['canteen_id'] as num?)?.toInt() ?? 0,
      star: (json['star'] as num?)?.toInt() ?? 0,
      comment: json['comment']?.toString() ?? '',
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      recommendedDishIds: (json['recommended_dish_ids'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      images: (json['images'] as List?)
              ?.filterMapJson(
                  (m) => CanteenReviewDraftImage.fromJson(m as Map<String, dynamic>))
              .toList() ??
          const [],
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
      baseRatingUpdatedAt: DateTime.tryParse(
          json['base_rating_updated_at']?.toString() ?? ''),
    );
  }
}

extension on List {
  Iterable<T> filterMapJson<T>(T Function(dynamic) transform) sync* {
    for (final item in this) {
      if (item is Map) {
        yield transform(item);
      }
    }
  }
}
