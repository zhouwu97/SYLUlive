import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/admin_security_service.dart';
import '../services/publish_session_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/security_session_guard.dart';

/// 安全中心操作记录：谁在什么时间结案、标误报、封禁或解除了哪条事件／来源。
/// 只读，管理员可见；完整管理日志仍只对超级管理员开放。
class AdminSecurityLogsScreen extends StatefulWidget {
  const AdminSecurityLogsScreen({super.key});

  @override
  State<AdminSecurityLogsScreen> createState() =>
      _AdminSecurityLogsScreenState();
}

class _AdminSecurityLogsScreenState extends State<AdminSecurityLogsScreen> {
  static const _pageSize = 30;
  List<SecurityLogEntry> _logs = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;
  PublishSessionScope? _session;
  int? _observedEpoch;
  int? _observedUserId;
  String? _observedRole;
  int _generation = 0;

  AdminSecurityService get _service =>
      AdminSecurityService(context.read<AuthProvider>().dio);

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
    _generation++;
    _logs = const [];
    _loading = _session != null;
    _loadingMore = false;
    _hasMore = false;
    _error = _session == null ? '需要管理员权限，请返回安全中心' : null;
    final session = _session;
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(session)) _load();
      });
    }
  }

  bool _owns(PublishSessionScope session) =>
      mounted &&
      SecuritySessionGuard.owns(context.read<AuthProvider>(), session,
          requireAdmin: true);

  Future<void> _load() async {
    final session = _session;
    if (session == null || !_owns(session)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final logs = await _service.loadLogs(session: session);
      if (!_owns(session) || generation != _generation) return;
      setState(() {
        _logs = logs;
        _page = 1;
        _hasMore = logs.length >= _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!_owns(session) || generation != _generation) return;
      setState(() {
        _error = '读取操作记录失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final session = _session;
    if (session == null || !_owns(session) || _loadingMore || !_hasMore) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final logs = await _service.loadLogs(page: _page + 1, session: session);
      if (!_owns(session) || generation != _generation) return;
      setState(() {
        final ids = _logs.map((log) => log.id).toSet();
        _logs = [..._logs, ...logs.where((log) => ids.add(log.id))];
        _page++;
        _hasMore = logs.length >= _pageSize;
      });
    } catch (_) {
      if (mounted && _owns(session) && generation == _generation) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('加载更多失败，请重试')));
      }
    } finally {
      if (_owns(session) && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  String _time(DateTime value) =>
      '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('操作记录')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(
                child: AppContentSurface.reading(
                    child: Column(children: [
                  Text(_error!),
                  if (_session != null)
                    TextButton(onPressed: _load, child: const Text('重试')),
                ])),
              )
            else if (_logs.isEmpty)
              const Center(
                  child: AppContentSurface.reading(child: Text('还没有安全处置记录')))
            else ...[
              for (final log in _logs)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: AppSpacing.sm,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(log.actionLabel,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                      color:
                                          log.action == 'security_block_created'
                                              ? AppColors.danger
                                              : null)),
                              Text(
                                  log.adminName.isEmpty
                                      ? '管理员 #${log.adminId}'
                                      : log.adminName,
                                  style: theme.textTheme.titleSmall),
                              if (log.targetLabel.isNotEmpty)
                                Text(log.targetLabel,
                                    style: theme.textTheme.bodySmall),
                            ],
                          ),
                          if (log.detail.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(log.detail),
                          ],
                          const SizedBox(height: AppSpacing.xs),
                          Text(_time(log.createdAt),
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_hasMore)
                Center(
                  child: TextButton(
                    onPressed: _loadingMore ? null : _loadMore,
                    child: Text(_loadingMore ? '正在加载…' : '加载更多'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
