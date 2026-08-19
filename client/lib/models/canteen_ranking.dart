/// 食堂完整排行榜数据模型。
/// 对应服务端 GET /canteens/rankings。rank 由服务端返回（Bayesian 稳定排序），
/// 客户端绝不自行 index+1 当绝对排名。
class CanteenRankingItem {
  final int rank;
  final int id;
  final String name;
  final String image;

  final double averageStar;
  final int ratingCount;

  final double rankingScore;
  final String confidence; // low / medium / high

  final int dishCount;
  final int dishPhotoCount;

  final List<SummaryTag> summaryTags;

  const CanteenRankingItem({
    required this.rank,
    required this.id,
    required this.name,
    this.image = '',
    this.averageStar = 0,
    this.ratingCount = 0,
    this.rankingScore = 0,
    this.confidence = 'low',
    this.dishCount = 0,
    this.dishPhotoCount = 0,
    this.summaryTags = const [],
  });

  factory CanteenRankingItem.fromJson(Map<String, dynamic> json) {
    final rawTags = json['summary_tags'];
    return CanteenRankingItem(
      rank: (json['rank'] ?? 0).toInt(),
      id: (json['id'] ?? 0).toInt(),
      name: json['name']?.toString() ?? '',
      image: json['image']?.toString() ?? '',
      averageStar: (json['average_star'] ?? 0).toDouble(),
      ratingCount: (json['rating_count'] ?? 0).toInt(),
      rankingScore: (json['ranking_score'] ?? 0).toDouble(),
      confidence: json['confidence']?.toString() ?? 'low',
      dishCount: (json['dish_count'] ?? 0).toInt(),
      dishPhotoCount: (json['dish_photo_count'] ?? 0).toInt(),
      summaryTags: rawTags is List
          ? rawTags
              .whereType<Map<String, dynamic>>()
              .map(SummaryTag.fromJson)
              .toList()
          : const [],
    );
  }

  /// 样本提示（UI 置信提示，不改公式）。
  String get sampleHint {
    if (ratingCount < 3) return '样本很少';
    if (ratingCount < 6) return '样本较少';
    return '';
  }
}

class SummaryTag {
  final String key;
  final String name;
  final int count;

  const SummaryTag({required this.key, required this.name, required this.count});

  factory SummaryTag.fromJson(Map<String, dynamic> json) {
    return SummaryTag(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      count: (json['count'] ?? 0).toInt(),
    );
  }
}

/// 排行页排序模式。
class CanteenRankingSort {
  static const composite = 'composite';
  static const rating = 'rating';
  static const reviewCount = 'review_count';

  static const values = [composite, rating, reviewCount];
}
