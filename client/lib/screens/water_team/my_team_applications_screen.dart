import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/water_team.dart';
import '../../providers/water_team_provider.dart';
import '../post_detail_screen.dart';

/// 当前用户提交过的组队申请。
class MyTeamApplicationsScreen extends StatefulWidget {
  const MyTeamApplicationsScreen({super.key});

  @override
  State<MyTeamApplicationsScreen> createState() =>
      _MyTeamApplicationsScreenState();
}

class _MyTeamApplicationsScreenState extends State<MyTeamApplicationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() => context
          .read<WaterTeamProvider>()
          .loadMyApplications(force: true)
          .then((_) {
        if (mounted) setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WaterTeamProvider>();
    final apps = provider.myApplications;
    final groups = <String, List<WaterTeamApplication>>{
      'pending': apps.where((app) => app.status == 'pending').toList(),
      'accepted': apps.where((app) => app.status == 'accepted').toList(),
      'rejected': apps.where((app) => app.status == 'rejected').toList(),
      'cancelled': apps.where((app) => app.status == 'cancelled').toList(),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('我的组队申请'), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))
      ]),
      body: provider.isLoadingMyApplications && apps.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : apps.isEmpty && provider.myApplicationsError != null
              ? _buildErrorView(provider)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      children: [
                        for (final entry in groups.entries) ...[
                          if (entry.value.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
                                child: Text(
                                    '${_label(entry.key)} ${entry.value.length}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800))),
                          ...entry.value.map((app) => _MyApplicationCard(
                              application: app,
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => PostDetailScreen(
                                          postId: app.postId,
                                          initialPost: app.post))))),
                        ],
                        if (apps.isEmpty && provider.myApplicationsError == null)
                          const Padding(
                              padding: EdgeInsets.only(top: 160),
                              child: Center(child: Text('还没有组队申请'))),
                      ])),
    );
  }

  Widget _buildErrorView(WaterTeamProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 14),
            Text(provider.myApplicationsError ?? '加载失败',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 15)),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  String _label(String status) =>
      const {
        'pending': '等待处理',
        'accepted': '已加入',
        'rejected': '未通过',
        'cancelled': '已取消'
      }[status] ??
      status;
}

class _MyApplicationCard extends StatelessWidget {
  final WaterTeamApplication application;
  final VoidCallback onTap;
  const _MyApplicationCard({required this.application, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = application.post?.title.isNotEmpty == true
        ? application.post!.title
        : '组队招募帖子 #${application.postId}';
    return Card(
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800))),
                        _StatusBadge(status: application.status)
                      ]),
                      const SizedBox(height: 8),
                      Text(application.message,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (application.ownerReply.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('回复：${application.ownerReply}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade700))
                      ],
                      const SizedBox(height: 8),
                      Text(
                          '申请于 ${application.createdAt.month} 月 ${application.createdAt.day} 日',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                      if (application.status == 'pending')
                        Align(
                            alignment: Alignment.centerRight,
                            child: Builder(builder: (context) {
                              final processing = context
                                  .watch<WaterTeamProvider>()
                                  .isApplicationProcessing(application.id);
                              return TextButton(
                                  onPressed:
                                      processing ? null : () => _cancel(context),
                                  child: processing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Text('取消申请'));
                            })),
                    ]))));
  }

  Future<void> _cancel(BuildContext context) async {
    final provider = context.read<WaterTeamProvider>();
    if (provider.isApplicationProcessing(application.id)) return;
    final result = await provider.cancel(
      applicationId: application.id,
      recruitmentId: application.recruitmentId,
      postId: application.postId,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.isSuccess
            ? '申请已取消'
            : (result.error ?? '取消申请失败'))));
    if (result.isSuccess) await provider.loadMyApplications(force: true);
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});
  @override
  Widget build(BuildContext context) => Chip(
      label: Text(const {
            'pending': '待处理',
            'accepted': '已通过',
            'rejected': '已拒绝',
            'cancelled': '已取消'
          }[status] ??
          status),
      visualDensity: VisualDensity.compact);
}
