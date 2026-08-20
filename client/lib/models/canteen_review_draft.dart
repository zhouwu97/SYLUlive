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

/// 草稿中的单道菜品三维评分。
///
/// 菜名用于旧草稿和菜品列表尚未加载时恢复展示，dishId 用于恢复后准确提交。
class CanteenReviewDraftDishReview {
  final int dishId;
  final String name;
  final int taste;
  final int value;
  final int portion;
  final String comment;

  const CanteenReviewDraftDishReview({
    required this.dishId,
    required this.name,
    required this.taste,
    required this.value,
    required this.portion,
    this.comment = '',
  });

  Map<String, dynamic> toJson() => {
        'dish_id': dishId,
        'name': name,
        'taste': taste,
        'value': value,
        'portion': portion,
        'comment': comment,
      };

  factory CanteenReviewDraftDishReview.fromJson(Map<String, dynamic> json) {
    return CanteenReviewDraftDishReview(
      dishId: (json['dish_id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      taste: (json['taste'] as num?)?.toInt() ?? 0,
      value: (json['value'] as num?)?.toInt() ?? 0,
      portion: (json['portion'] as num?)?.toInt() ?? 0,
      comment: json['comment']?.toString() ?? '',
    );
  }
}

/// 食堂评价草稿
class CanteenReviewDraft {
  static const int currentSchemaVersion = 4;

  final int schemaVersion;
  final int userId;
  final int canteenId;
  final int star;
  final int tasteScore;
  final int valueScore;
  final int queueScore;
  final int hygieneScore;
  final int serviceScore;
  final String comment;
  final List<String> tags;
  final List<String> recommendedDishes;
  final List<CanteenReviewDraftDishReview> dishReviews;
  final List<CanteenReviewDraftImage> images;
  final DateTime updatedAt;

  /// 用户开始修改时，服务端对应已发布评价的更新时间（用于检测是否在其他设备被覆盖更新）
  final DateTime? baseRatingUpdatedAt;

  const CanteenReviewDraft({
    this.schemaVersion = currentSchemaVersion,
    required this.userId,
    required this.canteenId,
    this.star = 0,
    this.tasteScore = 0,
    this.valueScore = 0,
    this.queueScore = 0,
    this.hygieneScore = 0,
    this.serviceScore = 0,
    this.comment = '',
    this.tags = const [],
    this.recommendedDishes = const [],
    this.dishReviews = const [],
    this.images = const [],
    required this.updatedAt,
    this.baseRatingUpdatedAt,
  });

  /// 是否为没有任何有效内容的空草稿
  bool get isEmpty =>
      star == 0 &&
      tasteScore == 0 &&
      valueScore == 0 &&
      queueScore == 0 &&
      hygieneScore == 0 &&
      serviceScore == 0 &&
      comment.trim().isEmpty &&
      tags.isEmpty &&
      recommendedDishes.isEmpty &&
      dishReviews.isEmpty &&
      images.isEmpty;

  CanteenReviewDraft copyWith({
    int? schemaVersion,
    int? userId,
    int? canteenId,
    int? star,
    int? tasteScore,
    int? valueScore,
    int? queueScore,
    int? hygieneScore,
    int? serviceScore,
    String? comment,
    List<String>? tags,
    List<String>? recommendedDishes,
    List<CanteenReviewDraftDishReview>? dishReviews,
    List<CanteenReviewDraftImage>? images,
    DateTime? updatedAt,
    DateTime? baseRatingUpdatedAt,
  }) {
    return CanteenReviewDraft(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      userId: userId ?? this.userId,
      canteenId: canteenId ?? this.canteenId,
      star: star ?? this.star,
      tasteScore: tasteScore ?? this.tasteScore,
      valueScore: valueScore ?? this.valueScore,
      queueScore: queueScore ?? this.queueScore,
      hygieneScore: hygieneScore ?? this.hygieneScore,
      serviceScore: serviceScore ?? this.serviceScore,
      comment: comment ?? this.comment,
      tags: tags ?? this.tags,
      recommendedDishes: recommendedDishes ?? this.recommendedDishes,
      dishReviews: dishReviews ?? this.dishReviews,
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
        'taste_score': tasteScore,
        'value_score': valueScore,
        'queue_score': queueScore,
        'hygiene_score': hygieneScore,
        'service_score': serviceScore,
        'comment': comment,
        'tags': tags,
        'recommended_dishes': recommendedDishes,
        'dish_reviews': dishReviews.map((e) => e.toJson()).toList(),
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
      tasteScore: (json['taste_score'] as num?)?.toInt() ??
          (json['star'] as num?)?.toInt() ??
          0,
      valueScore: (json['value_score'] as num?)?.toInt() ??
          (json['star'] as num?)?.toInt() ??
          0,
      queueScore: (json['queue_score'] as num?)?.toInt() ??
          (json['star'] as num?)?.toInt() ??
          0,
      hygieneScore: (json['hygiene_score'] as num?)?.toInt() ??
          (json['star'] as num?)?.toInt() ??
          0,
      serviceScore: (json['service_score'] as num?)?.toInt() ??
          (json['star'] as num?)?.toInt() ??
          0,
      comment: json['comment']?.toString() ?? '',
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      recommendedDishes: (json['recommended_dishes'] as List?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [],
      dishReviews: (json['dish_reviews'] as List?)
              ?.filterMapJson((m) => CanteenReviewDraftDishReview.fromJson(
                  Map<String, dynamic>.from(m as Map)))
              .where((item) => item.dishId > 0)
              .toList() ??
          const [],
      images: (json['images'] as List?)
              ?.filterMapJson((m) => CanteenReviewDraftImage.fromJson(
                  Map<String, dynamic>.from(m as Map)))
              .toList() ??
          const [],
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
      baseRatingUpdatedAt:
          DateTime.tryParse(json['base_rating_updated_at']?.toString() ?? ''),
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
