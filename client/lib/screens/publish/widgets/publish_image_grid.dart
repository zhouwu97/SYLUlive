import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../../config/api_constants.dart';
import '../../../models/post.dart';
import 'dashed_outline.dart';

/// 发布表单图片网格。
///
/// 以三列方形网格展示已上传图片和本地新选图片。第一张图片会标记为「封面」。
/// 空图片状态下仍展示添加入口，水帖页会将其渲染成单个虚线上传卡片。
class PublishImageGrid extends StatelessWidget {
  static const Color _teal = Color(0xFF12B8A6);

  final List<PostImage> existingImages;
  final List<XFile> selectedImages;
  final bool canAddMore;
  final VoidCallback onAddImage;
  final void Function(int index) onRemoveNewImage;
  final void Function(int index) onRemoveExistingImage;
  final bool compact;

  const PublishImageGrid({
    super.key,
    required this.existingImages,
    required this.selectedImages,
    required this.canAddMore,
    required this.onAddImage,
    required this.onRemoveNewImage,
    required this.onRemoveExistingImage,
    this.compact = false,
  });

  int get totalImages => existingImages.length + selectedImages.length;

  double get _spacing => compact ? 8.0 : 10.0;
  double get _radius => compact ? 10.0 : 12.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (totalImages == 0) {
      final tileSize = compact ? 132.0 : 148.0;
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: tileSize,
          height: tileSize,
          child: _buildAddCell(isDark),
        ),
      );
    }

    // 至少保留一个添加入口；已有图片且还能继续添加时，入口放在末尾。
    final int cellCount =
        max(1, totalImages) + (canAddMore && totalImages > 0 ? 1 : 0);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: _spacing,
        mainAxisSpacing: _spacing,
      ),
      itemCount: cellCount,
      itemBuilder: (context, index) {
        // ---- 添加入口：空状态在首位，有图片时在末尾 ----
        final isAddSlot = (totalImages == 0) || (index == totalImages);
        if (isAddSlot) {
          return _buildAddCell(isDark);
        }

        // ---- 图片缩略图 ----
        final isExisting = index < existingImages.length;
        final isFirst = index == 0;

        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: isExisting
                  ? CachedNetworkImage(
                      imageUrl: ApiConstants.fullUrl(existingImages[index].url),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
                    )
                  : Image.file(
                      File(selectedImages[index - existingImages.length].path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
            ),

            // 封面角标
            if (isFirst)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '封面',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),

            // 删除按钮
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => isExisting
                    ? onRemoveExistingImage(index)
                    : onRemoveNewImage(index - existingImages.length),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
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
        );
      },
    );
  }

  Widget _buildAddCell(bool isDark) {
    return GestureDetector(
      onTap: onAddImage,
      child: DashedOutline(
        color: isDark
            ? _teal.withValues(alpha: 0.55)
            : _teal.withValues(alpha: 0.34),
        radius: _radius + 4,
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? _teal.withValues(alpha: 0.08)
                : const Color(0xFFF3FFFC),
            borderRadius: BorderRadius.circular(_radius + 4),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_a_photo_outlined,
                size: compact ? 30 : 34,
                color: _teal,
              ),
              const SizedBox(height: 8),
              const Text(
                '添加照片',
                style: TextStyle(
                  fontSize: 14,
                  color: _teal,
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
