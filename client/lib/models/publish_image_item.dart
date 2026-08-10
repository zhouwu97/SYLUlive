import 'package:image_picker/image_picker.dart';

import 'post.dart';

/// 图片来源：服务器已有图 / 本地新选图。
enum PublishImageSource { existing, local }

/// 上传状态（C-3 预留；C-2 只使用 idle 占位，不实现上传逻辑）。
enum PublishImageUploadState { idle, uploading, success, failed }

/// 发布表单统一图片项（C-2）。
///
/// 用 factory 保证合法组合：
///   - [PublishImageItem.local]：localFile != null，existingImage == null；
///   - [PublishImageItem.existing]：existingImage != null，localFile == null。
class PublishImageItem {
  const PublishImageItem._({
    required this.id,
    required this.source,
    this.localFile,
    this.existingImage,
    // uploadState / progress 为 C-3 上传状态预留，C-2 不使用。
    // ignore: unused_element_parameter
    this.uploadState = PublishImageUploadState.idle,
    // ignore: unused_element_parameter
    this.progress = 0,
  });

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

  /// 上传状态与进度（C-3 预留）。
  final PublishImageUploadState uploadState;
  final double progress;

  /// 服务器 fileId：唯一来源是 existingImage.fileId，不维护第二份副本。
  int? get fileId => existingImage?.fileId;
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
