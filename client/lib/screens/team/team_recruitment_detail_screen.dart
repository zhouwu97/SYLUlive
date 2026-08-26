import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/api_constants.dart';
import '../../models/team_recruitment.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../utils/team_share_link.dart';
import '../../widgets/team/team_application_sheet.dart';
import '../../widgets/team/team_recruitment_card.dart';
import '../chat_detail_screen.dart';
import '../../widgets/team/team_ui_tokens.dart';
import 'team_application_manage_screen.dart';
import 'team_recruitment_create_screen.dart';
import '../../widgets/cached_avatar.dart';
import '../../widgets/app_cached_image.dart';

class TeamRecruitmentDetailScreen extends StatefulWidget {
  final int recruitmentId;
  const TeamRecruitmentDetailScreen({super.key, required this.recruitmentId});
  @override
  State<TeamRecruitmentDetailScreen> createState() =>
      _TeamRecruitmentDetailScreenState();
}

class _TeamRecruitmentDetailScreenState
    extends State<TeamRecruitmentDetailScreen> {
  TeamRecruitment? _item;
  bool _loading = true;
  String? _error;
  int _lastSessionVersion = -1;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sessionVersion =
        context.watch<TeamRecruitmentProvider>().sessionVersion;
    if (_lastSessionVersion == sessionVersion) return;
    _lastSessionVersion = sessionVersion;
    _loadVersion++;
    _item = null;
    _loading = true;
    _error = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final loadVersion = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    final item = await context
        .read<TeamRecruitmentProvider>()
        .loadDetail(widget.recruitmentId);
    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      _item = item;
      _loading = false;
      _error = item == null ? '加载组队详情失败' : null;
    });
  }

  Future<void> _apply(TeamRecruitment item) async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      Navigator.pushNamed(context, '/login');
      return;
    }
    final application = await _applicationSheet();
    if (application == null || !mounted) return;
    final error = await context.read<TeamRecruitmentProvider>().apply(
          recruitmentId: item.id,
          message: application.message,
          availability: application.availability,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error ?? '申请已提交')));
    if (error == null) {
      _load();
    }
  }

  Future<({String message, String availability})?> _applicationSheet() async {
    return TeamRecruitmentApplicationSheet.show(context);
  }

  Future<void> _changeStatus(TeamRecruitment item, String status) async {
    if (context.read<TeamRecruitmentProvider>().closingIds.contains(item.id)) {
      return;
    }
    final error = await context
        .read<TeamRecruitmentProvider>()
        .updateStatus(item.id, status);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error ?? (status == 'closed' ? '已关闭招募' : '已重新开启招募'))));
    if (error == null) {
      _load();
    }
  }

  Future<void> _delete(TeamRecruitment item) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除组队'),
            content: Text('“${item.title}”将从组队大厅和相关列表中移除，删除后无法恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE54848),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    final error = await context
        .read<TeamRecruitmentProvider>()
        .deleteRecruitment(item.id);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('组队已删除')));
    Navigator.pop(context, true);
  }

  Future<void> _share(TeamRecruitment item) async {
    final link = TeamShareLink.webUri(item.id).toString();
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    try {
      await Share.share(
        '我在沈理校园发起了组队：${item.title}\n$link',
        subject: '${item.title} - 沈理校园组队',
        sharePositionOrigin: origin,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂时无法调起分享，请稍后重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_item == null) {
      return Scaffold(
          appBar: AppBar(), body: Center(child: Text(_error ?? '招募不存在')));
    }
    final item = _item!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = TeamUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: pageColor,
      appBar: AppBar(
        backgroundColor: pageColor,
        surfaceTintColor: Colors.transparent,
        title: const Text('组队详情'),
        actions: [
          if (item.isOwner)
            IconButton(
              tooltip: '编辑招募',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        TeamRecruitmentCreateScreen(initialValue: item),
                  ),
                );
                if (changed == true && mounted) _load();
              },
            ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.ios_share_outlined),
            onPressed: () => _share(item),
          ),
          if (item.isOwner)
            IconButton(
              tooltip: '删除组队',
              icon: context
                      .watch<TeamRecruitmentProvider>()
                      .deletingIds
                      .contains(item.id)
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline_rounded),
              onPressed: context
                      .watch<TeamRecruitmentProvider>()
                      .deletingIds
                      .contains(item.id)
                  ? null
                  : () => _delete(item),
            ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: pageColor,
          border: Border(top: BorderSide(color: TeamUiTokens.border(isDark))),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 48,
              child: _bottomAction(item, isDark),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
          color: TeamUiTokens.accent(isDark),
          onRefresh: _load,
          child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 110),
              children: [
                Row(children: [
                  TeamStatusBadge(status: item.effectiveStatus),
                  const SizedBox(width: 8),
                  Text(teamCategoryLabel(item.category),
                      style: TextStyle(
                          color: teamCategoryColor(item.category),
                          fontWeight: FontWeight.w700))
                ]),
                const SizedBox(height: 12),
                Text(item.title,
                    style: const TextStyle(
                        fontSize: 23,
                        height: 1.25,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                Row(children: [
                  CachedAvatar(
                    radius: 20,
                    imageUrl: ApiConstants.fullUrl(item.author.avatar),
                    fallbackText: item.author.name,
                  ),
                  const SizedBox(width: 9),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.author.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        if (item.author.major.isNotEmpty)
                          Text(item.author.major,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: TeamUiTokens.subtitle(isDark)))
                      ])
                ]),
                const SizedBox(height: 24),
                _section(
                    '组队说明',
                    [
                      Text(item.description,
                          style: const TextStyle(height: 1.65)),
                    ],
                    isDark),
                const SizedBox(height: 24),
                _section(
                    '招募信息',
                    [
                      _infoRow(
                          Icons.group_outlined,
                          '已加入 ${item.acceptedCount} / 计划招募 ${item.neededCount}，还缺 ${item.remainingCount} 人',
                          isDark),
                      _infoRow(
                          Icons.event_outlined,
                          item.deadline == null
                              ? '未设置截止日期'
                              : '截止 ${item.deadline!.year}-${item.deadline!.month.toString().padLeft(2, '0')}-${item.deadline!.day.toString().padLeft(2, '0')}',
                          isDark),
                      if (item.roles.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: item.roles
                                .map((role) => Chip(
                                      label: Text(role),
                                      backgroundColor:
                                          TeamUiTokens.pageBg(isDark),
                                      side: BorderSide(
                                          color: TeamUiTokens.border(isDark)),
                                    ))
                                .toList())
                      ],
                    ],
                    isDark),
                if (item.images.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Padding(
                    padding: EdgeInsets.only(left: 4, bottom: 8),
                    child: Text('图片',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  SizedBox(
                      height: 130,
                      child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: item.images.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, index) => ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: AppCachedImage.public(
                                imageUrl: ApiConstants.fullUrl(
                                  item.images[index].url,
                                ),
                                width: 170,
                                height: 130,
                                fit: BoxFit.cover,
                                memCacheWidth: 340,
                                memCacheHeight: 260,
                              ))))
                ],
              ])),
    );
  }

  Widget _section(String title, List<Widget> children, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: TeamUiTokens.title(isDark),
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TeamUiTokens.cardBg(isDark),
            borderRadius: BorderRadius.circular(TeamUiTokens.cardRadius),
            border: Border.all(color: TeamUiTokens.border(isDark)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text, bool isDark) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: TeamUiTokens.subtitle(isDark)),
        const SizedBox(width: 8),
        Expanded(child: Text(text))
      ]));

  Widget _bottomAction(TeamRecruitment item, bool isDark) {
    if (item.isOwner) {
      final updatingStatus =
          context.watch<TeamRecruitmentProvider>().closingIds.contains(item.id);
      return Row(children: [
        Expanded(
            child: OutlinedButton(
                style: TeamUiTokens.secondaryButtonStyle(isDark),
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              TeamApplicationManageScreen(recruitment: item)));
                  _load();
                },
                child: Text(
                    '管理申请${item.pendingApplicationCount > 0 ? ' (${item.pendingApplicationCount})' : ''}'))),
        const SizedBox(width: 10),
        Expanded(
            child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: item.isClosed
                      ? TeamUiTokens.accent(isDark)
                      : const Color(0xFFE54848),
                  foregroundColor: Colors.white,
                ),
                onPressed: updatingStatus
                    ? null
                    : item.isClosed
                        ? () => _changeStatus(item, 'recruiting')
                        : () => _changeStatus(item, 'closed'),
                child: Text(updatingStatus
                    ? '处理中…'
                    : item.isClosed
                        ? '重新开启'
                        : '关闭招募'))),
      ]);
    }
    if (item.myApplicationStatus == 'pending') {
      return FilledButton(
          style: TeamUiTokens.primaryButtonStyle(isDark),
          onPressed: null,
          child: const Text('等待审核'));
    }
    if (item.myApplicationStatus == 'accepted') {
      final applicationId = item.myApplicationId;
      final processing = applicationId != null &&
          context
              .watch<TeamRecruitmentProvider>()
              .reviewingApplicationIds
              .contains(applicationId);
      return Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            style: TeamUiTokens.secondaryButtonStyle(isDark),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ChatDetailScreen(targetUser: _authorAsUser(item)),
              ),
            ),
            icon: const Icon(Icons.mail_outline_rounded),
            label: const Text('私信'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE54848),
              foregroundColor: Colors.white,
            ),
            onPressed: applicationId == null || processing
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('退出队伍'),
                            content: const Text('退出后名额会重新开放，确定继续吗？'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('确认退出'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (!confirmed || !mounted) return;
                    final error = await context
                        .read<TeamRecruitmentProvider>()
                        .leave(applicationId);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error ?? '已退出队伍')));
                    if (error == null) _load();
                  },
            icon: const Icon(Icons.logout_rounded),
            label: Text(processing ? '处理中…' : '退出'),
          ),
        ),
      ]);
    }
    if (!item.canApply) {
      return FilledButton(
          style: TeamUiTokens.primaryButtonStyle(isDark),
          onPressed: null,
          child: Text(item.isFull
              ? '已满员'
              : item.isExpired
                  ? '已截止'
                  : '暂不可申请'));
    }
    final applying =
        context.watch<TeamRecruitmentProvider>().applyingIds.contains(item.id);
    return FilledButton(
        style: TeamUiTokens.primaryButtonStyle(isDark),
        onPressed: applying ? null : () => _apply(item),
        child: Text(applying ? '提交中…' : '申请加入'));
  }

  User _authorAsUser(TeamRecruitment item) => User(
        id: item.author.id,
        studentId: '',
        nickname: item.author.name,
        avatar: item.author.avatar,
        eduMajor: item.author.major,
        createdAt: item.createdAt,
      );
}
