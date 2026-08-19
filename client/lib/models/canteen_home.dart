/// 食堂发现首页数据模型。
///
/// 对应服务端 GET /canteens/home：hero 推荐 + 排行入口 + 推荐信息流。
/// 每个 feed 条目带稳定 ID（服务端生成），前端用它做 ValueKey，避免刷新跳位。
class CanteenFeedType {
  static const recommendedStore = 'recommended_store';
  static const trendingStore = 'trending';
  static const recentPhoto = 'recent_photo';
  static const stableChoice = 'stable_choice';
  static const newStore = 'new_store';
  static const caution = 'caution';
}

class CanteenFeedItem {
  final String id;
  final String type;
  final int canteenId;
  final String canteenName;
  final int dishId;
  final String dishName;

  final String image;
  final List<String> images;

  final String title;
  final String reason;
  final String createdAt;

  final double rankingScore;
  final double averageStar;
  final int ratingCount;
  final List<String> tags;

  const CanteenFeedItem({
    required this.id,
    required this.type,
    this.canteenId = 0,
    this.canteenName = '',
    this.dishId = 0,
    this.dishName = '',
    this.image = '',
    this.images = const [],
    this.title = '',
    this.reason = '',
    this.createdAt = '',
    this.rankingScore = 0,
    this.averageStar = 0,
    this.ratingCount = 0,
    this.tags = const [],
  });

  factory CanteenFeedItem.fromJson(Map<String, dynamic> json) {
    return CanteenFeedItem(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      canteenId: (json['canteen_id'] ?? 0).toInt(),
      canteenName: json['canteen_name']?.toString() ?? '',
      dishId: (json['dish_id'] ?? 0).toInt(),
      dishName: json['dish_name']?.toString() ?? '',
      image: json['image']?.toString() ?? '',
      images: _toStrList(json['images']),
      title: json['title']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
      rankingScore: (json['ranking_score'] ?? 0).toDouble(),
      averageStar: (json['average_star'] ?? 0).toDouble(),
      ratingCount: (json['rating_count'] ?? 0).toInt(),
      tags: _toStrList(json['tags']),
    );
  }

  bool get isRecommended => type == CanteenFeedType.recommendedStore;
  bool get isTrending => type == CanteenFeedType.trendingStore;
  bool get isRecentPhoto => type == CanteenFeedType.recentPhoto;
  bool get isStable => type == CanteenFeedType.stableChoice;
}

/// Hero 今日推荐卡。
class CanteenHero {
  final int canteenId;
  final String canteenName;
  final String image;
  final double rankingScore;
  final double averageStar;
  final int ratingCount;
  final String title;
  final String reason;
  final List<String> tags;

  const CanteenHero({
    this.canteenId = 0,
    this.canteenName = '',
    this.image = '',
    this.rankingScore = 0,
    this.averageStar = 0,
    this.ratingCount = 0,
    this.title = '',
    this.reason = '',
    this.tags = const [],
  });

  factory CanteenHero.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CanteenHero();
    return CanteenHero(
      canteenId: (json['canteen_id'] ?? 0).toInt(),
      canteenName: json['canteen_name']?.toString() ?? '',
      image: json['image']?.toString() ?? '',
      rankingScore: (json['ranking_score'] ?? 0).toDouble(),
      averageStar: (json['average_star'] ?? 0).toDouble(),
      ratingCount: (json['rating_count'] ?? 0).toInt(),
      title: json['title']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      tags: _toStrList(json['tags']),
    );
  }

  bool get isEmpty => canteenId == 0;
}

/// 排行入口：Top1 + 食堂总数。
class CanteenRankingEntry {
  final int topId;
  final String topName;
  final double topScore;
  final int total;

  const CanteenRankingEntry({
    this.topId = 0,
    this.topName = '',
    this.topScore = 0,
    this.total = 0,
  });

  factory CanteenRankingEntry.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CanteenRankingEntry();
    final top = json['top'];
    final topMap = top is Map<String, dynamic> ? top : null;
    return CanteenRankingEntry(
      topId: (topMap?['id'] ?? 0).toInt(),
      topName: topMap?['name']?.toString() ?? '',
      topScore: (topMap?['ranking_score'] ?? 0).toDouble(),
      total: (json['total'] ?? 0).toInt(),
    );
  }
}

/// 食堂发现首页完整数据。
class CanteenHomeData {
  final CanteenHero hero;
  final CanteenRankingEntry rankingEntry;
  final List<CanteenFeedItem> feed;

  const CanteenHomeData({
    this.hero = const CanteenHero(),
    this.rankingEntry = const CanteenRankingEntry(),
    this.feed = const [],
  });

  factory CanteenHomeData.fromJson(Map<String, dynamic> json) {
    final rawFeed = json['feed'];
    return CanteenHomeData(
      hero: CanteenHero.fromJson(
        json['hero'] is Map<String, dynamic> ? json['hero'] as Map<String, dynamic> : null,
      ),
      rankingEntry: CanteenRankingEntry.fromJson(
        json['ranking_entry'] is Map<String, dynamic>
            ? json['ranking_entry'] as Map<String, dynamic>
            : null,
      ),
      feed: rawFeed is List
          ? rawFeed
              .whereType<Map<String, dynamic>>()
              .map(CanteenFeedItem.fromJson)
              .toList()
          : const [],
    );
  }
}

List<String> _toStrList(dynamic value) {
  if (value is List) {
    return value.map((e) => e?.toString() ?? '').toList();
  }
  return const [];
}
