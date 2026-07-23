import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_award.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_award_editor_screen.dart';

class CompetitionAwardScreen extends StatefulWidget {
  final Dio dio;
  final Object accountKey;

  const CompetitionAwardScreen({
    super.key,
    required this.dio,
    required this.accountKey,
  });

  @override
  State<CompetitionAwardScreen> createState() => _CompetitionAwardScreenState();
}

class _CompetitionAwardScreenState extends State<CompetitionAwardScreen> {
  List<CompetitionAward> _items = const [];
  bool _loading = true;
  String? _error;
  int _loadSerial = 0;
  final Set<int> _deleting = {};
  final Set<int> _changingVerification = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CompetitionAwardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountKey != widget.accountKey) {
      setState(() {
        _items = const [];
        _loading = true;
        _error = null;
        _deleting.clear();
        _changingVerification.clear();
      });
      _load();
    }
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    if (mounted) setState(() => _loading = true);
    try {
      final response = await widget.dio.get('/user/competition-awards');
      final data = Map<String, dynamic>.from(response.data as Map);
      final items = ((data['items'] as List?) ?? const [])
          .map((item) =>
              CompetitionAward.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '竞赛经历加载失败')
            : '竞赛经历数据解析失败';
      });
    }
  }

  Future<void> _openEditor([CompetitionAward? initial]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CompetitionAwardEditorScreen(
          dio: widget.dio,
          initial: initial,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _delete(CompetitionAward award) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除竞赛经历？'),
        content: Text('“${award.competitionTitle}”将从你的私有档案中删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || _deleting.contains(award.id)) return;
    setState(() => _deleting.add(award.id));
    try {
      await widget.dio.delete('/user/competition-awards/${award.id}');
      if (!mounted) return;
      setState(
          () => _items = _items.where((item) => item.id != award.id).toList());
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('竞赛经历已删除')));
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '删除失败')
              : '删除失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _deleting.remove(award.id));
    }
  }

  Future<void> _changeVerification(
    CompetitionAward award, {
    required bool submit,
  }) async {
    if (_changingVerification.contains(award.id)) return;
    if (submit && award.evidenceFileIds.isEmpty) {
      AppFeedback.showSnackBar(context, '请先编辑经历并上传至少一份证明材料', isError: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(submit ? '提交材料核验？' : '取消材料核验？'),
        content: Text(
            submit ? '提交后，比赛信息和证明材料在核验完成前不可修改。' : '取消后将恢复为“本人填写”，你可以继续修改材料。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(submit ? '确认提交' : '确认取消'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changingVerification.add(award.id));
    try {
      final action = submit ? 'submit-verification' : 'cancel-verification';
      await widget.dio.post('/user/competition-awards/${award.id}/$action');
      if (!mounted) return;
      await _load();
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          submit ? '材料已提交核验' : '已取消材料核验',
        );
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '核验状态更新失败')
              : '核验状态更新失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _changingVerification.remove(award.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('我的竞赛经历')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('competition-award-add'),
        onPressed: _openEditor,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加经历'),
      ),
      body: _body(isDark),
    );
  }

  Widget _body(bool isDark) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: _AwardEmptyState(
          icon: Icons.error_outline_rounded,
          title: _error!,
          actionLabel: '重新加载',
          onAction: _load,
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: _AwardEmptyState(
          icon: Icons.workspace_premium_outlined,
          title: '还没有竞赛经历',
          subtitle: '记录参赛、获奖和你在团队中的贡献',
          actionLabel: '添加经历',
          onAction: _openEditor,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
        itemCount: _items.length,
        itemBuilder: (context, index) => _awardCard(_items[index], isDark),
      ),
    );
  }

  Widget _awardCard(CompetitionAward award, bool isDark) {
    final status = competitionAwardStatusLabels[award.verificationStatus] ??
        competitionAwardStatusLabels['self_reported']!;
    final visibility = competitionAwardVisibilityLabels[award.visibility] ??
        competitionAwardVisibilityLabels['private']!;
    final role = competitionAwardRoleLabels[award.role] ?? award.role;
    final stage = competitionAwardStageLabels[award.competitionStage] ??
        award.competitionStage;
    final resultText = [award.awardLevel, award.awardName, stage]
        .where((value) => value.trim().isNotEmpty)
        .join(' · ');
    return Container(
      key: Key('competition-award-${award.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(15, 14, 8, 14),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${award.competitionYear} ${award.competitionTitle}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: CompetitionUiTokens.titleColor(isDark),
                  ),
                ),
                const SizedBox(height: 7),
                Text(resultText,
                    style: TextStyle(
                        color: CompetitionUiTokens.subColor(isDark),
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  children: [
                    Text('角色：$role'),
                    Text('状态：$status'),
                    Text('可见范围：$visibility'),
                  ]
                      .map((child) => DefaultTextStyle.merge(
                            style: TextStyle(
                                fontSize: 12,
                                color: CompetitionUiTokens.subColor(isDark)),
                            child: child,
                          ))
                      .toList(),
                ),
                const SizedBox(height: 10),
                _verificationContent(award, isDark),
              ],
            ),
          ),
          _deleting.contains(award.id)
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : PopupMenuButton<String>(
                  tooltip: '经历操作',
                  onSelected: (value) {
                    if (value == 'edit') _openEditor(award);
                    if (value == 'delete') _delete(award);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _verificationContent(CompetitionAward award, bool isDark) {
    final busy = _changingVerification.contains(award.id);
    switch (award.verificationStatus) {
      case 'pending':
        return _statusPanel(
          isDark,
          '核验期间核心信息暂不可修改。',
          OutlinedButton(
            key: Key('competition-award-cancel-${award.id}'),
            onPressed:
                busy ? null : () => _changeVerification(award, submit: false),
            child: Text(busy ? '处理中' : '取消核验'),
          ),
        );
      case 'verified':
        return _statusPanel(
          isDark,
          '平台仅核验提交材料与填写信息是否一致，不代表学校教务或官方认证。',
          null,
        );
      case 'rejected':
        return _statusPanel(
          isDark,
          award.verificationNote.trim().isEmpty
              ? '材料核验未通过，请修改后重新提交。'
              : '原因：${award.verificationNote}',
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _openEditor(award),
                child: const Text('修改材料'),
              ),
              FilledButton(
                key: Key('competition-award-resubmit-${award.id}'),
                onPressed: busy
                    ? null
                    : () => _changeVerification(award, submit: true),
                child: Text(busy ? '提交中' : '重新提交'),
              ),
            ],
          ),
        );
      default:
        return _statusPanel(
          isDark,
          '该经历尚未经过平台材料核验。',
          FilledButton(
            key: Key('competition-award-submit-${award.id}'),
            onPressed:
                busy ? null : () => _changeVerification(award, submit: true),
            child: Text(busy ? '提交中' : '提交材料核验'),
          ),
        );
    }
  }

  Widget _statusPanel(bool isDark, String message, Widget? action) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.accentSoft(isDark),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action,
          ],
        ],
      ),
    );
  }
}

class _AwardEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  const _AwardEmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: CompetitionUiTokens.subColor(isDark)),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: CompetitionUiTokens.subColor(isDark),
              ),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
