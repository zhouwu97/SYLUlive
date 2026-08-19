import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/canteen_review_draft.dart';
import '../platform/contracts/preferences_store.dart';

/// 食堂评价草稿仓储层。
///
/// 遵循规则：
/// 1. 使用 AppPreferencesStore 进行跨平台存储抽象，禁止直接硬编码 SharedPreferences。
/// 2. Key 规则：canteen_review_draft:v1:{userId}:{canteenId}，严格账号隔离。
/// 3. 本地图片保存在 ApplicationSupportDirectory/canteen_review_drafts/{userId}/{canteenId}/。
class CanteenReviewDraftRepository {
  final AppPreferencesStore? _storeOverride;
  final Directory? _baseDirOverride;

  const CanteenReviewDraftRepository({
    AppPreferencesStore? storeOverride,
    Directory? baseDirOverride,
  })  : _storeOverride = storeOverride,
        _baseDirOverride = baseDirOverride;

  static String buildKey(int userId, int canteenId) =>
      'canteen_review_draft:v1:$userId:$canteenId';

  Future<AppPreferencesStore> _getStore() async {
    if (_storeOverride != null) return _storeOverride!;
    return AppPreferencesStore.getInstance();
  }

  Future<Directory> getDraftDirectory({
    required int userId,
    required int canteenId,
  }) async {
    final baseDir = _baseDirOverride ?? await getApplicationSupportDirectory();
    final dir = Directory(
      '${baseDir.path}/canteen_review_drafts/$userId/$canteenId',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 保存草稿。如果是空草稿，则执行删除。
  Future<void> saveDraft(CanteenReviewDraft draft) async {
    if (draft.userId <= 0 || draft.canteenId <= 0) return;

    if (draft.isEmpty) {
      await deleteDraft(userId: draft.userId, canteenId: draft.canteenId);
      return;
    }

    final store = await _getStore();
    final key = buildKey(draft.userId, draft.canteenId);
    final jsonStr = jsonEncode(draft.toJson());
    await store.setString(key, jsonStr);
  }

  /// 读取草稿；如无有效数据或解析失败返回 null。
  Future<CanteenReviewDraft?> loadDraft({
    required int userId,
    required int canteenId,
  }) async {
    if (userId <= 0 || canteenId <= 0) return null;

    final store = await _getStore();
    final key = buildKey(userId, canteenId);
    final raw = store.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = CanteenReviewDraft.fromJson(Map<String, dynamic>.from(decoded));
      if (draft.isEmpty) {
        await store.remove(key);
        return null;
      }
      return draft;
    } catch (e) {
      debugPrint('Error parsing canteen review draft for $key: $e');
      return null;
    }
  }

  /// 删除草稿 JSON 记录及对应的草稿图片目录。
  Future<void> deleteDraft({
    required int userId,
    required int canteenId,
    bool cleanupImages = true,
  }) async {
    if (userId <= 0 || canteenId <= 0) return;

    final store = await _getStore();
    final key = buildKey(userId, canteenId);
    await store.remove(key);

    if (cleanupImages) {
      await cleanupDraftImageFiles(userId: userId, canteenId: canteenId);
    }
  }

  /// 将选取的图片安全复制到应用沙盒草稿目录中。
  Future<String> copyImageToDraftStorage({
    required int userId,
    required int canteenId,
    required String sourcePath,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source image does not exist', sourcePath);
    }

    final targetDir = await getDraftDirectory(
      userId: userId,
      canteenId: canteenId,
    );
    final ext = sourcePath.contains('.')
        ? sourcePath.substring(sourcePath.lastIndexOf('.'))
        : '.jpg';
    final targetFileName =
        'draft_img_${DateTime.now().millisecondsSinceEpoch}_${sourceFile.lengthSync()}$ext';
    final targetFile = File('${targetDir.path}/$targetFileName');

    await sourceFile.copy(targetFile.path);
    return targetFile.path;
  }

  /// 清理特定食堂的本地草稿图片目录。
  Future<void> cleanupDraftImageFiles({
    required int userId,
    required int canteenId,
  }) async {
    try {
      final dir = await getDraftDirectory(
        userId: userId,
        canteenId: canteenId,
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Error cleaning up draft images: $e');
    }
  }

  /// 删除指定路径的单个草稿图片文件。
  Future<void> deleteDraftImageFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Error deleting draft image $filePath: $e');
    }
  }
}
