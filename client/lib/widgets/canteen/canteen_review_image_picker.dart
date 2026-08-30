import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_review_draft.dart';
import '../../screens/image_viewer_screen.dart';
import '../../services/canteen_review_draft_repository.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 商家评价图片选择与草稿暂存组件。
///
/// 特性：
/// - 最多 3 张图片（已有远端图片 + 本地待上传图片 <= 3）。
/// - 本地选图（相机/相册）经大小校验（<=10MB）后自动暂存至沙盒草稿目录，
///   在发布前绝不提前上传，避免服务器产生废弃文件。
/// - 支持单张删除并自动清理对应沙盒临时文件。
/// - 点击图片可全屏预览。
class CanteenReviewImagePicker extends StatefulWidget {
  final List<CanteenReviewDraftImage> images;
  final int maxImages;
  final int userId;
  final int canteenId;
  final String draftMode;
  final int? draftReviewEventId;
  final CanteenReviewDraftRepository draftRepository;
  final ValueChanged<List<CanteenReviewDraftImage>> onImagesChanged;
  final bool enabled;
  final int? defaultDishId;
  final String? defaultDishName;

  const CanteenReviewImagePicker({
    super.key,
    required this.images,
    this.maxImages = 3,
    required this.userId,
    required this.canteenId,
    this.draftMode = 'create',
    this.draftReviewEventId,
    required this.draftRepository,
    required this.onImagesChanged,
    this.enabled = true,
    this.defaultDishId,
    this.defaultDishName,
  });

  @override
  State<CanteenReviewImagePicker> createState() =>
      _CanteenReviewImagePickerState();
}

class _CanteenReviewImagePickerState extends State<CanteenReviewImagePicker> {
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;

  bool get _canAddMore =>
      widget.enabled &&
      !_isProcessing &&
      widget.images.length < widget.maxImages;

  Future<void> _pickImage(ImageSource source) async {
    if (!_canAddMore) return;

    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
        requestFullMetadata: false,
      );

      if (file == null) return;

      final length = await file.length();
      if (length > 10 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('图片大小不能超过 10MB'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      setState(() => _isProcessing = true);

      final draftPath = await widget.draftRepository.copyImageToDraftStorage(
        userId: widget.userId,
        canteenId: widget.canteenId,
        mode: widget.draftMode,
        reviewEventId: widget.draftReviewEventId,
        sourcePath: file.path,
      );

      final nextImages = List<CanteenReviewDraftImage>.from(widget.images)
        ..add(
          CanteenReviewDraftImage(
            type: ReviewDraftImageType.localPending,
            localPath: draftPath,
            dishId: widget.defaultDishId,
            dishName: widget.defaultDishName,
          ),
        );

      widget.onImagesChanged(nextImages);
    } catch (e) {
      debugPrint('Error picking image for canteen review: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showSourceSheet(BuildContext context) {
    if (!_canAddMore) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('从相册选择'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickImage(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('拍照'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickImage(ImageSource.camera);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _removeImageAt(int index) async {
    if (!widget.enabled || index < 0 || index >= widget.images.length) return;

    final image = widget.images[index];
    if (image.type == ReviewDraftImageType.localPending &&
        image.localPath != null) {
      await widget.draftRepository.deleteDraftImageFile(image.localPath!);
    }

    final nextImages = List<CanteenReviewDraftImage>.from(widget.images)
      ..removeAt(index);
    widget.onImagesChanged(nextImages);
  }

  void _openViewer(int initialIndex) {
    final imageUrls = <String>[];
    final imageBytes = <Uint8List?>[];

    for (final img in widget.images) {
      if (img.type == ReviewDraftImageType.publishedRemote &&
          img.url != null &&
          img.url!.isNotEmpty) {
        imageUrls.add(ApiConstants.fullUrl(img.url!));
        imageBytes.add(null);
      } else if (img.localPath != null) {
        imageUrls.add('');
        try {
          final file = File(img.localPath!);
          if (file.existsSync()) {
            imageBytes.add(file.readAsBytesSync());
          } else {
            imageBytes.add(null);
          }
        } catch (_) {
          imageBytes.add(null);
        }
      }
    }

    if (imageUrls.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: imageUrls,
          imageBytes: imageBytes,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);
    const itemSize = 84.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < widget.images.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              _buildImageThumb(
                index: i,
                image: widget.images[i],
                size: itemSize,
                isDark: isDark,
              ),
            ],
            if (_canAddMore) ...[
              if (widget.images.isNotEmpty) const SizedBox(width: 10),
              _buildAddButton(size: itemSize, isDark: isDark, accent: accent),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '最多 ${widget.maxImages} 张，随评价公开展示',
          style: TextStyle(
            fontSize: 12,
            color: CanteenTheme.textTertiaryColor(isDark),
          ),
        ),
      ],
    );
  }

  Widget _buildImageThumb({
    required int index,
    required CanteenReviewDraftImage image,
    required double size,
    required bool isDark,
  }) {
    Widget content;
    if (image.type == ReviewDraftImageType.publishedRemote &&
        image.url != null &&
        image.url!.isNotEmpty) {
      content = CanteenStatusImage(
        imageUrl: image.url!,
        variant: 'thumb',
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          color: CanteenTheme.surfaceMutedBg(isDark),
        ),
        errorWidget: (_, __, ___) => Container(
          color: CanteenTheme.surfaceMutedBg(isDark),
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    } else if (image.localPath != null) {
      final file = File(image.localPath!);
      if (file.existsSync()) {
        content = Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: CanteenTheme.surfaceMutedBg(isDark),
            child: const Icon(Icons.broken_image, color: Colors.grey),
          ),
        );
      } else {
        content = Container(
          color: CanteenTheme.surfaceMutedBg(isDark),
          child: const Icon(Icons.broken_image, color: Colors.grey),
        );
      }
    } else {
      content = Container(color: CanteenTheme.surfaceMutedBg(isDark));
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _openViewer(index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: content,
              ),
            ),
          ),
          if (widget.enabled)
            Positioned(
              top: -4,
              right: -4,
              child: GestureDetector(
                onTap: () => _removeImageAt(index),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAddButton({
    required double size,
    required bool isDark,
    required Color accent,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showSourceSheet(context),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceMutedBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
            border: Border.all(
              color: CanteenTheme.borderColor(isDark),
              width: 1,
            ),
          ),
          child: _isProcessing
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 26,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 12,
                        color: CanteenTheme.textSecondaryColor(isDark),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
