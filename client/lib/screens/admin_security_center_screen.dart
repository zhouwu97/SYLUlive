import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/security_event.dart';
import '../providers/auth_provider.dart';
import '../services/admin_security_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../widgets/global_background_wrapper.dart';

class AdminSecurityCenterScreen extends StatefulWidget {
  const AdminSecurityCenterScreen({super.key});

  @override
  State<AdminSecurityCenterScreen> createState() =>
      _AdminSecurityCenterScreenState();
}

class _AdminSecurityCenterScreenState extends State<AdminSecurityCenterScreen> {
  SecurityOverview? _overview;
  List<SecurityEvent> _events = const [];
  String _severity = 'all';
  String _status = 'active';
  String? _error;
  bool _loading = true;
  bool _actionBusy = false;

  AdminSecurityService get _service =>
      AdminSecurityService(context.read<AuthProvider>().dio);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await Future.wait([
        _service.loadOverview(),
        _service.loadEvents(severity: _severity, status: _status),
      ]);
      if (!mounted) return;
      setState(() {
        _overview = result[0] as SecurityOverview;
        _events = result[1] as List<SecurityEvent>;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.response?.data is Map
            ? (error.response!.data['error']?.toString() ?? '安全数据加载失败')
            : '安全数据加载失败，请稍后重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '安全数据加载失败，请稍后重试';
      });
    }
  }

  Future<void> _changeFilter({String? severity, String? status}) async {
    setState(() {
      if (severity != null) _severity = severity;
      if (status != null) _status = status;
    });
    await _load();
  }

  Future<void> _resolve(SecurityEvent event, bool falsePositive) async {
    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(falsePositive ? '标记为误报' : '标记已处理'),
        content: TextField(
          controller: noteController,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '处理备注（可选）'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, noteController.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    noteController.dispose();
    if (note == null || !mounted) return;
    setState(() => _actionBusy = true);
    try {
      if (falsePositive) {
        await _service.markFalsePositive(event.id, note: note);
      } else {
        await _service.resolve(event.id, note: note);
      }
      await _load();
    } catch (_) {
      if (mounted) _showMessage('更新安全事件失败');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _showEvent(SecurityEvent event) async {
    final isSuper = context.read<AuthProvider>().user?.isSuperAdmin == true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_eventTitle(event),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                Text(
                    '目标：${event.targetMasked.isEmpty ? '未标记目标' : event.targetMasked}'),
                Text(
                    '来源指纹：${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}'),
                Text('路由：${event.method} ${event.route}'),
                Text('过去窗口：${event.attemptCount} 次，拦截 ${event.blockedCount} 次'),
                Text('最后发生：${_formatTime(event.lastSeenAt)}'),
                if (event.installationSeen) const Text('安装标识：已记录（仅用于关联判断）'),
                if (isSuper && event.sourceKey.isNotEmpty)
                  Text('超级管理员来源键：${event.sourceKey}',
                      style: const TextStyle(fontSize: 12)),
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    if (event.status == 'active')
                      FilledButton.tonal(
                        onPressed: _actionBusy
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _resolve(event, false);
                              },
                        child: const Text('标记已处理'),
                      ),
                    if (event.status == 'active')
                      OutlinedButton(
                        onPressed: _actionBusy
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _resolve(event, true);
                              },
                        child: const Text('误报'),
                      ),
                    if (isSuper && event.sourceKey.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: _actionBusy
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _createBlock(event);
                              },
                        icon: const Icon(Icons.block_outlined),
                        label: const Text('临时封禁来源'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createBlock(SecurityEvent event) async {
    var duration = 60;
    final reasonController = TextEditingController(text: _eventTitle(event));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('临时封禁来源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: duration,
                decoration: const InputDecoration(labelText: '封禁时长'),
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 分钟')),
                  DropdownMenuItem(value: 60, child: Text('1 小时')),
                  DropdownMenuItem(value: 1440, child: Text('24 小时')),
                ],
                onChanged: (value) =>
                    setDialogState(() => duration = value ?? 60),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: reasonController,
                maxLength: 500,
                decoration: const InputDecoration(labelText: '原因'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认封禁')),
          ],
        ),
      ),
    );
    final reason = reasonController.text;
    reasonController.dispose();
    if (confirmed != true || !mounted) return;
    setState(() => _actionBusy = true);
    try {
      await _service.createBlock(
          sourceKey: event.sourceKey,
          durationMinutes: duration,
          reason: reason);
      _showMessage('已创建临时封禁');
    } catch (_) {
      _showMessage('创建封禁失败');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('安全中心'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh))
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: CustomBackgroundLayer()),
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
              children: [
                if (_overview != null) _buildOverview(_overview!, isDark),
                const SizedBox(height: AppSpacing.md),
                _buildFilters(isDark),
                const SizedBox(height: AppSpacing.sm),
                if (_error != null)
                  _buildError()
                else if (_loading)
                  const Padding(
                      padding: EdgeInsets.all(AppSpacing.xxl),
                      child: Center(child: CircularProgressIndicator()))
                else if (_events.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(AppSpacing.xxl),
                      child: Center(child: Text('当前筛选范围没有安全事件')))
                else
                  ..._events.map(_buildEventCard),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverview(SecurityOverview overview, bool isDark) {
    final values = [
      ('安全事件', overview.activeHighCount, AppColors.danger),
      ('拦截请求', overview.blockedRequests, AppColors.warning),
      ('受影响目标', overview.affectedUsers, AppColors.info),
      ('来源指纹', overview.uniqueSources, AppColors.brandPrimary),
      ('实际发信', overview.mailSentCount, AppColors.success),
      ('成功改密', overview.passwordResetSuccessCount, AppColors.danger),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: values
              .map((value) => Container(
                    width: 156,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppColors.surfaceSecondaryDark
                          : Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(
                          color: isDark
                              ? AppColors.borderNormalDark
                              : AppColors.borderSubtleLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value.$1,
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpacing.xs),
                        Text('${value.$2}',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(color: value.$3)),
                      ],
                    ),
                  ))
              .toList(),
        ),
        const SizedBox(height: AppSpacing.md),
        _buildProtectionStatus(overview.protection, isDark),
      ],
    );
  }

  Widget _buildProtectionStatus(Map<String, dynamic> protection, bool isDark) {
    String value(String key, [String fallback = 'unknown']) =>
        protection[key]?.toString() ?? fallback;
    final rows = [
      ('客户端 IP 识别', value('client_ip_identification')),
      ('来源封禁', value('security_block')),
      ('SecurityBlock 表', value('security_block_schema')),
      ('安全事件采集', value('security_event_collection')),
      ('验证码日限额', value('verification_daily_limit')),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
            color: isDark
                ? AppColors.borderNormalDark
                : AppColors.borderSubtleLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('防护状态', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.sm),
          ...rows.map((row) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(child: Text(row.$1)),
                    Text(row.$2,
                        style: TextStyle(
                            color: _protectionColor(row.$2),
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              )),
          if (value('source_attribution_valid_from', '').isNotEmpty)
            Text('归因可信起点：${value('source_attribution_valid_from')}',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Color _protectionColor(String status) => switch (status) {
        'ready' || 'enabled' || 'configured' || 'ok' => AppColors.success,
        'disabled' => AppColors.warning,
        _ => AppColors.danger,
      };

  Widget _buildFilters(bool isDark) {
    Widget chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label), selected: selected, onSelected: (_) => onTap());
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        chip('全部级别', _severity == 'all', () => _changeFilter(severity: 'all')),
        chip('高危', _severity == 'high', () => _changeFilter(severity: 'high')),
        chip('严重', _severity == 'critical',
            () => _changeFilter(severity: 'critical')),
        chip('处理中', _status == 'active', () => _changeFilter(status: 'active')),
        chip('已处理', _status == 'resolved',
            () => _changeFilter(status: 'resolved')),
        chip('误报', _status == 'false_positive',
            () => _changeFilter(status: 'false_positive')),
      ],
    );
  }

  Widget _buildEventCard(SecurityEvent event) {
    final color = _severityColor(event.severity);
    return InkWell(
      onTap: () => _showEvent(event),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.sm)),
                child: Text(_severityLabel(event.severity),
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                  child: Text(_eventTitle(event),
                      style: const TextStyle(fontWeight: FontWeight.w700))),
              Text(event.status == 'active' ? '处理中' : '已归档',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text(
                '目标：${event.targetMasked.isEmpty ? '未标记目标' : event.targetMasked}'),
            Text(
                '请求 ${event.attemptCount} 次 · 拦截 ${event.blockedCount} 次 · 来源 ${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}'),
            Text(
                '实际发信 ${event.mailSentCount} 次 · 成功改密 ${event.passwordResetSuccessCount} 次'),
            if (!event.sourceAttributionValid)
              const Text('历史来源归因不可用',
                  style: TextStyle(color: AppColors.warning)),
            const SizedBox(height: AppSpacing.xs),
            Text(_formatTime(event.lastSeenAt),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildError() => Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );

  Color _severityColor(String value) => switch (value) {
        'critical' => AppColors.danger,
        'high' => Colors.deepOrange,
        'medium' => AppColors.warning,
        'low' => AppColors.info,
        _ => AppColors.iconNeutralLight,
      };

  String _severityLabel(String value) => switch (value) {
        'critical' => '严重',
        'high' => '高危',
        'medium' => '中危',
        'low' => '低危',
        _ => '提示',
      };

  String _eventTitle(SecurityEvent event) => switch (event.eventType) {
        'password_reset_spray' => '密码重置喷洒',
        'verification_spray' => '验证码喷洒',
        'verification_source_rate' => '验证码来源限流',
        'verification_cooldown' => '验证码冷却拦截',
        'email_target_flood' => '验证码目标轰炸',
        'verification_code_bruteforce' => '验证码暴力尝试',
        'login_password_spray' => 'Password Spray',
        'login_bruteforce' => '登录暴力尝试',
        'refresh_token_reused' => 'Refresh Token Reuse',
        'suspicious_password_reset_succeeded' => '可疑密码重置成功',
        'password_reset_activity' => '密码重置请求',
        'verification_activity' => '验证码请求',
        'content_post_flood' => '发帖刷屏',
        'content_reply_flood' => '评论刷屏',
        'private_message_flood' => '私信刷屏',
        'feedback_ticket_flood' => '反馈工单刷量',
        'security_blocked_request' => '来源封禁拦截',
        'search_abuse' => '搜索扫描',
        _ => event.eventType,
      };

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
