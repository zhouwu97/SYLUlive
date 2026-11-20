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

  /// 图片型菜品入口只展示存在有效图片地址的数据，避免用占位图冒充实拍。
  bool get hasDisplayImage => coverImage.trim().isNotEmpty;
}

/// 管理端菜品条目：包含已隐藏的菜，用于改名、隐藏/恢复与合并。
class AdminCanteenDish {
  final int id;
  final String name;
  final String status;
  final int photoCount;
  final int mentionCount;

  const AdminCanteenDish({
    required this.id,
    required this.name,
    required this.status,
    this.photoCount = 0,
    this.mentionCount = 0,
  });

  factory AdminCanteenDish.fromJson(Map<String, dynamic> json) {
    return AdminCanteenDish(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      status: json['status']?.toString() ?? 'active',
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
      mentionCount: (json['mention_count'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isHidden => status == 'hidden';
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
