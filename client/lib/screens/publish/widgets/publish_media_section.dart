import 'package:flutter/material.dart';

import '../../../models/publish_image_item.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text_styles.dart';
import 'publish_image_grid.dart';

/// 图片附件区。空状态保持轻量按钮，有图后复用原有网格与上传状态机。
class PublishMediaSection extends StatelessWidget {
  final List<PublishImageItem> images;
  final bool canAddMore;
  final int maxImages;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;
  final void Function(String draggedId, String targetId) onReorder;
  final ValueChanged<String>? onRetry;

  const PublishMediaSection({
    super.key,
    required this.images,
    required this.canAddMore,
    required this.maxImages,
    required this.onAdd,
    required this.onRemove,
    required this.onReorder,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '图片',
                style: AppTextStyles.titleMedium.copyWith(
                  fontSize: 16,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimaryLight,
                ),
              ),
              const Spacer(),
              Text(
                '${images.length}/$maxImages',
                style: AppTextStyles.labelMedium.copyWith(color: secondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (images.isEmpty)
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: canAddMore ? onAdd : null,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('添加图片'),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimaryLight,
                  side: BorderSide(
                    color: isDark
                        ? AppColors.borderNormalDark
                        : AppColors.borderNormalLight,
                  ),
                ),
              ),
            )
          else
            PublishImageGrid(
              images: images,
              canAddMore: canAddMore,
              onAdd: onAdd,
              onRemove: onRemove,
              onReorder: onReorder,
              onRetry: onRetry,
              compact: true,
            ),
        ],
      ),
    );
  }
}
