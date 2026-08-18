import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/unread_reply_notification.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import 'cached_avatar.dart';

/// 首页信息流中的未读回复摘要；展示本身不触发已读消费。
class ReplyNotificationReminder extends StatelessWidget {
  final List<UnreadReplyNotification> items;
  final int totalCount;
  final VoidCallback onPressed;

  const ReplyNotificationReminder({
    super.key,
    required this.items,
    required this.totalCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final count = totalCount > 0 ? totalCount : items.length;
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: '互动回复，$count 条未读，查看',
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('home-reply-notification-reminder'),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.sm,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.brandPrimary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  const Icon(
                    Icons.forum_outlined,
                    size: 18,
                    color: AppColors.brandPrimary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '互动回复',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '$count 条新回复',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showReplyNotificationList(
  BuildContext context, {
  required List<UnreadReplyNotification> items,
  int totalCount = 0,
  required ValueChanged<UnreadReplyNotification> onSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Material(
      color: Theme.of(sheetContext).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: _ReplyNotificationSheetContent(
            items: items,
            totalCount: totalCount,
            onSelected: onSelected,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    ),
  );
}

class _ReplyNotificationSheetContent extends StatelessWidget {
  final List<UnreadReplyNotification> items;
  final int totalCount;
  final ValueChanged<UnreadReplyNotification> onSelected;
  final VoidCallback onClose;

  const _ReplyNotificationSheetContent({
    required this.items,
    required this.totalCount,
    required this.onSelected,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final list = ListView.separated(
      shrinkWrap: items.length <= 6,
      physics: items.length <= 6 ? const NeverScrollableScrollPhysics() : null,
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final item = items[index];
        final title = item.postTitle.trim().isEmpty ? '帖子' : item.postTitle.trim();
        final nickname = item.fromUser?.nickname.trim().isNotEmpty == true
            ? item.fromUser!.nickname.trim()
            : '同学';
        final avatar = item.fromUser?.avatar.trim() ?? '';
        final avatarUrl = avatar.isNotEmpty ? ApiConstants.fullUrl(avatar) : null;
        final time = _formatReplyNotificationTime(item.createdAt);
        final content =
            item.content.trim().isEmpty ? '回复了你的内容' : item.content.trim();

        return Semantics(
          container: true,
          button: true,
          label: '$nickname，$time，回复：$content，来自帖子《$title》',
          child: InkWell(
            key: ValueKey('reply-notification-${item.id}'),
            onTap: () {
              onClose();
              onSelected(item);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CachedAvatar(
                    imageUrl: avatarUrl,
                    radius: 20,
                    fallbackText: nickname,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                nickname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colors.onSurface,
                                    ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              time,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                color: colors.onSurface,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '回复于《$title》',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    final showRecentTag = totalCount > items.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Text(
                  showRecentTag
                      ? '未读回复 $totalCount'
                      : '未读回复 (${items.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (showRecentTag) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '最近 ${items.length} 条',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (items.length <= 6)
          list
        else
          Flexible(
            fit: FlexFit.loose,
            child: list,
          ),
      ],
    );
  }
}

String _formatReplyNotificationTime(DateTime value) {
  final difference = DateTime.now().difference(value.toLocal());
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 7) return '${difference.inDays}天前';
  final local = value.toLocal();
  return '${local.month}/${local.day}';
}
