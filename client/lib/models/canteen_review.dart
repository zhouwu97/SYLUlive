import 'dart:convert';

/// 店铺五维评价的客户端模型与评分常量。
class CanteenReviewDimensions {
  final int taste;
  final int value;
  final int queue;
  final int hygiene;
  final int service;

  const CanteenReviewDimensions({
    this.taste = 0,
    this.value = 0,
    this.queue = 0,
    this.hygiene = 0,
    this.service = 0,
  });

  bool get isComplete => [taste, value, queue, hygiene, service]
      .every((score) => score >= 1 && score <= 5);

  double get overall =>
      taste * .35 + value * .20 + queue * .15 + hygiene * .20 + service * .10;

  Map<String, dynamic> toJson() => {
        'taste_score': taste,
        'value_score': value,
        'queue_score': queue,
        'hygiene_score': hygiene,
        'service_score': service,
      };

  CanteenReviewDimensions copyWith({
    int? taste,
    int? value,
    int? queue,
    int? hygiene,
    int? service,
  }) {
    return CanteenReviewDimensions(
      taste: taste ?? this.taste,
      value: value ?? this.value,
      queue: queue ?? this.queue,
      hygiene: hygiene ?? this.hygiene,
      service: service ?? this.service,
    );
  }
}

class CanteenDishReviewInput {
  final int dishId;
  final String dishName;
  final int taste;
  final int value;
  final int portion;
  final String comment;
  final List<int> photoFileIds;

  const CanteenDishReviewInput({
    required this.dishId,
    this.dishName = '',
    required this.taste,
    required this.value,
    required this.portion,
    this.comment = '',
    this.photoFileIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'dish_id': dishId,
        if (dishName.trim().isNotEmpty) 'dish_name': dishName.trim(),
        'taste_score': taste,
        'value_score': value,
        'portion_score': portion,
        if (comment.trim().isNotEmpty) 'comment': comment.trim(),
        if (photoFileIds.isNotEmpty) 'photo_file_ids': photoFileIds,
      };
}

class CanteenReviewEvent {
  final int id;
  final int canteenId;
  final int userId;
  final CanteenReviewDimensions dimensions;
  final double overallScore;
  final int scoreVersion;
  final String comment;
  final String userName;
  final String userAvatar;
  final int creditScore;
  final double creditWeight;
  final int historyCount;
  final int helpfulCount;
  final int unhelpfulCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<String> images;
  final List<String> tags;
  final List<String> recommendedDishes;
  final List<Map<String, dynamic>> recommendedDishDetails;
  final List<Map<String, dynamic>> dishReviews;
  final List<Map<String, dynamic>> dishPhotos;
  final String source;
  final CanteenReviewCanteen? canteen;
  final bool canEdit;
  final bool canDelete;
  final int? legacyRatingId;

  const CanteenReviewEvent({
    required this.id,
    required this.canteenId,
    required this.userId,
    required this.dimensions,
    required this.overallScore,
    this.scoreVersion = 2,
    required this.comment,
    required this.userName,
    required this.userAvatar,
    required this.creditScore,
    required this.creditWeight,
    required this.historyCount,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    required this.createdAt,
    this.updatedAt,
    this.images = const [],
    this.tags = const [],
    this.recommendedDishes = const [],
    this.recommendedDishDetails = const [],
    this.dishReviews = const [],
    this.dishPhotos = const [],
    this.source = 'v2',
    this.canteen,
    this.canEdit = false,
    this.canDelete = false,
    this.legacyRatingId,
  });

  factory CanteenReviewEvent.fromJson(Map<String, dynamic> json) {
    return CanteenReviewEvent(
      id: _int(json['id']),
      canteenId: _int(json['canteen_id']),
      userId: _int(json['user_id']),
      dimensions: CanteenReviewDimensions(
        taste: _int(json['taste_score']),
        value: _int(json['value_score']),
        queue: _int(json['queue_score']),
        hygiene: _int(json['hygiene_score']),
        service: _int(json['service_score']),
      ),
      overallScore: _double(json['overall_score']),
      scoreVersion: _int(json['score_version']),
      comment: json['comment']?.toString() ?? '',
      userName: json['user_name']?.toString() ?? '匿名同学',
      userAvatar: json['user_avatar']?.toString() ?? '',
      creditScore: _int(json['credit_score']),
      creditWeight: _double(json['credit_weight']),
      historyCount: _int(json['history_count']),
      helpfulCount: _int(json['helpful_count']),
      unhelpfulCount: _int(json['unhelpful_count']),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      images: _stringList(json['images']),
      tags: _stringList(json['tags']),
      recommendedDishes: _recommendedDishNames(json['recommended_dishes']),
      recommendedDishDetails: _mapList(json['recommended_dish_details']),
      dishReviews: _mapList(json['dish_reviews']),
      dishPhotos: _mapList(json['dish_photos']),
      source: json['source']?.toString() ??
          json['review_source']?.toString() ??
          'v2',
      canteen: json['canteen'] is Map
          ? CanteenReviewCanteen.fromJson(
              Map<String, dynamic>.from(json['canteen'] as Map),
            )
          : null,
      canEdit: json['can_edit'] == true,
      canDelete: json['can_delete'] == true,
      legacyRatingId: json['legacy_rating_id'] == null
          ? null
          : _int(json['legacy_rating_id']),
    );
  }
}

List<Map<String, dynamic>> _mapList(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

class CanteenReviewCanteen {
  final int id;
  final String name;
  final String image;
  final String operatingStatus;
  final bool isOffline;

  const CanteenReviewCanteen({
    required this.id,
    required this.name,
    required this.image,
    required this.operatingStatus,
    required this.isOffline,
  });

  factory CanteenReviewCanteen.fromJson(Map<String, dynamic> json) {
    return CanteenReviewCanteen(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      image: json['image']?.toString() ?? '',
      operatingStatus: json['operating_status']?.toString() ?? 'active',
      isOffline: json['is_offline'] == true ||
          json['operating_status']?.toString() == 'offline',
    );
  }
}

class CanteenReviewPage {
  final List<CanteenReviewEvent> items;
  final String? nextCursor;
  final bool hasMore;

  const CanteenReviewPage({
    required this.items,
    this.nextCursor,
    this.hasMore = false,
  });
}

class CanteenDishSuggestion {
  final int dishId;
  final String name;
  final String matchType;
  final int ratingCount;

  const CanteenDishSuggestion({
    required this.dishId,
    required this.name,
    required this.matchType,
    required this.ratingCount,
  });

  bool get isExact => matchType == 'exact' || matchType == 'alias';

  factory CanteenDishSuggestion.fromJson(Map<String, dynamic> json) {
    return CanteenDishSuggestion(
      dishId: _int(json['dish_id']),
      name: json['name']?.toString() ?? '',
      matchType: json['match_type']?.toString() ?? 'possible',
      ratingCount: _int(json['rating_count']),
    );
  }
}

int _int(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
double _double(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List
        ? decoded
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false)
        : const [];
  } catch (_) {
    return const [];
  }
}

List<String> _recommendedDishNames(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) =>
          item is Map ? item['name']?.toString() ?? '' : item.toString())
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
