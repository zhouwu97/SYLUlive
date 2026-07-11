import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/team_recruitment.dart';
import '../../models/water_team.dart';
import '../../providers/team_recruitment_provider.dart';

class TeamApplicationManageScreen extends StatefulWidget {
  final TeamRecruitment recruitment;
  const TeamApplicationManageScreen({super.key, required this.recruitment});
  @override
  State<TeamApplicationManageScreen> createState() =>
      _TeamApplicationManageScreenState();
}

class _TeamApplicationManageScreenState
    extends State<TeamApplicationManageScreen> {
  String _filter = 'pending';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() => context
      .read<TeamRecruitmentProvider>()
      .loadApplications(widget.recruitment.id);
  Future<void> _review(WaterTeamApplication app, bool accepted) async {
    final replyController = TextEditingController();
    final reply = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(accepted ? '通过申请' : '拒绝申请'),
        content: TextField(
          controller: replyController,
          maxLength: 300,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: accepted ? '给申请人的回复（选填）' : '简要说明原因（选填）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, replyController.text.trim()),
            child: Text(accepted ? '通过' : '拒绝'),
          ),
        ],
      ),
    );
    replyController.dispose();
    if (reply == null || !mounted) return;
    final error = await context
        .read<TeamRecruitmentProvider>()
        .review(app.id, accepted: accepted, reply: reply);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? (accepted ? '已通过申请' : '已拒绝申请'))));
    if (error == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    final apps = provider
        .applicationsFor(widget.recruitment.id)
        .where((item) => item.status == _filter)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('申请管理')),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: const [
              ('待审核', 'pending'),
              ('已通过', 'accepted'),
              ('已拒绝', 'rejected'),
              ('已取消', 'cancelled'),
            ]
                .map((item) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(item.$1),
                        selected: _filter == item.$2,
                        onSelected: (_) => setState(() => _filter = item.$2),
                      ),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: apps.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 220),
                    Center(child: Text('暂无记录'))
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: apps.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, index) => _ApplicationCard(
                        application: apps[index], onReview: _review),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _ApplicationCard extends StatelessWidget {
  final WaterTeamApplication application;
  final Future<void> Function(WaterTeamApplication, bool) onReview;
  const _ApplicationCard({required this.application, required this.onReview});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                application.applicant?.nickname.isNotEmpty == true
                    ? application.applicant!.nickname
                    : '校园用户',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            if (application.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(application.message)
            ],
            if (application.availability.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('可参与时间：${application.availability}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700))
            ],
            if (application.status == 'pending') ...[
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                    onPressed: () => onReview(application, false),
                    child: const Text('拒绝')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: () => onReview(application, true),
                    child: const Text('通过'))
              ])
            ],
          ])));
}
