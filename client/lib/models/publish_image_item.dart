import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'post.dart';

/// 图片来源：服务器已有图 / 本地新选图。
enum PublishImageSource { existing, local }

/// 上传状态（C-3：waiting → uploading → success / failed）。
enum PublishImageUploadState { waiting, uploading, success, failed }

/// 发布表单统一图片项（C-2 模型，C-3 启用上传状态）。
///
/// 用 factory 保证合法组合：
///   - [PublishImageItem.local]：localFile != null，existingImage == null；
///   - [PublishImageItem.existing]：existingImage != null，localFile == null。
class PublishImageItem {
  PublishImageItem._({
    required this.id,
    required this.source,
    this.localFile,
    this.existingImage,
  }) : fileId = existingImage?.fileId;

  /// 本地新选图片。
  factory PublishImageItem.local(XFile file, String id) => PublishImageItem._(
        id: id,
        source: PublishImageSource.local,
        localFile: file,
      );

  /// 服务器已有图片（编辑旧帖时初始化）。
  factory PublishImageItem.existing(PostImage image) => PublishImageItem._(
        id: 'existing-${image.id}',
        source: PublishImageSource.existing,
        existingImage: image,
      );

  /// 稳定 ID：拖拽后 index 会变，禁止用 index 作 id。
  final String id;

  final PublishImageSource source;
  final XFile? localFile;
  final PostImage? existingImage;

  /// 服务器 fileId：existing 由 existingImage 派生；local 上传成功后由上传流程写入。
  int? fileId;

  /// 上传状态与进度（C-3 启用；local 项在上传流程中更新）。
  PublishImageUploadState uploadState = PublishImageUploadState.waiting;
  double progress = 0;
}

/// 按 UI 顺序解析 file_ids（C-2 数据正确性核心）。
///
/// existing 直接取 fileId；local 逐张调用 [upload] 上传取 fileId。
/// 顺序严格等于 [images] 顺序；任一上传失败返回 null。
Future<List<int>?> resolveOrderedFileIds(
  List<PublishImageItem> images,
  Future<int?> Function(XFile file) upload,
) async {
  final fileIds = <int>[];
  for (final item in images) {
    switch (item.source) {
      case PublishImageSource.existing:
        fileIds.add(item.existingImage!.fileId);
      case PublishImageSource.local:
        final fileId = await upload(item.localFile!);
        if (fileId == null) return null;
        fileIds.add(fileId);
    }
  }
  return fileIds;
}

/// 拖拽排序：把 [draggedId] 移到 [targetId] 所在位置（removeAt + insert at target index）。
/// 语义固定：A B C 拖 A 到 C → B C A；C 到 A → C A B。同项/无效项为 no-op。
void reorderImages(
  List<PublishImageItem> images,
  String draggedId,
  String targetId,
) {
  final from = images.indexWhere((e) => e.id == draggedId);
  final to = images.indexWhere((e) => e.id == targetId);
  if (from < 0 || to < 0 || from == to) return;
  final item = images.removeAt(from);
  images.insert(to, item);
}

/// 并发上传本地图（C-3）。
///
/// 最多 [maxConcurrent] 个 worker；每个 local item 更新 uploadState / progress /
/// fileId。[onStateChanged] 供 UI 在状态变化后刷新。全部成功返回 true；
/// 任一失败返回 false（失败项留在 failed 态，可重试）。
///
/// 顺序保证：file_ids 由调用方按 `_images` 顺序组装，与上传完成顺序无关。
Future<bool> uploadImagesConcurrently(
  List<PublishImageItem> images, {
  required int maxConcurrent,
  required Future<int?> Function(PublishImageItem item) upload,
  VoidCallback? onStateChanged,
}) async {
  final locals = images
      .where((e) => e.source == PublishImageSource.local && e.fileId == null)
      .toList();
  if (locals.isEmpty) return true;

  for (final item in locals) {
    item.uploadState = PublishImageUploadState.waiting;
    item.progress = 0;
  }
  onStateChanged?.call();

  final queue = List<PublishImageItem>.from(locals);
  var allOk = true;
  final n = maxConcurrent.clamp(1, queue.length);
  final workers = <Future<void>>[];
  for (var i = 0; i < n; i++) {
    workers.add(() async {
      while (queue.isNotEmpty) {
        final item = queue.removeAt(0);
        item.uploadState = PublishImageUploadState.uploading;
        onStateChanged?.call();
        final fileId = await upload(item);
        if (fileId != null) {
          item.fileId = fileId;
          item.uploadState = PublishImageUploadState.success;
          item.progress = 1;
        } else {
          item.uploadState = PublishImageUploadState.failed;
          allOk = false;
        }
        onStateChanged?.call();
      }
    }());
  }
  await Future.wait(workers);
  return allOk;
}
