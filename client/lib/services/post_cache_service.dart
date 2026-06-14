import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/post.dart';

/// 帖子本地缓存服务（基于 Hive，JSON 序列化，无需 code-gen）
class PostCacheService {
  static const _boxName = 'post_cache';
  static const _boardPrefix = 'board_';

  static Future<Box<String>> _openBox() async {
    return await Hive.openBox<String>(_boxName);
  }

  static String _cacheKey(int boardId, String sort) {
    return '$_boardPrefix${boardId}_$sort';
  }

  /// 保存指定板块的帖子列表到本地缓存
  static Future<void> savePosts(
    int boardId,
    List<Post> posts, {
    String sort = 'time',
  }) async {
    final box = await _openBox();
    final key = _cacheKey(boardId, sort);
    final json = jsonEncode(posts.map((p) => _postToJson(p)).toList());
    await box.put(key, json);
  }

  /// 从本地缓存读取指定板块的帖子列表
  static Future<List<Post>> loadPosts(
    int boardId, {
    String sort = 'time',
  }) async {
    final box = await _openBox();
    final key = _cacheKey(boardId, sort);
    final json = box.get(key);
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 获取缓存中最新的帖子时间戳（用于增量请求）
  static Future<String?> getLatestTimestamp(
    int boardId, {
    String sort = 'time',
  }) async {
    final posts = await loadPosts(boardId, sort: sort);
    if (posts.isEmpty) return null;
    posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return posts.first.createdAt.toUtc().toIso8601String();
  }

  /// 合并新帖子到缓存（新帖在前，去重）
  static Future<void> mergeNewPosts(
    int boardId,
    List<Post> newPosts, {
    String sort = 'time',
  }) async {
    if (newPosts.isEmpty) return;
    final existing = await loadPosts(boardId, sort: sort);
    final existingIds = existing.map((p) => p.id).toSet();
    final uniqueNew =
        newPosts.where((p) => !existingIds.contains(p.id)).toList();
    final merged = [...uniqueNew, ...existing];
    // 限制缓存数量，防止无限增长
    if (merged.length > 200) {
      merged.removeRange(200, merged.length);
    }
    await savePosts(boardId, merged, sort: sort);
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
      'price': post.price,
      'contact': post.contact,
      'status': post.status,
      'view_count': post.viewCount,
      'images': post.images
          .map((img) => {
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
              })
          .toList(),
      'author': post.author != null
          ? {
              'id': post.author!.id,
              'student_id': post.author!.studentId,
              'nickname': post.author!.nickname,
              'avatar': post.author!.avatar,
              'background': post.author!.background,
              'credit_score': post.author!.creditScore,
              'role': post.author!.role,
              'admin_exp': post.author!.adminExp,
              'exp': post.author!.exp,
              'report_count': post.author!.reportCount,
              'created_at': post.author!.createdAt.toIso8601String(),
            }
          : null,
      'created_at': post.createdAt.toUtc().toIso8601String(),
    };
  }
}
