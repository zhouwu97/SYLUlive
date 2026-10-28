import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../config/api_constants.dart';
import '../../../models/publish_image_item.dart';
import '../../../theme/app_motion.dart';
import 'dashed_outline.dart';
import '../../../widgets/app_card.dart';
import 'package:provider/provider.dart';
import '../../../providers/theme_provider.dart';

/// 发布表单图片网格（C-2 统一模型）。
///
/// 按可用宽度展示至少三列方形网格（服务器已有图 + 本地新选图可混合）。
/// 第一张标记「封面」。支持长按拖拽排序（Add 按钮不参与）。
/// 空状态展示添加入口，水帖页渲染成单个虚线上传卡片。
class PublishImageGrid extends StatelessWidget {
  static const Color _marketAccent = Color(0xFFFF7A45);

  final List<PublishImageItem> images;
  final bool canAddMore;
  final bool canRemove;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;
  final void Function(String draggedId, String targetId) onReorder;
  final ValueChanged<String>? onRetry;
  final void Function(int index)? onPreviewImage;
  final bool compact;
  final bool singleSlot;
  final String addLabel;
  final Color? accent;

  const PublishImageGrid({
    super.key,
    required this.images,
    required this.canAddMore,
    this.canRemove = true,
    required this.onAdd,
    required this.onRemove,
    required this.onReorder,
    this.onRetry,
    this.onPreviewImage,
    this.compact = false,
    this.singleSlot = false,
    this.addLabel = '添加照片',
    this.accent,
  });

  int get totalImages => images.length;

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

    return LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
              addRepaintBoundaries:
                  context.watch<ThemeProvider?>()?.frostedGlass != true,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:
                    ((constraints.maxWidth + _spacing) / (180 + _spacing))
                        .ceil()
                        .clamp(3, 8),
                crossAxisSpacing: _spacing,
                mainAxisSpacing: _spacing,
              ),
              itemCount: cellCount,
              itemBuilder: (context, index) {
                // ---- 添加入口：空状态在首位，有图片时在末尾；不参与排序 ----
                final isAddSlot = (totalImages == 0) || (index == totalImages);
                if (isAddSlot) {
                  return _buildAddCell(isDark);
                }

                final item = images[index];
                return _buildDraggableItem(context, item, index, isDark);
              },
            ));
  }

  // ---- 可拖拽图片项（长按拖动，drop 到目标位交换） ----

  Widget _buildDraggableItem(
    BuildContext context,
    PublishImageItem item,
    int index,
    bool isDark,
  ) {
    final thumbnail = _buildThumbnail(context, item, index, isDark);
    return LongPressDraggable<String>(
      data: item.id,
      hapticFeedbackOnStart: false,
      delay: const Duration(milliseconds: 500), // 长按启动拖动，避免普通点击即拖
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(width: 100, height: 100, child: thumbnail),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: thumbnail),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) {
          if (details.data == item.id) return;
          onReorder(details.data, item.id);
        },
        builder: (context, candidates, rejected) {
          if (MediaQuery.disableAnimationsOf(context)) {
            return thumbnail;
          }
          final isOver = candidates.isNotEmpty;
          return AnimatedContainer(
            duration: AppMotion.fast,
            decoration: BoxDecoration(
              border: isOver
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
              borderRadius: BorderRadius.circular(_radius),
            ),
            child: thumbnail,
          );
        },
      ),
    );
  }

  Widget _buildThumbnail(
    BuildContext context,
    PublishImageItem item,
    int index,
    bool isDark,
  ) {
    final isFirst = index == 0;
    return GestureDetector(
      onTap: onPreviewImage == null ? null : () => onPreviewImage!(index),
      child: Stack(
        key: ValueKey(item.id),
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: switch (item.source) {
              PublishImageSource.existing => CachedNetworkImage(
                  imageUrl: ApiConstants.fullUrl(item.existingImage!.url),
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.broken_image),
                  ),
                ),
              PublishImageSource.local => Image(
                  image: ResizeImage(FileImage(File(item.localFile!.path)),
                      width: 512, height: 512, policy: ResizeImagePolicy.fit),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.broken_image),
                  ),
                ),
            },
          ),

          if (item.source == PublishImageSource.local) ..._uploadStatus(item),

          // 封面角标
          if (isFirst)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

          // 覆盖层之上的独立取消按钮，失败与上传中均可移除。
          Positioned(
            top: 0,
            right: 0,
            child: _buildRemoveButton(item),
          ),
        ],
      ),
    );
  }

  // ---- 单槽模式（市场） ----

  Widget _buildSingleSlot(BuildContext context, bool isDark) {
    final item = images.isNotEmpty ? images.first : null;
    final hasImage = item != null;

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
                  : onAdd,
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
                      ? _buildSinglePreview(context, item, isDark)
                      : _buildSingleAddContent(isDark),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSinglePreview(
    BuildContext context,
    PublishImageItem item,
    bool isDark,
  ) {
    return Stack(
      key: ValueKey(item.id),
      fit: StackFit.expand,
      children: [
        switch (item.source) {
          PublishImageSource.existing => CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(item.existingImage!.url),
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildBrokenImage(),
            ),
          PublishImageSource.local => Image(
              image: ResizeImage(FileImage(File(item.localFile!.path)),
                  width: 640, height: 640, policy: ResizeImagePolicy.fit),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildBrokenImage(),
            ),
        },
        if (item.source == PublishImageSource.local) ..._uploadStatus(item),
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
          top: 0,
          right: 0,
          child: _buildRemoveButton(item),
        ),
      ],
    );
  }

  Widget _buildRemoveButton(PublishImageItem item) {
    final label = !canRemove
        ? '正在发布，暂不能移除图片'
        : item.source == PublishImageSource.existing
            ? '移除图片'
            : switch (item.uploadState) {
                PublishImageUploadState.waiting => '取消等待并移除图片',
                PublishImageUploadState.uploading => '取消上传并移除图片',
                PublishImageUploadState.failed => '移除上传失败的图片',
                PublishImageUploadState.success => '移除已上传图片',
              };
    return IconButton(
      key: ValueKey('publish-image-remove-${item.id}'),
      tooltip: label,
      onPressed: canRemove ? () => onRemove(item.id) : null,
      visualDensity: VisualDensity.standard,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: const EdgeInsets.all(10),
      icon: DecoratedBox(
        decoration:
            const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.close,
              size: 16, color: canRemove ? Colors.white : Colors.white54),
        ),
      ),
    );
  }

  List<Widget> _uploadStatus(PublishImageItem item) {
    final state = item.uploadState;
    if (state == PublishImageUploadState.success) {
      return [
        Positioned(
          bottom: 4,
          right: 4,
          child: Semantics(
            label: '图片已上传',
            child: const ColoredBox(
              color: Colors.black54,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('已上传',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ),
        )
      ];
    }
    final failed = state == PublishImageUploadState.failed;
    final label = failed
        ? '上传失败，点击重试'
        : state == PublishImageUploadState.waiting
            ? '等待上传'
            : item.progress > 0
                ? '上传 ${(item.progress * 100).round()}%'
                : '正在处理';
    return [
      Positioned.fill(
        child: Semantics(
          label:
              failed ? '${item.uploadError?.message ?? '图片上传失败'}，点击重试' : label,
          button: failed,
          child: Tooltip(
            triggerMode: TooltipTriggerMode.manual,
            message: failed ? item.uploadError?.message ?? label : label,
            child: GestureDetector(
              onTap: failed && onRetry != null ? () => onRetry!(item.id) : null,
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (failed)
                      const Icon(Icons.refresh_rounded,
                          color: Colors.white, size: 24)
                    else if (state == PublishImageUploadState.waiting)
                      const Icon(Icons.schedule, color: Colors.white, size: 22)
                    else
                      SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            value: item.progress > 0 ? item.progress : null,
                            color: Colors.white,
                          )),
                    const SizedBox(height: 4),
                    Text(label,
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 10)),
                  ],
                )),
              ),
            ),
          ),
        ),
      )
    ];
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
      onTap: onAdd,
      child: DashedOutline(
        color: isDark
            ? _marketAccent.withValues(alpha: 0.55)
            : _marketAccent.withValues(alpha: 0.34),
        radius: _radius + 4,
        child: AppCardSurface(
          key: const ValueKey('publish-image-add-surface'),
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
