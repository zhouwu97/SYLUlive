import 'package:flutter/material.dart';

import '../../models/team_recruitment.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/team/team_ui_tokens.dart';
import '../../widgets/cached_avatar.dart';
import '../../config/api_constants.dart';

class TeamRecruitmentCard extends StatelessWidget {
  final TeamRecruitment recruitment;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool isDeleting;

  const TeamRecruitmentCard(
      {super.key,
      required this.recruitment,
      required this.onTap,
      this.onDelete,
      this.isDeleting = false});

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(recruitment.category);
    final isInactive = recruitment.isClosed || recruitment.isExpired;
    final status = recruitment.isRecruiting &&
            recruitment.deadline != null &&
            recruitment.deadline!
                .isBefore(DateTime.now().add(const Duration(days: 3)))
        ? 'deadline_soon'
        : recruitment.effectiveStatus;
    final visibleRoles = recruitment.roles.take(3).toList(growable: false);
    final extraRoleCount = recruitment.roles.length - visibleRoles.length;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: isInactive ? 0.62 : 1,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: TeamUiTokens.cardBg(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: TeamUiTokens.border(isDark)),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _Pill(
                    label: _categoryLabel(recruitment.category), color: color),
                const Spacer(),
                TeamStatusBadge(status: status),
                if (onDelete != null) ...[
                  const SizedBox(width: 2),
                  PopupMenuButton<String>(
                    tooltip: '组队操作',
                    enabled: !isDeleting,
                    padding: EdgeInsets.zero,
                    icon: isDeleting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.more_vert_rounded, size: 20),
                    onSelected: (value) {
                      if (value == 'delete') onDelete?.call();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded,
                              color: Color(0xFFE54848)),
                          SizedBox(width: 10),
                          Text('删除组队'),
                        ]),
                      ),
                    ],
                  ),
                ],
              ]),
              const SizedBox(height: 10),
              Text(recruitment.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(recruitment.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: TeamUiTokens.subtitle(isDark))),
              if (recruitment.roles.isNotEmpty) ...[
                const SizedBox(height: 11),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ...visibleRoles.map(
                      (role) => _Pill(label: role, color: color, subtle: true)),
                  if (extraRoleCount > 0)
                    _Pill(
                        label: '+$extraRoleCount', color: color, subtle: true),
                ]),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.group_outlined, size: 16, color: color),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                      '已加入 ${recruitment.acceptedCount} 人 · 还缺 ${recruitment.remainingCount} 人',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ),
                if (recruitment.deadline != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.schedule_rounded,
                      size: 15, color: TeamUiTokens.subtitle(isDark)),
                  const SizedBox(width: 3),
                  Text(
                      '截止 ${recruitment.deadline!.month.toString().padLeft(2, '0')}-${recruitment.deadline!.day.toString().padLeft(2, '0')}',
                      style: TextStyle(
                          fontSize: 12, color: TeamUiTokens.subtitle(isDark))),
                ],
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: recruitment.neededCount == 0
                      ? 0
                      : (recruitment.acceptedCount / recruitment.neededCount)
                          .clamp(0, 1)
                          .toDouble(),
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.12),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                CachedAvatar(
                  radius: 12,
                  imageUrl: ApiConstants.fullUrl(recruitment.author.avatar),
                  fallbackText: recruitment.author.name,
                ),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(
                        '${recruitment.author.name}${recruitment.author.major.isEmpty ? '' : ' · ${recruitment.author.major}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: TeamUiTokens.subtitle(isDark)))),
                Text(_relativeTime(recruitment.createdAt),
                    style: TextStyle(
                        fontSize: 12, color: TeamUiTokens.subtitle(isDark))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class TeamStatusBadge extends StatelessWidget {
  final String status;
  const TeamStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final data = switch (status) {
      'deadline_soon' => ('即将截止', const Color(0xFFC56D31)),
      'full' => ('已满员', const Color(0xFF9B6A24)),
      'closed' => ('已关闭', const Color(0xFF687385)),
      'expired' => ('已截止', const Color(0xFFC45E58)),
      _ => ('招募中', const Color(0xFF3B8D70)),
    };
    return _Pill(label: data.$1, color: data.$2);
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final bool subtle;
  const _Pill({required this.label, required this.color, this.subtle = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: color.withValues(alpha: subtle ? 0.08 : 0.13),
            borderRadius: BorderRadius.circular(99)),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );
}

String teamCategoryLabel(String category) => _categoryLabel(category);
Color teamCategoryColor(String category) => _categoryColor(category);
String _categoryLabel(String value) =>
    const {
      'competition': '学科竞赛',
      'project': '项目协作',
      'study': '学习互助',
      'activity': '活动组队',
      'other': '其他组队'
    }[value] ??
    '其他组队';
Color _categoryColor(String value) =>
    const {
      'competition': CampusTheme.blue,
      'project': CampusTheme.cyan,
      'study': CampusTheme.green,
      'activity': CampusTheme.orange,
      'other': Color(0xFF687385)
    }[value] ??
    const Color(0xFF687385);
String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  return '${diff.inDays}天前';
}
