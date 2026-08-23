import 'package:flutter/material.dart';

import '../../../models/topic.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text_styles.dart';

/// Composer 内的 Topic 语义区：已选择、推荐、主动添加三种状态集中呈现。
class PublishTopicSection extends StatelessWidget {
  final List<TopicSelection> selectedTopics;
  final List<Topic> recommendedTopics;
  final bool loading;
  final int maxTopics;
  final VoidCallback onAdd;
  final ValueChanged<TopicSelection> onRemove;
  final ValueChanged<TopicSelection> onSelectRecommendation;

  const PublishTopicSection({
    super.key,
    required this.selectedTopics,
    required this.recommendedTopics,
    required this.loading,
    required this.maxTopics,
    required this.onAdd,
    required this.onRemove,
    required this.onSelectRecommendation,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedIds = selectedTopics.map((topic) => topic.id).toSet();
    final visibleRecommendations = recommendedTopics
        .where((topic) => !selectedIds.contains(topic.id))
        .take(4)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeading(
            title: '话题',
            count: '${selectedTopics.length}/$maxTopics',
            isDark: isDark,
          ),
          if (selectedTopics.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: selectedTopics
                  .map(
                    (topic) => InputChip(
                      label: Text('#${topic.name}'),
                      onDeleted: () => onRemove(topic),
                      visualDensity: VisualDensity.compact,
                      labelStyle: AppTextStyles.labelMedium.copyWith(
                        color: isDark
                            ? AppColors.brandPrimary
                            : AppColors.brandPrimaryStrong,
                      ),
                      backgroundColor: isDark
                          ? AppColors.brandSurfaceDark
                          : AppColors.brandSurfaceLight,
                      side: BorderSide(
                        color: AppColors.brandPrimary.withValues(alpha: 0.18),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          if (visibleRecommendations.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '推荐',
              style: AppTextStyles.labelMedium.copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: visibleRecommendations
                  .map(
                    (topic) => ActionChip(
                      label: Text('#${topic.name}'),
                      onPressed: () => onSelectRecommendation(
                        TopicSelection.existing(
                          id: topic.id,
                          name: topic.name,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                      labelStyle: AppTextStyles.labelMedium.copyWith(
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondaryLight,
                      ),
                      backgroundColor: isDark
                          ? AppColors.surfaceMutedDark
                          : AppColors.surfaceMutedLight,
                      side: BorderSide.none,
                    ),
                  )
                  .toList(growable: false),
            ),
          ] else if (loading) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '推荐',
              style: AppTextStyles.labelMedium.copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            const _TopicSkeletons(),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: Text(selectedTopics.isEmpty ? '添加话题' : '继续添加'),
              onPressed: selectedTopics.length >= maxTopics ? null : onAdd,
              visualDensity: VisualDensity.compact,
              labelStyle: AppTextStyles.labelMedium.copyWith(
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final String count;
  final bool isDark;

  const _SectionHeading({
    required this.title,
    required this.count,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: AppTextStyles.titleMedium.copyWith(
            fontSize: 16,
            color:
                isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
          ),
        ),
        const Spacer(),
        Text(
          count,
          style: AppTextStyles.labelMedium.copyWith(
            color: isDark
                ? AppColors.textTertiaryDark
                : AppColors.textTertiaryLight,
          ),
        ),
      ],
    );
  }
}

class _TopicSkeletons extends StatelessWidget {
  const _TopicSkeletons();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color =
        isDark ? AppColors.surfaceMutedDark : AppColors.surfaceMutedLight;
    return Wrap(
      spacing: AppSpacing.sm,
      children: [
        for (final width in [54.0, 42.0, 64.0])
          Container(
            width: width,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
      ],
    );
  }
}
