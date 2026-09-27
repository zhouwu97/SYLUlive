import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  static const _lastCleanedSchemaKey = '_last_cleaned_schema_version';

  static final Set<Future<void>> _pendingWrites = {};
  static int _activeSessionEpoch = 0;
  static final Map<String, int> _keyWriteVersions = {};
  // 同一缓存键严格串行，清理可以等待已经排队的旧写入完成后再删除。
  static final Map<String, Future<void>> _keyWriteTails = {};

  @visibleForTesting
  static Future<void> Function()? beforeCachePut;

  static void setActiveSessionEpoch(int epoch) {
    _activeSessionEpoch = epoch;
  }

  static set activeSessionEpoch(int epoch) {
    _activeSessionEpoch = epoch;
  }

  static void incrementSessionEpoch() {
    _activeSessionEpoch++;
  }

  static int get activeSessionEpoch => _activeSessionEpoch;

  static Future<void> waitForPendingWrites() async {
    if (_pendingWrites.isEmpty) return;
    try {
      await Future.wait(_pendingWrites.toList(growable: false),
          eagerError: false);
    } catch (e) {
      debugPrint('waitForPendingWrites caught error: $e');
    }
  }

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
    int? sessionEpoch,
  }) async {
    final epoch = sessionEpoch ?? _activeSessionEpoch;
    if (epoch != _activeSessionEpoch) {
      // 旧会话产生的落后写入直接丢弃，不污染新会话
      return;
    }
    final key = _cacheKey(boardId, sort, type: type, tagId: tagId);
    final writeVersion = (_keyWriteVersions[key] ?? 0) + 1;
    _keyWriteVersions[key] = writeVersion;

    final previous = _keyWriteTails[key] ?? Future<void>.value();
    final writeFuture =
        previous.catchError((_) {}).then<void>((_) => _doSavePosts(
              boardId,
              feed,
              sort: sort,
              type: type,
              tagId: tagId,
              sessionEpoch: epoch,
              writeVersion: writeVersion,
            ));
    late final Future<void> tail;
    tail = writeFuture.whenComplete(() {
      if (identical(_keyWriteTails[key], tail)) {
        _keyWriteTails.remove(key);
      }
    });
    _keyWriteTails[key] = tail;
    _pendingWrites.add(tail);
    try {
      await tail;
    } finally {
      _pendingWrites.remove(tail);
    }
  }

  static Future<void> _doSavePosts(
    int boardId,
    CachedPostFeed feed, {
    String sort = 'time',
    String? type,
    int? tagId,
    int? sessionEpoch,
    int? writeVersion,
  }) async {
    final epoch = sessionEpoch ?? _activeSessionEpoch;
    final key = _cacheKey(boardId, sort, type: type, tagId: tagId);
    if (epoch != _activeSessionEpoch ||
        (writeVersion != null &&
            writeVersion < (_keyWriteVersions[key] ?? 0))) {
      return;
    }
    final box = await _openBox();

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
      'session_epoch': epoch,
      'pinned_posts': feed.pinnedPosts.map((p) => _postToJson(p)).toList(),
      'posts': feed.posts.map((p) => _postToJson(p)).toList()
    });
    // 写入前再次校验会话世代与写入版本，确保没有在打开 box 期间发生切号或被新写入抢占
    if (epoch != _activeSessionEpoch ||
        (writeVersion != null &&
            writeVersion < (_keyWriteVersions[key] ?? 0))) {
      return;
    }
    final beforePut = beforeCachePut;
    if (beforePut != null) {
      await beforePut();
    }
    await box.put(key, json);
  }

  /// 从本地缓存读取指定帖子流。
  static Future<CachedPostFeed?> loadPosts(
    int boardId, {
    String sort = 'time',
    String? type,
    int? tagId,
    int? expectedSessionEpoch,
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

      final cachedEpoch = (decoded['session_epoch'] as num?)?.toInt() ?? 0;
      final requiredEpoch = expectedSessionEpoch ?? _activeSessionEpoch;
      if (boardId == 1 && cachedEpoch != requiredEpoch) {
        // 会话世代不匹配，清除旧账号/旧会话缓存
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
      // 解析失败的条目不能继续占位，否则后续启动会反复读到同一坏缓存。
      try {
        await box.delete(key);
      } catch (_) {}
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
  static Future<int> clearLegacyCache({bool force = false}) async {
    final box = await _openBox();
    if (!force) {
      final lastCleaned = box.get(_lastCleanedSchemaKey);
      if (lastCleaned == cacheSchemaVersion.toString()) {
        return 0;
      }
    }
    final keys = box.keys.toList(growable: false);
    int deletedCount = 0;

    for (final key in keys) {
      if (key == _lastCleanedSchemaKey) continue;
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
    await box.put(_lastCleanedSchemaKey, cacheSchemaVersion.toString());
    return deletedCount;
  }

  /// 清理帖子缓存，不触碰认证凭据和其它用户数据。
  ///
  /// 仅由启动恢复等明确的非敏感缓存恢复路径调用。
  static Future<void> clearAllCache() async {
    final box = await _openBox();
    _invalidateWriteVersions(<String>{
      ...box.keys.map((key) => key.toString()),
      ..._keyWriteVersions.keys,
    });
    try {
      await waitForPendingWrites();
    } catch (_) {}
    await box.clear();
  }

  /// 清除指定板块缓存
  static Future<void> clearBoard(int boardId) async {
    final box = await _openBox();
    try {
      final prefix = '$_boardPrefix${boardId}_';
      final keys = <String>{
        ...box.keys
            .map((key) => key.toString())
            .where((key) => key.startsWith(prefix)),
        ..._keyWriteVersions.keys.where((key) => key.startsWith(prefix)),
      };
      _invalidateWriteVersions(keys);
      await waitForPendingWrites();
    } catch (_) {}
    final prefix = '$_boardPrefix${boardId}_';
    final keys = box.keys.where((key) => key.toString().startsWith(prefix));
    await box.deleteAll(keys);
  }

  static void _invalidateWriteVersions(Iterable<String> keys) {
    for (final key in keys) {
      _keyWriteVersions[key] = (_keyWriteVersions[key] ?? 0) + 1;
    }
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
