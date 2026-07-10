import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../models/water_team.dart';
import '../../providers/water_team_provider.dart';

/// 发起人审批组队申请的独立页面。
class TeamRecruitmentApplicationsScreen extends StatefulWidget {
  final Post post;

  const TeamRecruitmentApplicationsScreen({super.key, required this.post});

  @override
  State<TeamRecruitmentApplicationsScreen> createState() =>
      _TeamRecruitmentApplicationsScreenState();
}

class _TeamRecruitmentApplicationsScreenState
    extends State<TeamRecruitmentApplicationsScreen> {
  String _filter = 'pending';

  TeamRecruitmentMeta? get _meta => widget.post.teamRecruitment;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final recruitmentId = _meta?.recruitmentId;
    if (recruitmentId == null || recruitmentId <= 0) return;
    await context
        .read<WaterTeamProvider>()
        .loadRecruitmentApplications(recruitmentId, force: true);
    if (mounted) setState(() {});
  }

  List<WaterTeamApplication> _filtered(List<WaterTeamApplication> apps) {
    final result = apps.where((app) => app.status == _filter).toList();
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final provider = context.watch<WaterTeamProvider>();
    final apps = meta == null
        ? const <WaterTeamApplication>[]
        : provider.applicationsFor(meta.recruitmentId);
    final filtered = _filtered(apps);
    return Scaffold(
      appBar: AppBar(title: const Text('申请管理'), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))
      ]),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
              '招募：${widget.post.title.isEmpty ? '未命名帖子' : widget.post.title}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        _buildFilterBar(apps),
        Expanded(
          child: provider.isRecruitmentLoading(_meta?.recruitmentId ?? 0) && apps.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? Center(
                      child: Text(_filter == 'pending'
                          ? '暂无待处理申请'
                          : '暂无${_statusLabel(_filter)}记录'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) => _ApplicationCard(
                              application: filtered[index],
                              onReview: _review))),
        ),
      ]),
    );
  }

  Widget _buildFilterBar(List<WaterTeamApplication> apps) {
    final statuses = ['pending', 'accepted', 'rejected', 'cancelled'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
          children: statuses.map((status) {
        final selected = _filter == status;
        final count = apps.where((app) => app.status == status).length;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
              label: Text('${_statusLabel(status)} $count'),
              selected: selected,
              onSelected: (_) => setState(() => _filter = status)),
        );
      }).toList()),
    );
  }

  String _statusLabel(String status) =>
      const {
        'pending': '待处理',
        'accepted': '已通过',
        'rejected': '已拒绝',
        'cancelled': '已取消'
      }[status] ??
      status;

  Future<void> _review(WaterTeamApplication application, bool accept) async {
    final provider = context.read<WaterTeamProvider>();
    if (provider.isApplicationProcessing(application.id)) return;
    if (accept) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
                title: const Text('确认通过该申请？'),
                content: const Text('通过后将占用一个招募名额。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认通过'))
                ],
              ));
      if (confirmed != true) return;
    }
    String reply = '';
    if (!accept) {
      final value = await _showReplyDialog();
      if (value == null) return;
      reply = value;
    }
    if (!mounted) return;
    final success = await provider.review(
      applicationId: application.id,
      accept: accept,
      reply: reply,
      recruitmentId: application.recruitmentId,
      postId: application.postId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? (accept ? '已通过申请' : '已拒绝申请')
            : (provider.errorFor(application.recruitmentId) ?? '操作失败'))));
    if (success) setState(() {});
  }

  Future<String?> _showReplyDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('拒绝申请'),
              content: TextField(
                  controller: controller,
                  maxLines: 4,
                  maxLength: 500,
                  decoration: const InputDecoration(
                      hintText: '回复申请人（选填）', border: OutlineInputBorder())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('确认拒绝'))
              ],
            ));
    controller.dispose();
    return value;
  }
}

class _ApplicationCard extends StatelessWidget {
  final WaterTeamApplication application;
  final Future<void> Function(WaterTeamApplication, bool) onReview;

  const _ApplicationCard({required this.application, required this.onReview});

  @override
  Widget build(BuildContext context) {
    final applicant = application.applicant;
    final name =
        applicant?.nickname.isNotEmpty == true ? applicant!.nickname : '匿名用户';
    final subtitle = applicant == null
        ? ''
        : '${applicant.eduMajor.isNotEmpty ? applicant.eduMajor : '校园用户'} · ${applicant.levelLabel}';
    final isPending = application.status == 'pending';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
                radius: 21,
                backgroundImage: applicant?.avatar.isNotEmpty == true
                    ? NetworkImage(applicant!.avatar)
                    : null,
                child: applicant?.avatar.isNotEmpty == true
                    ? null
                    : Text(name.isEmpty ? '?' : name.substring(0, 1))),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(name,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600))
                ])),
            _StatusBadge(status: application.status),
          ]),
          const SizedBox(height: 12),
          Text(application.message, style: const TextStyle(height: 1.45)),
          if (application.availability.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('可参与时间：${application.availability}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700))
          ],
          const SizedBox(height: 8),
          Text('申请于 ${_formatDate(application.createdAt)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          if (isPending) ...[
            const SizedBox(height: 12),
            Builder(builder: (context) {
              final processing = context
                  .watch<WaterTeamProvider>()
                  .isApplicationProcessing(application.id);
              return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                    onPressed:
                        processing ? null : () => onReview(application, false),
                    child: const Text('拒绝')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed:
                        processing ? null : () => onReview(application, true),
                    child: const Text('通过'))
              ]);
            }),
          ],
          if (!isPending && application.ownerReply.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('回复：${application.ownerReply}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700))
          ],
        ]),
      ),
    );
  }

  String _formatDate(DateTime value) =>
      '${value.month} 月 ${value.day} 日 ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});
  @override
  Widget build(BuildContext context) {
    final label = const {
          'pending': '待处理',
          'accepted': '已通过',
          'rejected': '已拒绝',
          'cancelled': '已取消'
        }[status] ??
        status;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)));
  }
}
