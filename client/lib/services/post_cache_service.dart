import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/post.dart';

enum PostFeedCacheFreshness {
  fresh,
  stale,
  expired,
}

class CachedPostFeed {
  final List<Post> posts;
  final List<Post> pinnedPosts;
  final String algorithmVersion;
  final PostFeedCacheFreshness freshness;

  const CachedPostFeed({
    required this.posts,
    this.pinnedPosts = const [],
    this.algorithmVersion = '',
    this.freshness = PostFeedCacheFreshness.fresh,
  });
}

/// 帖子本地缓存服务（基于 Hive，JSON 序列化，无需 code-gen）
class PostCacheService {
  static const int cacheSchemaVersion = 7;
  static const String homeAllAlgorithmVersion = 'home_all_v3_poll';
  static const String homeTimeAlgorithmVersion = 'home_time_v3_poll';
  static const String fallbackAlgorithmVersion = 'feed_v1';
  static const _boxName = 'post_cache';
  static const _boardPrefix = 'board_';

  static Future<Box<String>> _openBox() async {
    return await Hive.openBox<String>(_boxName);
  }

  static String _cacheKey(
    int boardId,
    String sort, {
    String? type,
    int? tagId,
  }) {
    final normalizedType = (type ?? '').trim();
    return '$_boardPrefix${boardId}_${sort}_${normalizedType}_${tagId ?? ''}';
  }

  static String expectedAlgorithmVersion({
    required int boardId,
    required String sort,
    String? type,
    int? tagId,
  }) {
    final normalizedType = type?.trim() ?? '';
    final usesHomeFeedV2 = boardId == 1 &&
        normalizedType.isEmpty &&
        tagId == null &&
        (sort == 'all' || sort == 'time');
    if (usesHomeFeedV2) {
      return sort == 'all' ? homeAllAlgorithmVersion : homeTimeAlgorithmVersion;
    }
    return fallbackAlgorithmVersion;
  }

  /// 保存指定帖子流到本地缓存，按 board/sort/section/tag 隔离。
  static Future<void> savePosts(
    int boardId,
    CachedPostFeed feed, {
    String sort = 'time',
    String? type,
    int? tagId,
  }) async {
    final box = await _openBox();
    final key = _cacheKey(boardId, sort, type: type, tagId: tagId);

    final expectedVersion = expectedAlgorithmVersion(
      boardId: boardId,
      sort: sort,
      type: type,
      tagId: tagId,
    );
    final storedVersion = feed.algorithmVersion.isNotEmpty
        ? feed.algorithmVersion
        : expectedVersion;

    final json = jsonEncode({
      'schema_version': cacheSchemaVersion,
      'algorithm_version': storedVersion,
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'pinned_posts': feed.pinnedPosts.map((p) => _postToJson(p)).toList(),
      'posts': feed.posts.map((p) => _postToJson(p)).toList()
    });
    await box.put(key, json);
  }

  /// 从本地缓存读取指定帖子流。
  static Future<CachedPostFeed?> loadPosts(
    int boardId, {
    String sort = 'time',
    String? type,
    int? tagId,
  }) async {
    final box = await _openBox();
    final key = _cacheKey(boardId, sort, type: type, tagId: tagId);
    final json = box.get(key);
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema_version'] != cacheSchemaVersion) {
        await box.delete(key);
        return null;
      }
      final savedAt = DateTime.tryParse(decoded['saved_at']?.toString() ?? '');
      if (savedAt == null) {
        await box.delete(key);
        return null;
      }

      final age = DateTime.now().difference(savedAt);
      if (age > const Duration(hours: 24)) {
        await box.delete(key);
        return null;
      }

      final cachedAlgorithm = decoded['algorithm_version']?.toString() ?? '';
      final expectedAlgo = expectedAlgorithmVersion(
          boardId: boardId, sort: sort, type: type, tagId: tagId);
      if (cachedAlgorithm != expectedAlgo) {
        await box.delete(key);
        return null;
      }

      final list = (decoded['posts'] as List?) ?? const <dynamic>[];
      final pinnedList =
          (decoded['pinned_posts'] as List?) ?? const <dynamic>[];

      final posts =
          list.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
      final pinnedPosts = pinnedList
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList();

      return CachedPostFeed(
        posts: posts,
        pinnedPosts: pinnedPosts,
        algorithmVersion: cachedAlgorithm,
        freshness: age > const Duration(minutes: 10)
            ? PostFeedCacheFreshness.stale
            : PostFeedCacheFreshness.fresh,
      );
    } catch (_) {
      return null;
    }
  }

  /// 获取缓存中最新的帖子时间戳（用于增量请求）
  static Future<String?> getLatestTimestamp(
    int boardId, {
    String sort = 'time',
    String? type,
    int? tagId,
  }) async {
    final feed = await loadPosts(
      boardId,
      sort: sort,
      type: type,
      tagId: tagId,
    );
    if (feed == null || feed.posts.isEmpty) return null;
    final posts = feed.posts;
    posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return posts.first.createdAt.toUtc().toIso8601String();
  }

  /// 合并新帖子到缓存（新帖在前，去重）
  static Future<void> mergeNewPosts(
    int boardId,
    List<Post> newPosts, {
    String sort = 'time',
    String? type,
    int? tagId,
  }) async {
    if (newPosts.isEmpty) return;
    final feed = await loadPosts(
      boardId,
      sort: sort,
      type: type,
      tagId: tagId,
    );
    final existing = feed?.posts ?? [];
    final existingIds = existing.map((p) => p.id).toSet();
    final uniqueNew =
        newPosts.where((p) => !existingIds.contains(p.id)).toList();
    final merged = [...uniqueNew, ...existing];
    // 限制缓存数量，防止无限增长
    if (merged.length > 200) {
      merged.removeRange(200, merged.length);
    }

    final algorithmVersion = feed?.algorithmVersion ??
        expectedAlgorithmVersion(
          boardId: boardId,
          sort: sort,
          type: type,
          tagId: tagId,
        );
    final pinnedPosts = feed?.pinnedPosts ?? [];

    await savePosts(
        boardId,
        CachedPostFeed(
          posts: merged,
          pinnedPosts: pinnedPosts,
          algorithmVersion: algorithmVersion,
        ),
        sort: sort,
        type: type,
        tagId: tagId);
  }

  /// 清理旧版或损坏的缓存数据
  static Future<int> clearLegacyCache() async {
    final box = await _openBox();
    final keys = box.keys.toList(growable: false);
    int deletedCount = 0;

    for (final key in keys) {
      final raw = box.get(key);

      if (raw == null || raw.isEmpty) {
        await box.delete(key);
        deletedCount++;
        continue;
      }

      try {
        final decoded = jsonDecode(raw);

        if (decoded is! Map<String, dynamic> ||
            decoded['schema_version'] != cacheSchemaVersion) {
          await box.delete(key);
          deletedCount++;
        }
      } catch (_) {
        await box.delete(key);
        deletedCount++;
      }
    }
    return deletedCount;
  }

  /// 清除指定板块缓存
  static Future<void> clearBoard(int boardId) async {
    final box = await _openBox();
    final prefix = '$_boardPrefix${boardId}_';
    final keys = box.keys.where((key) => key.toString().startsWith(prefix));
    await box.deleteAll(keys);
  }

  static Map<String, dynamic> _postToJson(Post post) {
    return {
      'id': post.id,
      'title': post.title,
      'content': post.content,
      'board_id': post.boardId,
      'author_id': post.authorId,
      'post_type': post.postType,
      'content_kind': post.contentKind,
      'price': post.price,
      'contact_type': post.contactType,
      'contact': post.contact,
      'market_tags': post.marketTags,
      'water_tag_id': post.waterTagId,
      'status': post.status,
      'view_count': post.viewCount,
      'reply_count': post.replyCount,
      'like_count': post.likeCount,
      'is_liked': post.isLiked,
      'is_pinned': post.isPinned,
      'pinned_at': post.pinnedAt?.toUtc().toIso8601String(),
      'pinned_until': post.pinnedUntil?.toUtc().toIso8601String(),
      'pinned_by': post.pinnedBy,
      'pinned_weight': post.pinnedWeight,
      'pinned_reason': post.pinnedReason,
      'is_featured': post.isFeatured,
      'featured_at': post.featuredAt?.toUtc().toIso8601String(),
      'featured_by': post.featuredBy,
      'featured_reason': post.featuredReason,
      'water_section_pinned': post.waterSectionPinned,
      'water_section_pin_id': post.waterSectionPinId,
      'water_section_featured': post.waterSectionFeatured,
      'water_section_featured_id': post.waterSectionFeaturedId,
      'home_featured_pending': post.homeFeaturedPending,
      'water_section_author_meta': post.waterSectionAuthorMeta != null
          ? {
              'section_id': post.waterSectionAuthorMeta!.sectionId,
              'section_slug': post.waterSectionAuthorMeta!.sectionSlug,
              'section_title': post.waterSectionAuthorMeta!.sectionTitle,
              'level': post.waterSectionAuthorMeta!.level,
              'exp': post.waterSectionAuthorMeta!.exp,
              'title': post.waterSectionAuthorMeta!.title,
            }
          : null,
      'team_recruitment_meta': post.teamRecruitment?.toJson(),
      'poll_meta': post.pollMeta?.toJson(),
      'topics': post.topics.map((topic) => topic.toJson()).toList(),
      'images': post.images
          .map(
            (img) => {
              'id': img.id,
              'post_id': img.postId,
              'file_id': img.fileId,
              'sort_order': img.sortOrder,
              'file': img.file != null
                  ? {
                      'id': img.file!.id,
                      'hash': img.file!.hash,
                      'path': img.file!.path,
                      'size': img.file!.size,
                      'mime_type': img.file!.mimeType,
                    }
                  : null,
            },
          )
          .toList(),
      'author': post.author != null
          ? {
              'id': post.author!.id,
              'nickname': post.author!.nickname,
              'avatar': post.author!.avatar,
              'background': post.author!.background,
              'exp': post.author!.exp,
              'credit_score': post.author!.creditScore,
            }
          : null,
      'created_at': post.createdAt.toUtc().toIso8601String(),
      'updated_at': post.updatedAt.toUtc().toIso8601String(),
      'last_activity_at': post.lastActivityAt.toUtc().toIso8601String(),
    };
  }
}
