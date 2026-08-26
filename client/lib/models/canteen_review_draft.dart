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
  final int? dishId;
  final String? dishName;

  const CanteenReviewDraftImage({
    required this.type,
    this.localPath,
    this.fileId,
    this.url,
    this.dishId,
    this.dishName,
  });

  CanteenReviewDraftImage copyWith({
    ReviewDraftImageType? type,
    String? localPath,
    int? fileId,
    String? url,
    int? dishId,
    String? dishName,
  }) {
    return CanteenReviewDraftImage(
      type: type ?? this.type,
      localPath: localPath ?? this.localPath,
      fileId: fileId ?? this.fileId,
      url: url ?? this.url,
      dishId: dishId ?? this.dishId,
      dishName: dishName ?? this.dishName,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'local_path': localPath,
        'file_id': fileId,
        'url': url,
        'dish_id': dishId,
        'dish_name': dishName,
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
      dishId: (json['dish_id'] as num?)?.toInt(),
      dishName: json['dish_name']?.toString(),
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
  static const int currentSchemaVersion = 6;

  final int schemaVersion;
  final int userId;
  final int canteenId;

  /// 草稿所属业务流程：create 为新增评价，edit 为修改最近一条 V2 评价。
  final String mode;

  /// edit 草稿对应的 ReviewEvent ID；create 草稿固定为空。
  final int? reviewEventId;
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

  /// 一次评价提交的幂等键。上传成功但请求超时后重试时必须复用同一键。
  final String? submitIdempotencyKey;

  const CanteenReviewDraft({
    this.schemaVersion = currentSchemaVersion,
    required this.userId,
    required this.canteenId,
    this.mode = 'create',
    this.reviewEventId,
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
    this.submitIdempotencyKey,
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
    String? mode,
    int? reviewEventId,
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
    String? submitIdempotencyKey,
  }) {
    return CanteenReviewDraft(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      userId: userId ?? this.userId,
      canteenId: canteenId ?? this.canteenId,
      mode: mode ?? this.mode,
      reviewEventId: reviewEventId ?? this.reviewEventId,
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
      submitIdempotencyKey: submitIdempotencyKey ?? this.submitIdempotencyKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'user_id': userId,
        'canteen_id': canteenId,
        'mode': mode,
        'review_event_id': reviewEventId,
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
        'submit_idempotency_key': submitIdempotencyKey,
      };

  factory CanteenReviewDraft.fromJson(Map<String, dynamic> json) {
    return CanteenReviewDraft(
      schemaVersion:
          (json['schema_version'] as num?)?.toInt() ?? currentSchemaVersion,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      canteenId: (json['canteen_id'] as num?)?.toInt() ?? 0,
      mode: json['mode']?.toString() == 'edit' ? 'edit' : 'create',
      reviewEventId: (json['review_event_id'] as num?)?.toInt(),
      star: (json['star'] as num?)?.toInt() ?? 0,
      // 五维评分是独立字段。旧草稿没有这些字段时保持未填写，不能把旧版星级
      // 复制到每个维度，否则恢复草稿会伪造用户从未填写过的业务数据。
      tasteScore: (json['taste_score'] as num?)?.toInt() ?? 0,
      valueScore: (json['value_score'] as num?)?.toInt() ?? 0,
      queueScore: (json['queue_score'] as num?)?.toInt() ?? 0,
      hygieneScore: (json['hygiene_score'] as num?)?.toInt() ?? 0,
      serviceScore: (json['service_score'] as num?)?.toInt() ?? 0,
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
      submitIdempotencyKey: json['submit_idempotency_key']?.toString(),
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
