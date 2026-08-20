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
  final int taste;
  final int value;
  final int portion;
  final String comment;

  const CanteenDishReviewInput({
    required this.dishId,
    required this.taste,
    required this.value,
    required this.portion,
    this.comment = '',
  });

  Map<String, dynamic> toJson() => {
        'dish_id': dishId,
        'taste_score': taste,
        'value_score': value,
        'portion_score': portion,
        if (comment.trim().isNotEmpty) 'comment': comment.trim(),
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
  final DateTime? createdAt;

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
    required this.createdAt,
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
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
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
