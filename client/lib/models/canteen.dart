import 'dart:convert';

class Canteen {
  final int id;
  final String name;
  final String image;
  final bool verified;
  final int createdBy;
  final int ratingCount;
  final double averageStar;

  Canteen({
    required this.id,
    required this.name,
    required this.image,
    required this.verified,
    required this.createdBy,
    required this.ratingCount,
    required this.averageStar,
  });

  factory Canteen.fromJson(Map<String, dynamic> json) {
    return Canteen(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      image: json['image'] ?? '',
      verified: json['verified'] ?? false,
      createdBy: json['created_by'] ?? 0,
      ratingCount: json['rating_count'] ?? 0,
      averageStar: (json['average_star'] ?? 0).toDouble(),
    );
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
    );
  }
}
