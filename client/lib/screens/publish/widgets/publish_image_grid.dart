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
  static const Color _marketAccent = Color(0xFFFF7A45);

  final List<PostImage> existingImages;
  final List<XFile> selectedImages;
  final bool canAddMore;
  final VoidCallback onAddImage;
  final void Function(int index) onRemoveNewImage;
  final void Function(int index) onRemoveExistingImage;
  final void Function(int index)? onPreviewImage;
  final bool compact;
  final bool singleSlot;
  final String addLabel;
  final Color? accent;

  const PublishImageGrid({
    super.key,
    required this.existingImages,
    required this.selectedImages,
    required this.canAddMore,
    required this.onAddImage,
    required this.onRemoveNewImage,
    required this.onRemoveExistingImage,
    this.onPreviewImage,
    this.compact = false,
    this.singleSlot = false,
    this.addLabel = '添加照片',
    this.accent,
  });

  int get totalImages => existingImages.length + selectedImages.length;

  double get _spacing => compact ? 8.0 : 10.0;
  double get _radius => compact ? 10.0 : 12.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (singleSlot) {
      return _buildSingleSlot(context, isDark);
    }

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

        return GestureDetector(
          onTap: onPreviewImage == null ? null : () => onPreviewImage!(index),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(_radius),
                child: isExisting
                    ? CachedNetworkImage(
                        imageUrl:
                            ApiConstants.fullUrl(existingImages[index].url),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.broken_image),
                        ),
                      )
                    : Image.file(
                        File(
                            selectedImages[index - existingImages.length].path),
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
          ),
        );
      },
    );
  }

  Widget _buildSingleSlot(BuildContext context, bool isDark) {
    final existing = existingImages.isNotEmpty ? existingImages.first : null;
    final selected = existing == null && selectedImages.isNotEmpty
        ? selectedImages.first
        : null;
    final hasImage = existing != null || selected != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, 590.0)
            : 590.0;
        final widthCap = availableWidth <= 430 ? 320.0 : 590.0;
        final frameWidth = availableWidth.clamp(0.0, widthCap);
        final height = (frameWidth / 2.0).clamp(150.0, 186.0);

        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: frameWidth,
            height: height,
            child: GestureDetector(
              onTap: hasImage
                  ? (onPreviewImage == null ? null : () => onPreviewImage!(0))
                  : onAddImage,
              child: DashedOutline(
                color: hasImage
                    ? Colors.transparent
                    : isDark
                        ? _marketAccent.withValues(alpha: 0.42)
                        : _marketAccent.withValues(alpha: 0.28),
                radius: 18,
                strokeWidth: 1.1,
                dashLength: 6,
                gapLength: 4,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: isDark
                        ? _marketAccent.withValues(alpha: 0.08)
                        : const Color(0xFFF8F8FF),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: hasImage
                          ? Colors.transparent
                          : _marketAccent.withValues(
                              alpha: isDark ? 0.10 : 0.06,
                            ),
                    ),
                    boxShadow: [
                      if (!isDark)
                        BoxShadow(
                          color: _marketAccent.withValues(alpha: 0.07),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: hasImage
                      ? _buildSinglePreview(
                          context: context,
                          existing: existing,
                          selected: selected,
                        )
                      : _buildSingleAddContent(isDark),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSinglePreview({
    required BuildContext context,
    required PostImage? existing,
    required XFile? selected,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (existing != null)
          CachedNetworkImage(
            imageUrl: ApiConstants.fullUrl(existing.url),
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => _buildBrokenImage(),
          )
        else
          Image.file(
            File(selected!.path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildBrokenImage(),
          ),
        Positioned(
          top: 10,
          left: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (accent ?? Theme.of(context).colorScheme.primary)
                  .withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '封面',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: GestureDetector(
            onTap: () => existing != null
                ? onRemoveExistingImage(0)
                : onRemoveNewImage(0),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 17,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSingleAddContent(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: isDark
                  ? _marketAccent.withValues(alpha: 0.16)
                  : _marketAccent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
              boxShadow: [
                if (!isDark)
                  BoxShadow(
                    color: _marketAccent.withValues(alpha: 0.10),
                    blurRadius: 14,
                    offset: const Offset(0, 7),
                  ),
              ],
            ),
            child: const Icon(
              Icons.photo_camera_rounded,
              size: 29,
              color: _marketAccent,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            addLabel,
            style: const TextStyle(
              fontSize: 16,
              color: _marketAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '首张默认为封面',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.56)
                  : const Color(0xFF7C8292),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrokenImage() {
    return Container(
      color: Colors.grey[300],
      child: const Icon(Icons.broken_image),
    );
  }

  Widget _buildAddCell(bool isDark) {
    return GestureDetector(
      onTap: onAddImage,
      child: DashedOutline(
        color: isDark
            ? _marketAccent.withValues(alpha: 0.55)
            : _marketAccent.withValues(alpha: 0.34),
        radius: _radius + 4,
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? _marketAccent.withValues(alpha: 0.08)
                : const Color(0xFFFFF0E8),
            borderRadius: BorderRadius.circular(_radius + 4),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_a_photo_outlined,
                size: compact ? 30 : 34,
                color: _marketAccent,
              ),
              const SizedBox(height: 8),
              Text(
                addLabel,
                style: const TextStyle(
                  fontSize: 14,
                  color: _marketAccent,
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
