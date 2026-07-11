import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/team_recruitment.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../widgets/team/team_recruitment_card.dart';
import '../chat_detail_screen.dart';
import 'team_application_manage_screen.dart';
import 'team_recruitment_create_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final item = await context
        .read<TeamRecruitmentProvider>()
        .loadDetail(widget.recruitmentId);
    if (!mounted) return;
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
    final messageController = TextEditingController();
    final availabilityController = TextEditingController();
    final result =
        await showModalBottomSheet<({String message, String availability})>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20,
                      MediaQuery.viewInsetsOf(sheetContext).bottom + 20),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('申请加入',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        TextField(
                            controller: messageController,
                            maxLines: 4,
                            maxLength: 500,
                            decoration: const InputDecoration(
                                labelText: '申请说明 *',
                                hintText: '介绍你的经验、能力和加入原因',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 10),
                        TextField(
                            controller: availabilityController,
                            maxLines: 2,
                            maxLength: 200,
                            decoration: const InputDecoration(
                                labelText: '可参与时间（选填）',
                                hintText: '例如：工作日晚 7 点后，周末全天',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 10),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                                onPressed: () {
                                  final message = messageController.text.trim();
                                  if (message.length < 5) return;
                                  Navigator.pop(sheetContext, (
                                    message: message,
                                    availability:
                                        availabilityController.text.trim(),
                                  ));
                                },
                                child: const Text('提交申请'))),
                      ]),
                ));
    messageController.dispose();
    availabilityController.dispose();
    return result;
  }

  Future<void> _changeStatus(TeamRecruitment item, String status) async {
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
    return Scaffold(
      appBar: AppBar(
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
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('分享链接功能即将支持')),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(16), child: _bottomAction(item))),
      body: RefreshIndicator(
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
                  CircleAvatar(
                      backgroundImage: item.author.avatar.isEmpty
                          ? null
                          : NetworkImage(item.author.avatar),
                      child: item.author.avatar.isEmpty
                          ? Text(item.author.name.substring(0, 1))
                          : null),
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
                                  fontSize: 12, color: Colors.grey.shade600))
                      ])
                ]),
                const SizedBox(height: 24),
                const Text('组队说明',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(item.description, style: const TextStyle(height: 1.65)),
                const SizedBox(height: 24),
                const Text('招募信息',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                _infoRow(Icons.group_outlined,
                    '已加入 ${item.acceptedCount} / 计划招募 ${item.neededCount}，还缺 ${item.remainingCount} 人'),
                _infoRow(
                    Icons.event_outlined,
                    item.deadline == null
                        ? '未设置截止日期'
                        : '截止 ${item.deadline!.year}-${item.deadline!.month.toString().padLeft(2, '0')}-${item.deadline!.day.toString().padLeft(2, '0')}'),
                if (item.roles.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: item.roles
                          .map((role) => Chip(label: Text(role)))
                          .toList())
                ],
                if (item.images.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text('图片',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  SizedBox(
                      height: 130,
                      child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: item.images.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, index) => ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                ApiConstants.fullUrl(item.images[index].url),
                                width: 170,
                                fit: BoxFit.cover,
                              ))))
                ],
              ])),
    );
  }

  Widget _infoRow(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Expanded(child: Text(text))
      ]));

  Widget _bottomAction(TeamRecruitment item) {
    if (item.isOwner) {
      return Row(children: [
        Expanded(
            child: OutlinedButton(
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              TeamApplicationManageScreen(recruitment: item)));
                  _load();
                },
                child: Text(
                    '管理申请${item.applicationCount > 0 ? ' (${item.applicationCount})' : ''}'))),
        const SizedBox(width: 10),
        Expanded(
            child: FilledButton(
                onPressed: item.isClosed
                    ? () => _changeStatus(item, 'recruiting')
                    : () => _changeStatus(item, 'closed'),
                child: Text(item.isClosed ? '重新开启' : '关闭招募'))),
      ]);
    }
    if (item.myApplicationStatus == 'pending') {
      return const FilledButton(onPressed: null, child: Text('等待审核'));
    }
    if (item.myApplicationStatus == 'accepted') {
      return FilledButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatDetailScreen(targetUser: _authorAsUser(item)),
          ),
        ),
        icon: const Icon(Icons.mail_outline_rounded),
        label: const Text('私信发起人'),
      );
    }
    if (!item.canApply) {
      return FilledButton(
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
