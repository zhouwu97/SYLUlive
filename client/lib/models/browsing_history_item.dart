/// 浏览历史记录类型
enum BrowsingHistoryType {
  /// 校园资讯
  campusNews,

  /// 社区帖子
  post,
}

extension BrowsingHistoryTypeExtension on BrowsingHistoryType {
  String get label => switch (this) {
        BrowsingHistoryType.campusNews => '校园资讯',
        BrowsingHistoryType.post => '帖子',
      };
}

/// 浏览历史记录条目
class BrowsingHistoryItem {
  final String id;
  final String targetId;
  final BrowsingHistoryType type;
  final String titleSnapshot;
  final String? authorSnapshot;
  final String? coverSnapshot;
  final DateTime viewedAt;

  const BrowsingHistoryItem({
    required this.id,
    required this.targetId,
    required this.type,
    required this.titleSnapshot,
    this.authorSnapshot,
    this.coverSnapshot,
    required this.viewedAt,
  });

  /// 唯一逻辑键：type + targetId
  String get logicalKey => '${type.name}_$targetId';

  BrowsingHistoryItem copyWith({
    String? id,
    String? targetId,
    BrowsingHistoryType? type,
    String? titleSnapshot,
    String? authorSnapshot,
    String? coverSnapshot,
    DateTime? viewedAt,
  }) {
    return BrowsingHistoryItem(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      type: type ?? this.type,
      titleSnapshot: titleSnapshot ?? this.titleSnapshot,
      authorSnapshot: authorSnapshot ?? this.authorSnapshot,
      coverSnapshot: coverSnapshot ?? this.coverSnapshot,
      viewedAt: viewedAt ?? this.viewedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'target_id': targetId,
        'type': type.name,
        'title_snapshot': titleSnapshot,
        if (authorSnapshot != null) 'author_snapshot': authorSnapshot,
        if (coverSnapshot != null) 'cover_snapshot': coverSnapshot,
        'viewed_at': viewedAt.toIso8601String(),
      };

  factory BrowsingHistoryItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type']?.toString();
    final type = BrowsingHistoryType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => BrowsingHistoryType.post,
    );

    return BrowsingHistoryItem(
      id: json['id']?.toString() ?? '',
      targetId: json['target_id']?.toString() ?? '',
      type: type,
      titleSnapshot: json['title_snapshot']?.toString() ?? '',
      authorSnapshot: json['author_snapshot']?.toString(),
      coverSnapshot: json['cover_snapshot']?.toString(),
      viewedAt: DateTime.tryParse(json['viewed_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
