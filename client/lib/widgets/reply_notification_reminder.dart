import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/unread_reply_notification.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../services/publish_session_scope.dart';
import 'cached_avatar.dart';
import 'app_card.dart';

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
      child: AppCardMaterial(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('home-reply-notification-reminder'),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
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
  Future<void> Function()? onMarkAllRead,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    showDragHandle: true,
    builder: (sheetContext) => AppCardMaterial(
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
            onMarkAllRead: onMarkAllRead,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    ),
  );
}

class _ReplyNotificationSheetContent extends StatefulWidget {
  final List<UnreadReplyNotification> items;
  final int totalCount;
  final ValueChanged<UnreadReplyNotification> onSelected;
  final VoidCallback onClose;
  final Future<void> Function()? onMarkAllRead;

  const _ReplyNotificationSheetContent({
    required this.items,
    required this.totalCount,
    required this.onSelected,
    required this.onClose,
    this.onMarkAllRead,
  });

  @override
  State<_ReplyNotificationSheetContent> createState() =>
      _ReplyNotificationSheetContentState();
}

class _ReplyNotificationSheetContentState
    extends State<_ReplyNotificationSheetContent> {
  bool _markingRead = false;
  String? _readError;

  Future<void> _markAllRead() async {
    if (_markingRead) return;
    setState(() {
      _markingRead = true;
      _readError = null;
    });
    try {
      await widget.onMarkAllRead!();
      if (mounted) widget.onClose();
    } catch (error) {
      if (mounted) {
        setState(() => _readError =
            error is PublishSessionChanged ? '账号已切换，请关闭后重新打开' : '标记已读失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _markingRead = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final totalCount = widget.totalCount;
    final colors = Theme.of(context).colorScheme;
    final list = ListView.separated(
      shrinkWrap: items.length <= 6,
      physics: items.length <= 6 ? const NeverScrollableScrollPhysics() : null,
      itemCount: items.length,
      separatorBuilder: (_, __) => AppCardDivider(
        height: 1,
        color: colors.outlineVariant.withValues(alpha: 0.25),
      ),
      itemBuilder: (_, index) {
        final item = items[index];
        final title =
            item.postTitle.trim().isEmpty ? '帖子' : item.postTitle.trim();
        final nickname = item.fromUser?.nickname.trim().isNotEmpty == true
            ? item.fromUser!.nickname.trim()
            : '同学';
        final avatar = item.fromUser?.avatar.trim() ?? '';
        final avatarUrl =
            avatar.isNotEmpty ? ApiConstants.fullUrl(avatar) : null;
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
              widget.onClose();
              widget.onSelected(item);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: 12,
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
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colors.onSurface,
                                  ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '回复于《$title》',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        showRecentTag
                            ? '未读回复 $totalCount'
                            : '未读回复 (${items.length})',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onSurface,
                                ),
                      ),
                      if (showRecentTag)
                        Text(
                          '最近 ${items.length} 条',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                        ),
                    ],
                  ),
                ),
                if (widget.onMarkAllRead != null)
                  TextButton(
                    key: const ValueKey('reply-notifications-mark-all-read'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      visualDensity: VisualDensity.standard,
                    ),
                    onPressed: _markingRead ? null : _markAllRead,
                    child: Text(_markingRead ? '处理中…' : '一键已读'),
                  ),
              ],
            ),
          ),
        ),
        if (_readError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              _readError!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.error,
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
