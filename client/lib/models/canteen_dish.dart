/// 菜品图鉴数据模型。
class CanteenDish {
  final int id;
  final String name;
  final int canteenId;
  final String canteenName;
  final String canteenOperatingStatus;
  final String coverImage;
  final int photoCount;
  final String lastPhotoAt;
  final double averageScore;
  final int reviewerCount;

  const CanteenDish({
    required this.id,
    required this.name,
    this.canteenId = 0,
    this.canteenName = '',
    this.canteenOperatingStatus = 'active',
    required this.coverImage,
    required this.photoCount,
    required this.lastPhotoAt,
    this.averageScore = 0,
    this.reviewerCount = 0,
  });

  factory CanteenDish.fromJson(Map<String, dynamic> json) {
    return CanteenDish(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      canteenId: (json['canteen_id'] ?? 0).toInt(),
      canteenName: json['canteen_name']?.toString() ?? '',
      canteenOperatingStatus:
          json['canteen_operating_status']?.toString() ?? 'active',
      coverImage: json['cover_image']?.toString() ?? '',
      photoCount: json['photo_count'] ?? 0,
      lastPhotoAt: json['last_photo_at']?.toString() ?? '',
      averageScore: (json['average_score'] ?? 0).toDouble(),
      reviewerCount: (json['reviewer_count'] ?? 0).toInt(),
    );
  }

  bool get isCanteenOffline => canteenOperatingStatus == 'offline';
}

/// 菜品实拍（公开接口仅含 approved）。
class CanteenDishPhoto {
  final int id;
  final String image;
  final String createdAt;

  const CanteenDishPhoto({
    required this.id,
    required this.image,
    required this.createdAt,
  });

  factory CanteenDishPhoto.fromJson(Map<String, dynamic> json) {
    return CanteenDishPhoto(
      id: json['id'] ?? 0,
      image: json['image']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
    );
  }
}
