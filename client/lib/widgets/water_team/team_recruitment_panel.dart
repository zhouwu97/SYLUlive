import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/water_team_provider.dart';
import '../../screens/water_team/team_recruitment_applications_screen.dart';
import 'team_application_sheet.dart';

/// 帖子详情中的招募摘要。审批列表独立跳转，避免详情页承担长列表状态。
class TeamRecruitmentPanel extends StatelessWidget {
  final Post post;
  final VoidCallback? onChanged;

  const TeamRecruitmentPanel({super.key, required this.post, this.onChanged});

  String _statusLabel(TeamRecruitmentMeta meta) {
    switch (meta.effectiveStatus) {
      case 'full':
        return '已满员';
      case 'closed':
        return '已关闭';
      case 'expired':
        return '已截止';
      default:
        return '招募中';
    }
  }

  Color _statusColor(TeamRecruitmentMeta meta, bool isDark) {
    if (meta.isRecruiting) {
      return isDark ? Colors.tealAccent : const Color(0xFF087F73);
    }
    return isDark ? Colors.white60 : const Color(0xFF687386);
  }

  Future<void> _apply(BuildContext context, TeamRecruitmentMeta meta) async {
    final changed = await TeamApplicationSheet.show(
      context,
      recruitmentId: meta.recruitmentId,
      postId: post.id,
    );
    if (changed == true) onChanged?.call();
  }

  Future<void> _cancel(BuildContext context, TeamRecruitmentMeta meta) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('取消申请？'),
        content: const Text('取消后，招募仍开放时可以重新申请。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消申请')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final provider = context.read<WaterTeamProvider>();
    final applications = await provider.loadMyApplications(force: true);
    final application = applications
        .where((item) => item.recruitmentId == meta.recruitmentId)
        .firstOrNull;
    if (!context.mounted) return;
    if (application == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未找到申请记录，请稍后重试')));
      return;
    }
    final success =
        await provider.cancel(applicationId: application.id, postId: post.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success ? '申请已取消' : (provider.errorFor(0) ?? '取消申请失败'))));
    if (success) onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final meta = post.teamRecruitment;
    if (meta == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _statusColor(meta, isDark);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF182A2A) : const Color(0xFFF0FBF9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.groups_2_outlined, size: 20),
          const SizedBox(width: 7),
          const Expanded(
              child: Text('组队招募',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Text(_statusLabel(meta),
              style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        Text('还需 ${meta.remainingCount} 人 · 已加入 ${meta.acceptedCount} 人',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text('招募方向',
            style: TextStyle(
                fontSize: 12, color: isDark ? Colors.white60 : Colors.black54)),
        const SizedBox(height: 6),
        Wrap(
            spacing: 6,
            runSpacing: 6,
            children: meta.roles
                .map((role) => Chip(
                    label: Text(role), visualDensity: VisualDensity.compact))
                .toList()),
        if (meta.deadline != null) ...[
          const SizedBox(height: 8),
          Text('截止时间：${_formatDate(meta.deadline!)}',
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white60 : Colors.black54)),
        ],
        if (meta.canManage) ...[
          const SizedBox(height: 12),
          Text('申请 ${meta.applicationCount} 人 · 已通过 ${meta.acceptedCount} 人',
              style:
                  TextStyle(color: isDark ? Colors.white70 : Colors.black87)),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            TeamRecruitmentApplicationsScreen(post: post)));
                onChanged?.call();
              },
              icon: const Icon(Icons.fact_check_outlined, size: 17),
              label: const Text('管理申请'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: meta.isExpired
                  ? null
                  : () => _toggleStatus(context, meta),
              child: Text(meta.isClosed ? '重新开启招募' : '关闭招募'),
            ),
          ]),
        ] else if (meta.isPending) ...[
          _statusRow('申请状态：等待处理', isDark),
          Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  onPressed: () => _cancel(context, meta),
                  child: const Text('取消申请'))),
        ] else if (meta.isAccepted) ...[
          _statusRow('申请状态：已加入', isDark),
        ] else if (meta.canApply) ...[
          Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                  onPressed: () => _apply(context, meta),
                  icon: const Icon(Icons.person_add_alt_1, size: 17),
                  label: Text(
                      meta.isRejected || meta.isCancelled ? '重新申请' : '申请加入'))),
        ] else if (!context.read<AuthProvider>().isLoggedIn && meta.isRecruiting) ...[
          Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/login'),
                  icon: const Icon(Icons.login_rounded, size: 17),
                  label: const Text('登录后申请'))),
        ] else if (meta.isFull) ...[
          _statusRow('当前已满员', isDark),
        ] else if (meta.isClosed) ...[
          _statusRow('招募已关闭', isDark),
        ] else if (meta.isExpired) ...[
          _statusRow('招募已截止', isDark),
        ],
      ]),
    );
  }

  Future<void> _toggleStatus(
      BuildContext context, TeamRecruitmentMeta meta) async {
    final close = meta.status != 'closed';
    final action = close ? '关闭' : '重新开启';
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('$action招募？'),
              content: Text(close ? '关闭后其他用户将不能继续申请。' : '重新开启后，符合条件的用户可以继续申请。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('返回')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(action))
              ],
            ));
    if (ok != true || !context.mounted) return;
    final provider = context.read<WaterTeamProvider>();
    final success = await provider.updateRecruitmentStatus(
        recruitmentId: meta.recruitmentId,
        status: close ? 'closed' : 'recruiting');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(success ? '$action成功' : (provider.errorFor(meta.recruitmentId) ?? '$action失败'))));
    if (success) onChanged?.call();
  }

  Widget _statusRow(String text, bool isDark) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(text,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white70 : Colors.black87)));

  String _formatDate(DateTime value) =>
      '${value.month} 月 ${value.day} 日 ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
