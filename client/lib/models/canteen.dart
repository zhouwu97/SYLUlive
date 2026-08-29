import 'dart:convert';

class Canteen {
  final int id;
  final String name;
  final String locationArea;
  final String locationFloor;
  final String image;
  final bool verified;
  final String operatingStatus;
  final int createdBy;
  final int ratingCount;
  final int reviewerCount;
  final int visitReviewCount;
  final double averageStar;
  final Map<String, double> dimensionScores;
  final int dishCount;
  final int dishWithPhotoCount;
  final int dishPhotoCount;
  final double rankingScore;

  Canteen({
    required this.id,
    required this.name,
    this.locationArea = '',
    this.locationFloor = '',
    required this.image,
    required this.verified,
    this.operatingStatus = 'active',
    required this.createdBy,
    required this.ratingCount,
    this.reviewerCount = 0,
    this.visitReviewCount = 0,
    required this.averageStar,
    this.dimensionScores = const {},
    this.dishCount = 0,
    this.dishWithPhotoCount = 0,
    this.dishPhotoCount = 0,
    this.rankingScore = 0,
  });

  factory Canteen.fromJson(Map<String, dynamic> json) {
    return Canteen(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      locationArea: json['location_area']?.toString() ?? '',
      locationFloor: json['location_floor']?.toString() ?? '',
      image: json['image'] ?? '',
      verified: json['verified'] ?? false,
      operatingStatus: json['is_offline'] == true
          ? 'offline'
          : (json['operating_status']?.toString() ?? 'active'),
      createdBy: json['created_by'] ?? 0,
      ratingCount: json['rating_count'] ?? 0,
      reviewerCount: json['reviewer_count'] ?? json['rating_count'] ?? 0,
      visitReviewCount: json['visit_review_count'] ?? json['rating_count'] ?? 0,
      averageStar: (json['average_star'] ?? 0).toDouble(),
      dimensionScores: (json['dimension_scores'] is Map)
          ? (json['dimension_scores'] as Map).map(
              (key, value) =>
                  MapEntry(key.toString(), (value as num?)?.toDouble() ?? 0),
            )
          : const {},
      dishCount: json['dish_count'] ?? 0,
      dishWithPhotoCount: json['dish_with_photo_count'] ?? 0,
      dishPhotoCount: json['dish_photo_count'] ?? 0,
      rankingScore: (json['ranking_score'] ?? 0).toDouble(),
    );
  }

  bool get isOffline => operatingStatus == 'offline';

  /// 位置标签文案，如"一食堂·二楼"；未填写时为空。
  String get locationLabel {
    if (locationArea.isEmpty && locationFloor.isEmpty) return '';
    if (locationArea.isEmpty) return locationFloor;
    if (locationFloor.isEmpty) return locationArea;
    return '$locationArea·$locationFloor';
  }
}

class CanteenRating {
  final int id;
  final int canteenId;
  final int userId;
  final int star;
  final String comment;
  final List<String> images;
  final String userName;
  final String userStudentId;
  final String userAvatar;
  final String createdAt;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote;
  final int tasteScore;
  final int valueScore;
  final int queueScore;
  final int hygieneScore;
  final int serviceScore;
  final int creditScore;
  final double creditWeight;
  final int historyCount;

  CanteenRating({
    required this.id,
    required this.canteenId,
    required this.userId,
    required this.star,
    required this.comment,
    required this.images,
    required this.userName,
    required this.userStudentId,
    required this.userAvatar,
    required this.createdAt,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    this.myVote,
    this.tasteScore = 0,
    this.valueScore = 0,
    this.queueScore = 0,
    this.hygieneScore = 0,
    this.serviceScore = 0,
    this.creditScore = 0,
    this.creditWeight = 0,
    this.historyCount = 0,
  });

  factory CanteenRating.fromJson(Map<String, dynamic> json) {
    List<String> parsedImages = [];
    if (json['images'] != null && json['images'].toString().isNotEmpty) {
      try {
        final decoded = jsonDecode(json['images']);
        if (decoded is List) {
          parsedImages = List<String>.from(decoded);
        }
      } catch (e) {
        // json decode failed
      }
    }
    return CanteenRating(
      id: json['id'] ?? 0,
      canteenId: json['canteen_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      star: json['star'] ?? 0,
      comment: json['comment'] ?? '',
      images: parsedImages,
      userName: json['user_name'] ?? '匿名',
      userStudentId: json['user_student_id'] ?? '',
      userAvatar: json['user_avatar'] ?? '',
      createdAt: json['created_at'] ?? '',
      helpfulCount: json['helpful_count'] ?? 0,
      unhelpfulCount: json['unhelpful_count'] ?? 0,
      myVote: json['my_vote']?.toString(),
      tasteScore: (json['taste_score'] ?? 0).toInt(),
      valueScore: (json['value_score'] ?? 0).toInt(),
      queueScore: (json['queue_score'] ?? 0).toInt(),
      hygieneScore: (json['hygiene_score'] ?? 0).toInt(),
      serviceScore: (json['service_score'] ?? 0).toInt(),
      creditScore: (json['credit_score'] ?? 0).toInt(),
      creditWeight: (json['credit_weight'] ?? 0).toDouble(),
      historyCount: (json['history_count'] ?? 0).toInt(),
    );
  }
}
