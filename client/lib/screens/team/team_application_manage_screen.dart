import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/team_recruitment.dart';
import '../../models/water_team.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../widgets/team/team_ui_tokens.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = TeamUiTokens.border(isDark);
    final replyController = TextEditingController();
    final inputDeco = InputDecoration(
      filled: true,
      fillColor: Colors.transparent,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: TeamUiTokens.accent(isDark), width: 1.5)),
    );
    final reply = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(accepted ? '通过申请' : '拒绝申请'),
        content: TextField(
          controller: replyController,
          maxLength: 300,
          maxLines: 3,
          cursorColor: TeamUiTokens.accent(isDark),
          decoration: inputDeco.copyWith(
            labelText: accepted ? '给申请人的回复（选填）' : '简要说明原因（选填）',
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
                foregroundColor: TeamUiTokens.subtitle(isDark)),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accepted
                  ? TeamUiTokens.accent(isDark)
                  : const Color(0xFFE54848),
              foregroundColor: Colors.white,
            ),
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

  Future<void> _remove(WaterTeamApplication app) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('移除成员'),
            content: const Text('移除后名额会重新开放，确定继续吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认移除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final error = await context.read<TeamRecruitmentProvider>().remove(app.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error ?? '已移除成员')));
    if (error == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = TeamUiTokens.pageBg(isDark);
    final apps = provider
        .applicationsFor(widget.recruitment.id)
        .where((item) => item.status == _filter)
        .toList();
    final loading =
        provider.loadingApplicationIds.contains(widget.recruitment.id);
    final loadError = provider.applicationErrors[widget.recruitment.id];
    return Scaffold(
      backgroundColor: pageColor,
      appBar: AppBar(
        backgroundColor: pageColor,
        surfaceTintColor: Colors.transparent,
        title: const Text('申请管理'),
      ),
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
              ('已退出', 'withdrawn'),
              ('已移除', 'removed'),
            ]
                .map((item) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(item.$1),
                        selected: _filter == item.$2,
                        selectedColor: TeamUiTokens.accentSoft(isDark),
                        labelStyle: TextStyle(
                          color: _filter == item.$2
                              ? TeamUiTokens.accent(isDark)
                              : TeamUiTokens.subtitle(isDark),
                          fontWeight: _filter == item.$2
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: _filter == item.$2
                                  ? Colors.transparent
                                  : TeamUiTokens.border(isDark)),
                        ),
                        onSelected: (_) => setState(() => _filter = item.$2),
                      ),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: TeamUiTokens.accent(isDark),
            onRefresh: _load,
            child: loading && apps.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : loadError != null && apps.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Icon(Icons.wifi_off_rounded,
                              size: 34, color: TeamUiTokens.subtitle(isDark)),
                          const SizedBox(height: 12),
                          Center(child: Text(loadError)),
                          Center(
                            child: TextButton(
                              onPressed: _load,
                              child: const Text('重新加载'),
                            ),
                          ),
                        ],
                      )
                    : apps.isEmpty
                        ? Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 64,
                                    height: 64,
                                    decoration: BoxDecoration(
                                      color: TeamUiTokens.accentSoft(isDark),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Icon(Icons.inbox_outlined,
                                        size: 30,
                                        color: TeamUiTokens.accent(isDark)),
                                  ),
                                  const SizedBox(height: 16),
                                  Text('暂无记录',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: TeamUiTokens.title(isDark))),
                                ]),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: apps.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, index) => _ApplicationCard(
                                application: apps[index],
                                reviewing: provider.reviewingApplicationIds
                                    .contains(apps[index].id),
                                onReview: _review,
                                onRemove: _remove),
                          ),
          ),
        ),
      ]),
    );
  }
}

class _ApplicationCard extends StatelessWidget {
  final WaterTeamApplication application;
  final bool reviewing;
  final Future<void> Function(WaterTeamApplication, bool) onReview;
  final Future<void> Function(WaterTeamApplication) onRemove;
  const _ApplicationCard({
    required this.application,
    required this.reviewing,
    required this.onReview,
    required this.onRemove,
  });
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: TeamUiTokens.cardBg(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeamUiTokens.cardRadius),
          side: BorderSide(color: TeamUiTokens.border(isDark)),
        ),
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  application.applicant?.nickname.isNotEmpty == true
                      ? application.applicant!.nickname
                      : '校园用户',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: TeamUiTokens.title(isDark))),
              if (application.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(application.message)
              ],
              if (application.availability.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('可参与时间：${application.availability}',
                    style: TextStyle(
                        fontSize: 12, color: TeamUiTokens.subtitle(isDark)))
              ],
              if (application.status == 'pending') ...[
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE54848),
                        side: const BorderSide(
                            color: Color(0xFFE54848), width: 0.8),
                      ),
                      onPressed:
                          reviewing ? null : () => onReview(application, false),
                      child: const Text('拒绝')),
                  const SizedBox(width: 8),
                  FilledButton(
                      style: TeamUiTokens.primaryButtonStyle(isDark),
                      onPressed:
                          reviewing ? null : () => onReview(application, true),
                      child: Text(reviewing ? '处理中…' : '通过'))
                ])
              ] else if (application.status == 'accepted') ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE54848),
                      side: const BorderSide(color: Color(0xFFE54848)),
                    ),
                    onPressed: reviewing ? null : () => onRemove(application),
                    icon: const Icon(Icons.person_remove_outlined),
                    label: Text(reviewing ? '处理中…' : '移除成员'),
                  ),
                ),
              ],
            ])));
  }
}
