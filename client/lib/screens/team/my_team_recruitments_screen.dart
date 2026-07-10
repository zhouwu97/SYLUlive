import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/water_team.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../widgets/team/team_recruitment_card.dart';
import 'team_recruitment_detail_screen.dart';

class MyTeamRecruitmentsScreen extends StatefulWidget {
  const MyTeamRecruitmentsScreen({super.key});
  @override
  State<MyTeamRecruitmentsScreen> createState() =>
      _MyTeamRecruitmentsScreenState();
}

class _MyTeamRecruitmentsScreenState extends State<MyTeamRecruitmentsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() => context.read<TeamRecruitmentProvider>().loadMine();
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    return Scaffold(
      appBar: AppBar(
          title: const Text('我的组队'),
          bottom: TabBar(
              controller: _tabs,
              tabs: const [Tab(text: '我发起的'), Tab(text: '我申请的')])),
      body: provider.isLoadingMine && provider.myCreated.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tabs, children: [
              RefreshIndicator(
                onRefresh: _load,
                child: provider.myCreated.isEmpty
                    ? _emptyList('还没有发起组队')
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: provider.myCreated.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final item = provider.myCreated[index];
                          return TeamRecruitmentCard(
                            recruitment: item,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => TeamRecruitmentDetailScreen(
                                  recruitmentId: item.id,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              RefreshIndicator(
                  onRefresh: _load,
                  child: provider.myApplications.isEmpty
                      ? _emptyList('还没有组队申请')
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: provider.myApplications.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) => _ApplicationItem(
                              application: provider.myApplications[index],
                              onCancelled: _load))),
            ]),
    );
  }

  Widget _emptyList(String text) => ListView(children: [
        const SizedBox(height: 220),
        Center(child: Text(text, style: TextStyle(color: Colors.grey.shade600)))
      ]);
}

class _ApplicationItem extends StatelessWidget {
  final WaterTeamApplication application;
  final Future<void> Function() onCancelled;
  const _ApplicationItem(
      {required this.application, required this.onCancelled});
  @override
  Widget build(BuildContext context) {
    final label = const {
          'pending': '等待审核',
          'accepted': '已加入',
          'rejected': '未通过',
          'cancelled': '已取消'
        }[application.status] ??
        application.status;
    final title = application.post?.title.isNotEmpty == true
        ? application.post!.title
        : '组队招募 #${application.recruitmentId}';
    return Card(
        child: ListTile(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TeamRecruitmentDetailScreen(
                  recruitmentId: application.recruitmentId))),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(
          application.ownerReply.isEmpty
              ? application.message
              : '回复：${application.ownerReply}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (application.status == 'pending')
              TextButton(
                  onPressed: () async {
                    final error = await context
                        .read<TeamRecruitmentProvider>()
                        .cancel(application.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error ?? '已取消申请')));
                    if (error == null) onCancelled();
                  },
                  child: const Text('取消'))
          ]),
    ));
  }
}
