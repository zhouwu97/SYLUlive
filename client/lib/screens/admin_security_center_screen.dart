import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/security_event.dart';
import '../providers/auth_provider.dart';
import '../services/admin_security_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/security_event_presentation.dart';
import '../widgets/global_background_wrapper.dart';

/// 安全中心。
///
/// 页面把「审计流水」和「待处置事件」分开：默认视图（待处置）只显示真正需要
/// 管理员判断的事件，正常验证码、正常改密、单次密码输错只在「全部记录」里出现。
/// 每条事件的指标行也只显示与该事件类型相关的字段，不再机械地打印
/// 「实际发信 0 次 · 成功改密 0 次」这类与当前阶段无关的数字。
class AdminSecurityCenterScreen extends StatefulWidget {
  const AdminSecurityCenterScreen({super.key});

  @override
  State<AdminSecurityCenterScreen> createState() =>
      _AdminSecurityCenterScreenState();
}

/// 列表视图档位。actionable=true 是默认口径。
class _SecurityView {
  static const pending = 'pending';
  static const all = 'all';
  static const resolved = 'resolved';
  static const falsePositive = 'false_positive';
}

class _AdminSecurityCenterScreenState extends State<AdminSecurityCenterScreen> {
  SecurityOverview? _overview;
  List<SecurityEvent> _events = const [];
  String _view = _SecurityView.pending;
  String _severity = 'all';
  String? _error;
  bool _loading = true;
  bool _actionBusy = false;

  AdminSecurityService get _service =>
      AdminSecurityService(context.read<AuthProvider>().dio);

  /// 视图 -> 接口筛选参数。
  (String actionable, String status) get _filters => switch (_view) {
        _SecurityView.all => ('all', 'all'),
        _SecurityView.resolved => ('all', 'resolved'),
        _SecurityView.falsePositive => ('all', 'false_positive'),
        _ => ('true', 'active'),
      };

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
    final filters = _filters;
    try {
      final result = await Future.wait([
        _service.loadOverview(),
        _service.loadEvents(
          severity: _severity,
          status: filters.$2,
          actionable: filters.$1,
        ),
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

  Future<void> _changeView({String? view, String? severity}) async {
    setState(() {
      if (view != null) _view = view;
      if (severity != null) _severity = severity;
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
                Text(securityEventTitle(event),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                _detailLine('级别',
                    '${securitySeverityLabel(event.severity)}（${event.severity}）'),
                _detailLine('状态', securityEventStatusLabel(event)),
                _detailLine('处置', securityEventActionLabel(event)),
                _detailLine(
                    '目标',
                    event.targetMasked.isEmpty
                        ? '未标记目标'
                        : event.targetMasked),
                ...securityEventMetrics(event).map((line) => Text(line)),
                _detailLine('路由', '${event.method} ${event.route}'),
                _detailLine('来源指纹',
                    event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint),
                _detailLine('最后发生', _formatTime(event.lastSeenAt)),
                if (!event.actionable)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('审计流水：正常业务记录，无需处置',
                        style: TextStyle(color: AppColors.info)),
                  ),
                if (event.installationSeen)
                  const Text('安装标识：已记录（仅用于关联判断）'),
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

  Widget _detailLine(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text('$label：$value'),
      );

  /// 临时封禁来源。
  ///
  /// 默认作用域是**当前接口**，不再是空路由前缀。空前缀在服务端等价于对全部高风险
  /// 接口生效，校园网/宿舍/运营商共享出口一点就可能连坐一批正常同学；
  /// 全部高风险接口必须选中危险项并显式勾选确认。
  Future<void> _createBlock(SecurityEvent event) async {
    final routePrefix = event.route.startsWith('/api/') ? event.route : '';
    var duration = 60;
    var scope = routePrefix.isEmpty ? 'account' : 'route';
    var globalConfirmed = false;
    final reasonController =
        TextEditingController(text: securityEventTitle(event));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('临时封禁来源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('来源：${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: AppSpacing.sm),
                const Text('封禁范围', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    if (routePrefix.isNotEmpty)
                      ChoiceChip(
                        label: Text('仅当前接口 $routePrefix'),
                        selected: scope == 'route',
                        onSelected: (_) =>
                            setDialogState(() => scope = 'route'),
                      ),
                    ChoiceChip(
                      label: const Text('账号与验证码链路'),
                      selected: scope == 'account',
                      onSelected: (_) => setDialogState(() => scope = 'account'),
                    ),
                    ChoiceChip(
                      label: const Text('全部高风险接口'),
                      selected: scope == 'all',
                      onSelected: (_) => setDialogState(() => scope = 'all'),
                    ),
                  ],
                ),
                if (scope == 'account')
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      '覆盖 /api/login · /api/login_edu · /api/password · '
                      '/api/register · /api/forgot_password · /api/send_code · /api/verify_code',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (scope == 'all')
                  Container(
                    margin: const EdgeInsets.only(top: AppSpacing.sm),
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                          color: AppColors.danger.withValues(alpha: 0.45)),
                    ),
                    child: const Text(
                      '全部高风险接口会同时封禁登录、注册、改密、发帖、私信、检索等入口。'
                      '如果该来源是校园网、宿舍宽带或运营商共享出口，会连带封禁大量正常用户。',
                      style: TextStyle(color: AppColors.danger),
                    ),
                  ),
                if (scope == 'all')
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: globalConfirmed,
                    onChanged: (value) => setDialogState(
                        () => globalConfirmed = value ?? false),
                    title: const Text('我已确认该来源不是共享出口'),
                  ),
                const SizedBox(height: AppSpacing.sm),
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
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: scope == 'all' && !globalConfirmed
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(scope == 'all' ? '确认全站封禁' : '确认封禁'),
            ),
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
        scope: scope,
        routePrefix: scope == 'route' ? event.route : '',
        confirmGlobal: scope == 'all',
        reason: reason,
      );
      _showMessage('已创建临时封禁');
    } catch (error) {
      _showMessage(_blockErrorMessage(error));
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  String _blockErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) {
        return data['error'].toString();
      }
    }
    return '创建封禁失败';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface;
    return Scaffold(
      // 之前这里 Scaffold 与 AppBar 同时透明，而背景层只铺在 body 内，
      // 于是状态栏下方那一条直接露出黑底，标题在深色上几乎不可见。
      // 安全中心是后台密排页面，不需要透出壁纸：AppBar 用不透明的 surface 色，
      // Scaffold 底色跟随同一颜色，确保浅色/深色模式下标题与图标都清晰。
      backgroundColor: surface,
      appBar: AppBar(
        title: const Text('安全中心'),
        backgroundColor: surface,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: (isDark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          )
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: CustomBackgroundLayer()),
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
              children: [
                if (_overview != null) _buildOverview(_overview!, isDark),
                const SizedBox(height: AppSpacing.md),
                _buildFilters(),
                const SizedBox(height: AppSpacing.sm),
                if (_error != null)
                  _buildError()
                else if (_loading)
                  const Padding(
                      padding: EdgeInsets.all(AppSpacing.xxl),
                      child: Center(child: CircularProgressIndicator()))
                else if (_events.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xxl),
                    child: Center(child: Text(_emptyMessage())),
                  )
                else
                  ..._events.map(_buildEventCard),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _emptyMessage() => switch (_view) {
        _SecurityView.pending => '当前没有需要处置的安全事件',
        _SecurityView.resolved => '没有已处理的安全事件',
        _SecurityView.falsePositive => '没有标记为误报的安全事件',
        _ => '当前筛选范围没有安全事件',
      };

  Widget _buildOverview(SecurityOverview overview, bool isDark) {
    final cards = <(String, String, Color, String)>[
      // 这张卡片的真实含义是「未处理的高危/严重且需要处置的事件数」，
      // 早期标签写成「安全事件」会让人误以为那是事件总数。
      ('高危待处理', '${overview.pendingHighCount}', AppColors.danger,
          '高危/严重 · 未处理 · 需处置'),
      ('${overview.range} 拦截', '${overview.blockedRequests}', AppColors.warning,
          '本区间被限流或封禁挡下的次数'),
      ('涉及目标', '${overview.affectedUsers}', AppColors.info, '出现事件的账号或邮箱数'),
      ('涉及来源', '${overview.uniqueSources}', AppColors.brandPrimary, '出现事件的来源指纹数'),
      ('实际发信', '${overview.mailSentCount}', AppColors.success, 'SMTP 真正投递成功'),
      ('密码重置成功', '${overview.passwordResetSuccessCount}', AppColors.danger,
          '验证码校验通过并完成改密'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: cards
              .map((card) => Container(
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
                        Text(card.$1,
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpacing.xs),
                        Text(card.$2,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(color: card.$3)),
                        const SizedBox(height: AppSpacing.xs),
                        Text(card.$4,
                            style: const TextStyle(fontSize: 11)),
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
    final blockDisabled = value('security_block') == 'disabled';
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
          if (blockDisabled)
            Text(
              '来源封禁只是附加层：登录与验证码的账号/来源限流、冷却与额度仍然生效。'
              '启用前请先确认真实 IP 识别，以及封禁作用域默认为最小范围。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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

  Widget _buildFilters() {
    Widget chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label), selected: selected, onSelected: (_) => onTap());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            chip('待处置', _view == _SecurityView.pending,
                () => _changeView(view: _SecurityView.pending)),
            chip('全部记录', _view == _SecurityView.all,
                () => _changeView(view: _SecurityView.all)),
            chip('已处理', _view == _SecurityView.resolved,
                () => _changeView(view: _SecurityView.resolved)),
            chip('误报', _view == _SecurityView.falsePositive,
                () => _changeView(view: _SecurityView.falsePositive)),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            chip('全部级别', _severity == 'all',
                () => _changeView(severity: 'all')),
            chip('严重', _severity == 'critical',
                () => _changeView(severity: 'critical')),
            chip('高危', _severity == 'high', () => _changeView(severity: 'high')),
            chip('中危', _severity == 'medium',
                () => _changeView(severity: 'medium')),
            chip('提示', _severity == 'low', () => _changeView(severity: 'low')),
            chip('信息', _severity == 'info', () => _changeView(severity: 'info')),
          ],
        ),
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
                child: Text(securitySeverityLabel(event.severity),
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                  child: Text(securityEventTitle(event),
                      style: const TextStyle(fontWeight: FontWeight.w700))),
              Text(securityEventStatusLabel(event),
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text(
                '目标：${event.targetMasked.isEmpty ? '未标记目标' : event.targetMasked}'),
            ...securityEventMetrics(event).map((line) => Text(line)),
            Text(
                '来源：${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}'),
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

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
