import 'package:shenliyuan/widgets/app_bottom_sheet.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import '../widgets/app_choice_chip.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../widgets/app_page_background.dart';
import '../models/security_event.dart';
import '../providers/auth_provider.dart';
import '../services/admin_security_service.dart';
import '../services/publish_session_scope.dart';
import '../widgets/security_session_guard.dart';
import 'admin_security_blocks_screen.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/security_event_presentation.dart';
import '../widgets/app_card.dart';

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
  int _loadGeneration = 0;
  int _page = 1;
  int? _total;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _moreError;
  PublishSessionScope? _session;
  int? _observedEpoch;
  int? _observedUserId;
  String? _observedRole;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedEpoch == auth.accountSessionEpoch &&
        _observedUserId == auth.user?.id &&
        _observedRole == auth.user?.role) {
      return;
    }
    _observedEpoch = auth.accountSessionEpoch;
    _observedUserId = auth.user?.id;
    _observedRole = auth.user?.role;
    _session = auth.isLoggedIn && auth.user?.isAdmin == true
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch)
        : null;
    _loadGeneration++;
    _overview = null;
    _events = const [];
    _hasMore = false;
    _loadingMore = false;
    _actionBusy = false;
    _loading = _session != null;
    _error = _session == null ? '需要管理员权限，请重新登录或返回' : null;
    final session = _session;
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(session)) _load();
      });
    }
  }

  bool _owns(PublishSessionScope session, {bool superAdmin = false}) =>
      mounted &&
      SecuritySessionGuard.owns(context.read<AuthProvider>(), session,
          requireAdmin: true, requireSuperAdmin: superAdmin);

  Future<void> _load() async {
    final session = _session;
    if (session == null || !_owns(session)) return;
    final requestGeneration = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _overview = null;
      _hasMore = false;
      _loadingMore = false;
      _moreError = null;
    });
    final filters = _filters;
    try {
      final result = await Future.wait([
        _service.loadOverview(session: session),
        _service.loadEventPage(
          severity: _severity,
          status: filters.$2,
          actionable: filters.$1,
          session: session,
        ),
      ]);
      if (!_owns(session) || requestGeneration != _loadGeneration) return;
      setState(() {
        _overview = result[0] as SecurityOverview;
        final page = result[1] as SecurityEventPage;
        _events = page.items;
        _hasMore = page.hasMore;
        _page = page.page;
        _total = page.total;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!_owns(session) || requestGeneration != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.response?.data is Map
            ? (error.response!.data['error']?.toString() ?? '安全数据加载失败')
            : '安全数据加载失败，请稍后重试';
      });
    } catch (_) {
      if (!_owns(session) || requestGeneration != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = '安全数据加载失败，请稍后重试';
      });
    }
  }

  Future<void> _loadMore() async {
    final session = _session;
    if (session == null ||
        !_owns(session) ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    final generation = _loadGeneration;
    final filters = _filters;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final result = await _service.loadEventPage(
          severity: _severity,
          status: filters.$2,
          actionable: filters.$1,
          page: _page + 1,
          session: session);
      if (!_owns(session) || generation != _loadGeneration) return;
      setState(() {
        final ids = _events.map((event) => event.id).toSet();
        _events = [
          ..._events,
          ...result.items.where((event) => ids.add(event.id))
        ];
        _hasMore = result.hasMore;
        _page = result.page;
        _total = result.total;
      });
    } catch (_) {
      if (_owns(session) && generation == _loadGeneration) {
        setState(() => _moreError = '加载更多失败，请重试');
      }
    } finally {
      if (_owns(session) && generation == _loadGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _changeView({String? view, String? severity}) async {
    setState(() {
      if (view != null) _view = view;
      if (severity != null) _severity = severity;
    });
    await _load();
  }

  Future<void> _resolve(SecurityEvent event, bool falsePositive,
      PublishSessionScope session) async {
    if (_actionBusy || !_owns(session)) return;
    setState(() => _actionBusy = true);
    var enteredNote = '';
    try {
      final note = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SecuritySessionGuard(
            auth: context.read<AuthProvider>(),
            session: session,
            requireAdmin: true,
            child: AppAlertDialog(
              title: Text(falsePositive ? '标记为误报' : '标记已处理'),
              content: TextField(
                onChanged: (value) => enteredNote = value,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '处理备注（可选）'),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消')),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, enteredNote),
                  child: const Text('确认'),
                ),
              ],
            )),
      );
      if (note == null || !_owns(session)) return;
      if (falsePositive) {
        await _service.markFalsePositive(event.id,
            note: note, session: session);
      } else {
        await _service.resolve(event.id, note: note, session: session);
      }
      if (!_owns(session)) return;
      _showMessage(falsePositive ? '已标记为误报' : '安全事件已处理');
      await _load();
    } catch (error) {
      if (_owns(session)) {
        _showMessage(_actionErrorMessage(error, '更新安全事件失败'));
        if (error is DioException && error.response?.statusCode == 409) {
          await _load();
        }
      }
    } finally {
      if (_owns(session)) setState(() => _actionBusy = false);
    }
  }

  Future<void> _showEvent(SecurityEvent event) async {
    final session = _session;
    if (session == null || !_owns(session)) return;
    final isSuper = context.read<AuthProvider>().user?.isSuperAdmin == true;
    final blockEnabled =
        _protectionLayer(_overview?.protection ?? const {}, 'security_block')
            .status;
    final blockDisabled =
        blockEnabled == 'disabled' || blockEnabled == 'not_configured';
    await showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SecuritySessionGuard(
          auth: context.read<AuthProvider>(),
          session: session,
          requireAdmin: true,
          requireSuperAdmin: isSuper,
          dialog: false,
          child: SafeArea(
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
                        '${securityEventSeverityLabel(event)}（${securityEventDisplaySeverity(event)}）'),
                    _detailLine('状态', securityEventStatusLabel(event)),
                    _detailLine('处置', securityEventActionLabel(event)),
                    _detailLine('目标', securityEventTargetLabel(event)),
                    ...securityEventMetrics(event).map((line) => Text(line)),
                    ...securityEventContext(event).map((line) => Text(
                          line,
                          style: Theme.of(context).textTheme.bodySmall,
                        )),
                    _detailLine('路由', '${event.method} ${event.route}'),
                    _detailLine(
                        '来源指纹',
                        event.sourceFingerprint.isEmpty
                            ? '未知'
                            : event.sourceFingerprint),
                    SelectableText(
                        '预警 IP：${securityEventSourceIPLabel(event)}'),
                    _detailLine('大致归属地', securityEventSourceRegionLabel(event)),
                    const Text('归属地来自离线 IP 库，仅代表网络出口的大致位置。'),
                    if (securityEventHasSourceIP(event))
                      TextButton.icon(
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制 IP'),
                        onPressed: () async {
                          if (!_owns(session)) return;
                          try {
                            await Clipboard.setData(
                                ClipboardData(text: event.sourceIP));
                            if (_owns(session)) _showMessage('IP 已复制');
                          } catch (_) {
                            if (_owns(session)) {
                              _showMessage('复制失败，请长按 IP 手动复制');
                            }
                          }
                        },
                      ),
                    _detailLine('最后发生', _formatTime(event.lastSeenAt)),
                    if (event.resolvedAt != null)
                      _detailLine('处理时间', _formatTime(event.resolvedAt!)),
                    if (event.resolutionNote.isNotEmpty)
                      _detailLine('处理备注', event.resolutionNote),
                    if (!event.actionable)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xs),
                        child: Text('审计流水：正常业务记录，无需处置',
                            style: TextStyle(color: AppColors.info)),
                      ),
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
                                    _resolve(event, false, session);
                                  },
                            child: const Text('标记已处理'),
                          ),
                        if (event.status == 'active')
                          OutlinedButton(
                            onPressed: _actionBusy
                                ? null
                                : () {
                                    Navigator.pop(sheetContext);
                                    _resolve(event, true, session);
                                  },
                            child: const Text('误报'),
                          ),
                        if (isSuper &&
                            event.sourceKey.isNotEmpty &&
                            event.sourceAttributionValid)
                          OutlinedButton.icon(
                            onPressed: _actionBusy || blockDisabled
                                ? null
                                : () {
                                    Navigator.pop(sheetContext);
                                    _createBlock(event, session);
                                  },
                            icon: const Icon(Icons.block_outlined),
                            label: Text(blockDisabled ? '来源封禁未启用' : '临时封禁来源'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          )),
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
  Future<void> _createBlock(
      SecurityEvent event, PublishSessionScope session) async {
    if (_actionBusy || !_owns(session, superAdmin: true)) return;
    setState(() => _actionBusy = true);
    final routePrefix = event.route.startsWith('/api/') ? event.route : '';
    var duration = 60;
    var scope = routePrefix.isEmpty ? 'account' : 'route';
    var globalConfirmed = false;
    var reason = securityEventTitle(event);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => SecuritySessionGuard(
            auth: context.read<AuthProvider>(),
            session: session,
            requireSuperAdmin: true,
            child: StatefulBuilder(
              builder: (context, setDialogState) => AppAlertDialog(
                title: const Text('临时封禁来源'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '来源：${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: AppSpacing.sm),
                      Text('预警 IP：${securityEventSourceIPLabel(event)}',
                          style: Theme.of(context).textTheme.bodySmall),
                      Text('归属地：${securityEventSourceRegionLabel(event)}',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: AppSpacing.sm),
                      const Text('封禁范围',
                          style: TextStyle(fontWeight: FontWeight.w600)),
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
                            label: const Text('账号与凭据链路'),
                            selected: scope == 'account',
                            onSelected: (_) =>
                                setDialogState(() => scope = 'account'),
                          ),
                          ChoiceChip(
                            label: const Text('全部高风险接口'),
                            selected: scope == 'all',
                            onSelected: (_) =>
                                setDialogState(() => scope = 'all'),
                          ),
                        ],
                      ),
                      if (scope == 'account' || scope == 'all')
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            securityBlockScopeDescription(
                                _overview?.protection['security_block_scopes']
                                    as Map<String, dynamic>?,
                                scope),
                            style: const TextStyle(fontSize: 12),
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
                                color:
                                    AppColors.danger.withValues(alpha: 0.45)),
                          ),
                          child: const Text(
                            '全部高风险接口会同时封禁登录、注册、改密，以及发帖、私信、检索的写入请求。'
                            '普通浏览与检索读取不在来源封禁内，读滥用需要另外限制。'
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
                      TextFormField(
                        initialValue: reason,
                        onChanged: (value) => reason = value,
                        maxLength: 200,
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
            )),
      );
      if (confirmed != true || !_owns(session, superAdmin: true)) return;
      await _service.createBlock(
        sourceKey: event.sourceKey,
        durationMinutes: duration,
        scope: scope,
        routePrefix: scope == 'route' ? event.route : '',
        confirmGlobal: scope == 'all',
        reason: reason,
        session: session,
      );
      if (_owns(session, superAdmin: true)) _showMessage('已创建临时封禁');
    } catch (error) {
      if (_owns(session, superAdmin: true)) {
        _showMessage(_actionErrorMessage(error, '创建封禁失败'));
      }
    } finally {
      if (_owns(session)) setState(() => _actionBusy = false);
    }
  }

  String _actionErrorMessage(Object error, String fallback) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) {
        return data['error'].toString();
      }
    }
    return fallback;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface;
    return Scaffold(
      // 共用背景覆盖整个页面和顶栏；简洁模式仍使用表面色，
      // 避免只在 body 铺壁纸时顶部露出黑底。
      backgroundColor: AppPageBackground.color(context, surface),
      appBar: AppBar(
        title: const Text('安全中心'),
        backgroundColor: AppPageBackground.color(context, surface),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle:
            (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        actions: [
          if (context.read<AuthProvider>().user?.isSuperAdmin == true)
            IconButton(
              tooltip: '当前生效封禁',
              style: IconButton.styleFrom(
                  visualDensity: VisualDensity.standard,
                  minimumSize: const Size(44, 44)),
              icon: const Icon(Icons.gpp_maybe_outlined),
              onPressed: _actionBusy
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminSecurityBlocksScreen(),
                        ),
                      ),
            ),
          IconButton(
            style: IconButton.styleFrom(
                visualDensity: VisualDensity.standard,
                minimumSize: const Size(44, 44)),
            onPressed: _session == null ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          )
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              addRepaintBoundaries: false,
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
                if (!_loading && _error == null && _events.isNotEmpty)
                  Text(
                      _total == null
                          ? '已加载 ${_events.length} 条'
                          : '已加载 ${_events.length} 条，共 $_total 条',
                      textAlign: TextAlign.center),
                if (!_loading && _error == null && _hasMore) ...[
                  if (_moreError != null)
                    Text(_moreError!, textAlign: TextAlign.center),
                  Center(
                      child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.standard),
                    onPressed: _loadingMore ? null : _loadMore,
                    child: Text(_loadingMore
                        ? '加载中…'
                        : _moreError != null
                            ? '重试加载更多'
                            : '加载更多'),
                  )),
                ],
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
      (
        '高危待处理',
        '${overview.pendingHighCount}',
        AppColors.danger,
        '高危/严重 · 未处理 · 需处置'
      ),
      (
        '${overview.range} 拦截',
        '${overview.blockedRequests}',
        AppColors.warning,
        '本区间被限流或封禁挡下的次数'
      ),
      ('涉及目标', '${overview.affectedUsers}', AppColors.info, '出现事件的账号或邮箱数'),
      (
        '涉及来源',
        '${overview.uniqueSources}',
        AppColors.brandPrimary,
        '出现事件的来源指纹数'
      ),
      ('实际发信', '${overview.mailSentCount}', AppColors.success, 'SMTP 真正投递成功'),
      (
        '密码重置成功',
        '${overview.passwordResetSuccessCount}',
        AppColors.danger,
        '验证码校验通过并完成改密'
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: cards
              .map((card) => AppCardSurface(
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
                        Text(card.$4, style: const TextStyle(fontSize: 11)),
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
      ('客户端 IP 识别', _protectionLayer(protection, 'client_ip_identification')),
      ('来源封禁', _protectionLayer(protection, 'security_block')),
      (
        'SecurityBlock 表',
        _protectionLayer(protection, 'security_block_schema')
      ),
      ('安全事件采集', _protectionLayer(protection, 'security_event_collection')),
      ('验证码日限额', _protectionLayer(protection, 'verification_daily_limit')),
      // 主动告警：没配收件人时这里必须显式报「未配置」，不能继续和其它层一样报绿。
      ('高危告警邮件', _protectionLayer(protection, 'security_alerts')),
      (
        'IP 离线归属地',
        _ProtectionLayer(
            status: value('security_ip_location'),
            note: protection['security_ip_location_note']?.toString())
      ),
    ];
    final blockDisabled = value('security_block') == 'disabled';
    return AppCardSurface(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(row.$1)),
                        Flexible(
                          child: Text(_protectionLabel(row.$2.status),
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                  color: _protectionColor(row.$2.status),
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (row.$2.note != null)
                      Text(row.$2.note!,
                          style: Theme.of(context).textTheme.bodySmall),
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

  /// 读取一层防护的状态。
  ///
  /// 新后端会额外给出 `<key>_state`：其中分开「配置态 configured」和「运行态 runtime」，
  /// 并带上最近一次成功/失败时间与连续失败次数。旧后端只有扁平字符串，此时按原文展示，
  /// 不能因为拿不到明细就把状态猜成健康。
  _ProtectionLayer _protectionLayer(
      Map<String, dynamic> protection, String key) {
    final state = protection['${key}_state'];
    if (state is! Map) {
      return _ProtectionLayer(status: protection[key]?.toString() ?? 'unknown');
    }
    final decoded = Map<String, dynamic>.from(state);
    final detail = decoded['detail'] is Map
        ? Map<String, dynamic>.from(decoded['detail'] as Map)
        : const <String, dynamic>{};
    return _ProtectionLayer(
      status: decoded['runtime']?.toString() ?? 'unknown',
      note: _protectionNote(detail),
    );
  }

  /// 把运行态明细压成一行证据。管理员要看到的是「上次真的写成功是什么时候」，
  /// 而不是一个没有来源的绿色。
  String? _protectionNote(Map<String, dynamic> detail) {
    final failures = (detail['consecutive_failures'] as num?)?.toInt() ?? 0;
    final lastFailure =
        DateTime.tryParse(detail['last_failure_at']?.toString() ?? '');
    final lastSuccess =
        DateTime.tryParse(detail['last_success_at']?.toString() ?? '');
    final dailyLimit = (detail['target_daily_limit'] as num?)?.toInt();
    final parts = <String>[];
    // 额度这一行要给出真实阈值，否则「正常」仍然只是一个没有内容的绿色。
    if (dailyLimit != null) parts.add('每邮箱 $dailyLimit 次/天');
    if (failures > 0) parts.add('连续失败 $failures 次');
    if (lastFailure != null) parts.add('最近失败 ${_formatTime(lastFailure)}');
    if (lastSuccess != null) parts.add('最近成功 ${_formatTime(lastSuccess)}');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _protectionLabel(String status) => switch (status) {
        'ready' || 'enabled' || 'configured' || 'ok' || 'healthy' => '正常',
        'degraded' => '降级',
        'unavailable' || 'missing' => '不可用',
        'disabled' || 'not_configured' => '未启用',
        'unknown' => '未验证',
        _ => status,
      };

  Color _protectionColor(String status) => switch (status) {
        'ready' ||
        'enabled' ||
        'configured' ||
        'ok' ||
        'healthy' =>
          AppColors.success,
        'degraded' || 'disabled' => AppColors.warning,
        'unknown' || 'not_configured' => AppColors.info,
        _ => AppColors.danger,
      };

  Widget _buildFilters() {
    Widget chip(String label, bool selected, VoidCallback onTap) => AppChoiceChip(
        visualDensity: VisualDensity.standard,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap());
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
            chip(
                '全部级别', _severity == 'all', () => _changeView(severity: 'all')),
            chip('严重', _severity == 'critical',
                () => _changeView(severity: 'critical')),
            chip(
                '高危', _severity == 'high', () => _changeView(severity: 'high')),
            chip('中危', _severity == 'medium',
                () => _changeView(severity: 'medium')),
            chip('提示', _severity == 'low', () => _changeView(severity: 'low')),
            chip(
                '信息', _severity == 'info', () => _changeView(severity: 'info')),
          ],
        ),
      ],
    );
  }

  Widget _buildEventCard(SecurityEvent event) {
    final displaySeverity = securityEventDisplaySeverity(event);
    final color = _severityColor(displaySeverity);
    return InkWell(
      onTap: () => _showEvent(event),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: AppCardSurface(
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
                child: Text(securityEventSeverityLabel(event),
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
            Text('目标：${securityEventTargetLabel(event)}'),
            ...securityEventMetrics(event).map((line) => Text(line)),
            ...securityEventContext(event).map((line) => Text(
                  line,
                  style: Theme.of(context).textTheme.bodySmall,
                )),
            Text(
                '来源：${event.sourceFingerprint.isEmpty ? '未知' : event.sourceFingerprint}'),
            Text('预警 IP：${securityEventSourceIPLabel(event)}'),
            Text('归属地：${securityEventSourceRegionLabel(event)}'),
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
          if (_session != null)
            OutlinedButton(
                style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.standard),
                onPressed: _load,
                child: const Text('重试')),
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

/// 一层防护在管理后台的展示结果。
///
/// [status] 是后端的运行态词汇（ready / degraded / unavailable / unknown /
/// not_configured），[note] 是支撑该结论的最近证据。缺证据时页面显示「未验证」，
/// 不在没有依据的情况下给出绿色。
class _ProtectionLayer {
  const _ProtectionLayer({required this.status, this.note});

  final String status;
  final String? note;
}
