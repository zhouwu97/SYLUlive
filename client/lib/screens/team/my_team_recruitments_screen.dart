import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/water_team.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../widgets/team/team_recruitment_card.dart';
import '../../widgets/team/team_ui_tokens.dart';
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = TeamUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: pageColor,
      appBar: AppBar(
          backgroundColor: pageColor,
          surfaceTintColor: Colors.transparent,
          title: const Text('我的组队'),
          bottom: TabBar(
            controller: _tabs,
            indicatorColor: TeamUiTokens.accent(isDark),
            labelColor: TeamUiTokens.accent(isDark),
            unselectedLabelColor: TeamUiTokens.subtitle(isDark),
            tabs: [
              Tab(text: '我发起的 ${provider.myCreated.length}'),
              Tab(text: '我申请的 ${provider.myApplications.length}'),
            ],
          )),
      body: provider.isLoadingMine && provider.myCreated.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tabs, children: [
              RefreshIndicator(
                color: TeamUiTokens.accent(isDark),
                onRefresh: _load,
                child: provider.myCreated.isEmpty
                    ? _emptyList('还没有发起组队', isDark)
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
                  color: TeamUiTokens.accent(isDark),
                  onRefresh: _load,
                  child: provider.myApplications.isEmpty
                      ? _emptyList('还没有组队申请', isDark)
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

  Widget _emptyList(String text, bool isDark) => Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 100),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: TeamUiTokens.accentSoft(isDark),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.groups_2_outlined,
                size: 30, color: TeamUiTokens.accent(isDark)),
          ),
          const SizedBox(height: 16),
          Text(text,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: TeamUiTokens.title(isDark))),
        ]),
      );
}

class _ApplicationItem extends StatelessWidget {
  final WaterTeamApplication application;
  final Future<void> Function() onCancelled;
  const _ApplicationItem(
      {required this.application, required this.onCancelled});
  @override
  Widget build(BuildContext context) {
    final cancelling = context
        .watch<TeamRecruitmentProvider>()
        .reviewingApplicationIds
        .contains(application.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = const {
          'pending': '等待审核',
          'accepted': '已加入',
          'rejected': '未通过',
          'cancelled': '已取消'
        }[application.status] ??
        application.status;
    final statusColor = const {
          'pending': Color(0xFFE5A100),
          'accepted': Color(0xFF147C72),
          'rejected': Color(0xFFE54848),
        }[application.status] ??
        TeamUiTokens.subtitle(isDark);
    final title = application.post?.title.isNotEmpty == true
        ? application.post!.title
        : '组队招募 #${application.recruitmentId}';
    return Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: TeamUiTokens.cardBg(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeamUiTokens.cardRadius),
          side: BorderSide(color: TeamUiTokens.border(isDark)),
        ),
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
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: TeamUiTokens.subtitle(isDark))),
          trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: statusColor)),
                if (application.status == 'pending')
                  TextButton(
                      style: TextButton.styleFrom(
                          foregroundColor: TeamUiTokens.accent(isDark)),
                      onPressed: cancelling
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (dialogContext) => AlertDialog(
                                      title: const Text('撤回申请'),
                                      content:
                                          const Text('撤回后可在需要时重新申请，确定继续吗？'),
                                      actions: [
                                        TextButton(
                                          style: TextButton.styleFrom(
                                              foregroundColor:
                                                  TeamUiTokens.subtitle(
                                                      isDark)),
                                          onPressed: () => Navigator.pop(
                                              dialogContext, false),
                                          child: const Text('暂不撤回'),
                                        ),
                                        FilledButton(
                                          style:
                                              TeamUiTokens.primaryButtonStyle(
                                                  isDark),
                                          onPressed: () => Navigator.pop(
                                              dialogContext, true),
                                          child: const Text('确认撤回'),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!confirmed || !context.mounted) return;
                              final error = await context
                                  .read<TeamRecruitmentProvider>()
                                  .cancel(application.id);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error ?? '已取消申请')));
                              if (error == null) onCancelled();
                            },
                      child: Text(cancelling ? '处理中…' : '撤回'))
              ]),
        ));
  }
}
