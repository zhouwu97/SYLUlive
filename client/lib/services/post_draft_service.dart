import 'dart:convert';

import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 一条未发布的帖子草稿（C-1）。
class PostDraft {
  const PostDraft({
    required this.title,
    required this.content,
    this.postType = '',
    this.waterTagId,
    this.draftImagePaths = const [],
    required this.updatedAt,
  });

  final String title;
  final String content;
  final String postType;
  final int? waterTagId;

  /// 本地草稿图片路径（顺序即展示顺序）。
  final List<String> draftImagePaths;
  final DateTime updatedAt;

  bool get isEmpty => title.isEmpty && content.isEmpty && draftImagePaths.isEmpty;

  Map<String, dynamic> toJson() => {
        'title': title,
        'content': content,
        'post_type': postType,
        'water_tag_id': waterTagId,
        'draft_image_paths': draftImagePaths,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory PostDraft.fromJson(Map<String, dynamic> json) => PostDraft(
        title: json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        postType: json['post_type']?.toString() ?? '',
        waterTagId: json['water_tag_id'] as int?,
        draftImagePaths:
            (json['draft_image_paths'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// 帖子草稿持久化（C-1）。
///
/// 保存：标题 / 正文 / postType / waterTagId / 本地图片路径顺序 / updatedAt。
/// 复用 AppPreferencesStore，不引入新存储层；composer 负责防抖节流。
class PostDraftService {
  static const String _draftKey = 'post_draft_v1';

  /// 保存草稿（覆盖）。
  Future<void> save(PostDraft draft) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(_draftKey, jsonEncode(draft.toJson()));
  }

  /// 读取草稿；无草稿或损坏时返回 null。
  Future<PostDraft?> load() async {
    final prefs = await AppPreferencesStore.getInstance();
    final encoded = prefs.getString(_draftKey);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return null;
      return PostDraft.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 清空草稿（发布成功 / 用户删除时）。
  Future<void> clear() async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.remove(_draftKey);
  }
}
