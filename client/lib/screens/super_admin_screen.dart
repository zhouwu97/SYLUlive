import 'package:shenliyuan/widgets/app_popup_menu.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shenliyuan/widgets/app_tab_bar_surface.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../widgets/app_page_background.dart';
import '../config/api_constants.dart';
import '../models/admin_user_summary.dart';
import '../providers/auth_provider.dart';
import 'admin/app_release_admin_tab.dart';
import 'admin/managed_ai_admin_tab.dart';
import '../widgets/app_card.dart';
import '../widgets/state_placeholder.dart';
import '../utils/app_feedback.dart';
import '../models/lottery.dart';
import '../theme/app_theme_style.dart';
import '../theme/app_theme_tokens.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/lottery/lottery_widgets.dart';
import 'lottery_publish_screen.dart';
import 'lottery_screen.dart';

class SuperAdminScreen extends StatefulWidget {
  const SuperAdminScreen({super.key});
  @override
  State<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends State<SuperAdminScreen>
    with SingleTickerProviderStateMixin {
  late Dio _dio;
  late TabController _tabController;
  List<AdminUserSummary> _users = [];
  List<dynamic> _pendingInvitations = [];
  List<dynamic> _adminLogs = [];
  String _searchQuery = '';
  Timer? _searchDebounce;
  late Future<Response<dynamic>> _lotteryFuture;
  List<Map<String, dynamic>> _lotteryEvents = [];
  int? _selectedLotteryEventId;
  bool _lotteryActionBusy = false;
  bool _lotteryDescExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _dio = context.read<AuthProvider>().dio;
    _lotteryFuture = _loadLotteryParticipants();
    _loadAll();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadUsers(), _loadInvitations(), _loadAdminLogs()]);
    if (mounted) setState(() {});
  }

  Future<void> _loadAdminLogs() async {
    try {
      final res = await _dio.get('/super/admin_logs');
      _adminLogs = res.data as List;
    } catch (_) {}
  }

  int _userSearchGeneration = 0;

  Future<void> _loadUsers() async {
    final generation = ++_userSearchGeneration;
    final search = _searchQuery.trim();

    try {
      final res = await _dio.get(
        '/super/users',
        queryParameters: {if (search.isNotEmpty) 'search': search},
      );

      final users = ((res.data as List?) ?? const [])
          .whereType<Map>()
          .map(
            (value) => AdminUserSummary.fromJson(
              Map<String, dynamic>.from(value),
            ),
          )
          .toList();

      if (!mounted || generation != _userSearchGeneration) return;

      setState(() => _users = users);
    } catch (_) {}
  }

  Future<void> _loadInvitations() async {
    try {
      final res = await _dio.get('/super/invitations/pending');
      _pendingInvitations = res.data as List;
    } catch (_) {}
  }

  Future<Response<dynamic>> _loadLotteryParticipants({int? eventId}) {
    final query = eventId != null ? <String, dynamic>{'event_id': eventId} : null;
    final request = _dio.get(
      '/super/lottery/participants',
      queryParameters: query,
    );
    // 标签页延迟构建：先订阅预取的失败，原 Future 仍交给 FutureBuilder 展示错误。
    request.then((_) => _loadLotteryEvents()).catchError((_) {});
    return request;
  }

  Future<void> _loadLotteryEvents() async {
    try {
      final res = await _dio.get(
        '/super/lottery/events',
        queryParameters: const {'page': 1, 'page_size': 30},
      );
      if (!mounted) return;
      final data = res.data;
      final raw = data is Map ? data['items'] : null;
      if (raw is List) {
        setState(() {
          _lotteryEvents = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        });
      }
    } catch (_) {}
  }

  void _refreshLotteryTab({int? eventId}) {
    if (mounted) {
      setState(() {
        if (eventId != null) {
          _selectedLotteryEventId = eventId;
        }
        _lotteryFuture = _loadLotteryParticipants(
          eventId: _selectedLotteryEventId,
        );
      });
    }
  }

  Future<void> _approveInvitation(dynamic inv, bool approve) async {
    final ctrl = TextEditingController();
    final reason = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(approve ? '同意理由' : '驳回理由'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: approve ? '填写同意该用户成为管理员的理由' : '填写驳回原因',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = ctrl.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(ctx, value);
            },
            child: Text(approve ? '同意' : '驳回'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null) return;

    try {
      await _dio.post(
        '/super/invitations/${inv['id']}/approve',
        data: {'reject': !approve, 'reason': reason},
      );
      if (mounted) {
        // 本地移除该待办
        if (mounted) {
          setState(
            () => _pendingInvitations.removeWhere((i) => i['id'] == inv['id']),
          );
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? '已提交同意审批' : '已驳回'),
            backgroundColor: approve ? Colors.green : Colors.red,
          ),
        );
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      final message = data is Map
          ? ((data['message'] ?? data['error'])?.toString() ?? '操作失败')
          : '操作失败';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('超级管理员面板'),
        leading: const BackButton(),
        actions: const [],
        bottom: AppTabBarSurface(
            child: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '用户管理'),
            Tab(text: '管理员审批'),
            Tab(text: '管理日志'),
            Tab(text: '抽奖管理'),
            Tab(text: '应用版本'),
            Tab(text: '所属 AI'),
          ],
        )),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildUsersTab(),
          _buildApprovalsTab(),
          _buildAdminLogsTab(),
          _buildLotteryTab(),
          AppReleaseAdminTab(dio: _dio),
          ManagedAIAdminTab(
            key: ValueKey(context.watch<AuthProvider>().user?.id),
            dio: _dio,
          ),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索用户 ID、学号/账号或昵称',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              _searchQuery = v;
              if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
              _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                _loadUsers();
              });
            },
          ),
        ),
        Expanded(
          child: _users.isEmpty
              ? const Center(child: AppContentSurface.reading(child: Text('暂无用户')))
              : ListView.builder(
                  itemCount: _users.length,
                  itemBuilder: (_, i) => _buildUserItem(_users[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildUserItem(AdminUserSummary user) {
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          child:
              Text(user.nickname.isEmpty ? '?' : user.nickname.substring(0, 1)),
        ),
        title: Text(user.nickname.isEmpty ? '未知' : user.nickname),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user.publicIdLabel),
            Text(user.accountLabel),
            Text(user.academicStatusLabel),
            Text('角色: ${user.role} | 诚信: ${user.creditScore}%'),
          ],
        ),
        isThreeLine: true,
        trailing: AppPopupMenuButton<String>(
          onSelected: (v) => _handleUserAction(user, v),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'role', child: Text('修改角色')),
            const PopupMenuItem(value: 'reset', child: Text('重置密码')),
            if (!user.isSuperAdmin)
              const PopupMenuItem(value: 'delete', child: Text('删除用户')),
          ],
        ),
      ),
    );
  }

  void _handleUserAction(AdminUserSummary user, String action) {
    if (action == 'role') {
      _showChangeRoleDialog(user);
    } else if (action == 'reset') {
      _resetPassword(user.id);
    } else if (action == 'delete') {
      _deleteUser(user.id);
    }
  }

  Widget _buildApprovalsTab() {
    if (_pendingInvitations.isEmpty) {
      return const Center(child: AppContentSurface.reading(child: Text('暂无待审批的申请')));
    }
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _pendingInvitations.length,
        itemBuilder: (_, i) {
          final inv = _pendingInvitations[i];
          final user = inv['user'] ?? {};
          final inviter = inv['inviter'] ?? {};
          return AppCard(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        child: Text(
                          (user['nickname'] ?? '?').toString().substring(0, 1),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user['nickname'] ?? '未知',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '用户 ID：${user['id']}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              '学号/账号：${user['student_id']} | 诚信：${user['credit_score']}%',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              '邀请人：${inviter['nickname'] ?? '未知'}（ID：${inviter['id'] ?? '-'}）',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () => _approveInvitation(inv, false),
                        icon: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.red,
                        ),
                        label: const Text(
                          '驳回',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _approveInvitation(inv, true),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('同意'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- 以下为原有用户管理逻辑 ---
  void _showChangeRoleDialog(AdminUserSummary user) {
    showAppDialog(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: const Text('修改角色'),
        content: Text('用户: ${user.nickname}'),
        actions: [
          if (!user.isSuperAdmin)
            TextButton(
              onPressed: () {
                _changeRole(user.id, 'user');
                Navigator.pop(ctx);
              },
              child: const Text('普通用户'),
            ),
          TextButton(
            onPressed: () {
              _changeRole(user.id, 'admin');
              Navigator.pop(ctx);
            },
            child: const Text('管理员'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeRole(int uid, String role) async {
    try {
      await _dio.put('/super/users/$uid/role', data: {'role': role});
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('角色修改成功')));
        _loadUsers();
      }
    } catch (_) {}
  }

  Future<void> _resetPassword(int uid) async {
    try {
      await _dio.post('/super/users/$uid/reset_password');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('密码已重置')));
      }
    } catch (_) {}
  }

  Future<void> _deleteUser(int uid) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: const Text('确认删除'),
        content: const Text('不可撤销'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _dio.delete('/super/users/$uid');
        _loadUsers();
      } catch (_) {}
    }
  }

  // ====== 管理员日志 Tab ======

  Widget _buildAdminLogsTab() {
    if (_adminLogs.isEmpty) {
      return const Center(child: AppContentSurface.reading(child: Text('暂无明显管理员操作日志')));
    }
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _adminLogs.length,
        itemBuilder: (_, i) {
          final log = _adminLogs[i];
          return _buildLogItem(log);
        },
      ),
    );
  }

  Widget _buildLogItem(dynamic log) {
    final adminName = log['admin_name'] ?? '未知';
    final action = log['action'] ?? '';
    final target = log['target'] ?? '';
    final adminExp = log['admin_exp'] ?? 0;
    final adminRole = log['admin_role'] ?? '';
    final createdAt = log['created_at'] ?? '';
    final adminId = log['admin_id'];

    return AppCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$adminName ($adminRole)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '管理经验: $adminExp',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('$action — $target', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              _formatLogTime(createdAt),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (adminRole != 'super_admin' && adminExp > 0)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () =>
                      _showRevokeExpDialog(adminId, adminName, adminExp),
                  icon: const Icon(Icons.undo, size: 16, color: Colors.red),
                  label: const Text(
                    '追回经验',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showRevokeExpDialog(dynamic adminId, String adminName, int currentExp) {
    final amountCtrl = TextEditingController(text: '1');
    final reasonCtrl = TextEditingController();

    showAppDialog(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text('追回 $adminName 的管理经验'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前经验: $currentExp'),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '追回数量',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: '追回原因（可选）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(ctx);
              final amount = int.tryParse(amountCtrl.text) ?? 0;
              if (amount <= 0) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('请输入有效的追回数量')),
                );
                return;
              }
              try {
                await _dio.post(
                  '/super/admin_logs/revoke_exp',
                  data: {
                    'admin_id': adminId,
                    'amount': amount,
                    'reason': reasonCtrl.text.trim(),
                  },
                );
                if (!mounted) return;
                messenger.showSnackBar(const SnackBar(content: Text('经验已追回')));
                _loadAdminLogs();
                if (navigator.mounted) navigator.pop();
              } on DioException catch (e) {
                final data = e.response?.data;
                final msg = data is Map
                    ? ((data['message'] ?? data['error']) ?? '操作失败')
                    : '操作失败';
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(msg.toString())),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认追回'),
          ),
        ],
      ),
    ).then((_) {
      amountCtrl.dispose();
      reasonCtrl.dispose();
    });
  }

  String _formatLogTime(String iso) {
    if (iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _lotteryStatusLabel(dynamic status) =>
      LotteryEvent.fromJson(<String, dynamic>{'status': status}).statusLabel;

  String _lotteryRemainingLabel(DateTime drawTime) {
    final diff = drawTime.difference(DateTime.now());
    if (diff <= Duration.zero) return '已到开奖时间';
    if (diff.inDays > 0) return '${diff.inDays} 天 ${diff.inHours % 24} 时';
    if (diff.inHours > 0) return '${diff.inHours} 时 ${diff.inMinutes % 60} 分';
    return '${diff.inMinutes % 60} 分钟';
  }

  Widget _buildLotteryTab() {
    return FutureBuilder(
      future: _lotteryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          if (snapshot.error.toString().contains('404')) {
            return _buildLotteryEmptyState('暂无抽奖活动');
          }
          final error = snapshot.error;
          return StatePlaceholder(
            icon: Icons.cloud_off_outlined,
            title: error is DioException
                ? AppFeedback.dioErrorMessage(error, fallback: '抽奖参与者加载失败')
                : '抽奖参与者加载失败',
            actionLabel: '重新加载',
            onAction: _refreshLotteryTab,
          );
        }
        if (snapshot.data?.statusCode == 404) {
          return _buildLotteryEmptyState('暂无抽奖活动');
        }

        final data = snapshot.data?.data;
        if (data == null || data is! Map) return _buildLotteryEmptyState('暂无数据');

        final rawEvent = data['event'];
        if (rawEvent is! Map) return _buildLotteryEmptyState('暂无抽奖活动');
        final eventMap = Map<String, dynamic>.from(rawEvent);
        final event = LotteryEvent.fromJson(eventMap);
        final hasOngoingElsewhere = _lotteryEvents.any((e) =>
            (e['status'] as num?)?.toInt() == LotteryEvent.statusOngoing);
        final participants = ((data['participants'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        // 中奖者置顶，其余保持接口顺序（报名时间倒序）。
        final winnerId = event.winnerId;
        if (winnerId != null) {
          participants.sort((a, b) {
            int rank(Map<String, dynamic> p) =>
                (p['user_id'] as num?)?.toInt() == winnerId ? 0 : 1;
            return rank(a).compareTo(rank(b));
          });
        }
        final totalParticipants =
            (data['total'] as num?)?.toInt() ?? participants.length;
        final ongoingTitle = event.isOngoing
            ? event.title
            : _lotteryEvents
                .where((e) =>
                    (e['status'] as num?)?.toInt() ==
                    LotteryEvent.statusOngoing)
                .map((e) => '${e['title'] ?? ''}')
                .firstOrNull;

        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
              children: [
                if (_lotteryEvents.isNotEmpty) ...[
                  _buildLotteryPeriodChips(event.id),
                  const SizedBox(height: 12),
                ],
                _buildLotteryEventCard(event, eventMap, totalParticipants),
                const SizedBox(height: 20),
                _buildLotteryParticipants(
                    event, participants, totalParticipants),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                heroTag: 'lottery-publish',
                backgroundColor: AppThemeTokens.of(context).primary,
                foregroundColor: AppThemeTokens.of(context).onPrimary,
                onPressed: _lotteryActionBusy
                    ? null
                    : () => _openLotteryPublish(
                          ongoingTitle: event.isOngoing || hasOngoingElsewhere
                              ? ongoingTitle
                              : null,
                        ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('发布抽奖'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLotteryPeriodChips(int currentId) {
    final tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _lotteryEvents.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = _lotteryEvents[index];
          final id = (item['id'] as num?)?.toInt() ?? 0;
          final selected = id == currentId;
          return ChoiceChip(
            label: Text(
                '#$id ${item['title'] ?? ''} · ${_lotteryStatusLabel(item['status'])}'),
            selected: selected,
            showCheckmark: false,
            // 选中项保持可用样式，点击当前期次不重复请求。
            onSelected: _lotteryActionBusy
                ? null
                : (_) {
                    if (!selected) _refreshLotteryTab(eventId: id);
                  },
            selectedColor: tokens.primary,
            backgroundColor: tokens.card,
            side: BorderSide(
                color: selected ? tokens.primary : tokens.cardBorder),
            labelStyle: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? tokens.onPrimary : tokens.textSecondary,
            ),
            shape: const StadiumBorder(),
          );
        },
      ),
    );
  }

  Widget _buildLotteryEventCard(
      LotteryEvent event, Map<String, dynamic> eventMap, int totalParticipants) {
    final tokens = AppThemeTokens.of(context);
    final due = event.isOngoing && !event.drawTime.isAfter(DateTime.now());
    final (dangerFg, _) = lotteryToneColors(context, LotteryTone.danger);
    final winner = event.winner;

    Widget meta(String label, Widget value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: tokens.textSecondary)),
              const SizedBox(height: 4),
              value,
            ],
          ),
        );
    Text metaText(String text) => Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: tokens.textPrimary));

    final Widget fourth;
    if (event.isOngoing) {
      fourth = meta('距开奖', metaText(_lotteryRemainingLabel(event.drawTime)));
    } else if (winner != null) {
      fourth = meta(
        '中奖者',
        Row(
          children: [
            CachedAvatar(
              radius: 10,
              imageUrl: winner.avatar.isNotEmpty
                  ? ApiConstants.fullUrl(winner.avatar)
                  : null,
              fallbackText: winner.nickname,
            ),
            const SizedBox(width: 6),
            Flexible(child: metaText(winner.nickname)),
          ],
        ),
      );
    } else {
      fourth = meta('结果', metaText(event.isDrawn ? '中奖用户已注销' : event.statusLabel));
    }

    return LotteryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                height: 72,
                child: LotteryPrizeArt(
                    imagePath: event.prizeImage, radius: 12, iconSize: 44),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        LotteryStatusChip(
                          label: event.statusLabel,
                          tone: lotteryStatusTone(event.status),
                        ),
                        const Spacer(),
                        Text('#${event.id}',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: tokens.textTertiary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: tokens.textPrimary)),
                    const SizedBox(height: 2),
                    Text(event.prizeName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: tokens.primary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: tokens.divider),
          const SizedBox(height: 14),
          Row(children: [
            meta('开奖时间', metaText(formatLotteryBeijing(event.drawTime))),
            meta('参与人数', metaText('$totalParticipants 人')),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            meta(
                '开奖方式',
                metaText(event.isOngoing
                    ? '到点自动'
                    : event.drawMode == LotteryDrawMode.manual
                        ? '手动补开'
                        : '自动开奖')),
            fourth,
          ]),
          if (event.description.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Material(
              color: tokens.surfaceMuted,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(
                    () => _lotteryDescExpanded = !_lotteryDescExpanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _lotteryDescExpanded
                              ? '说明：${event.description.trim()}'
                              : '说明：${event.description.trim().replaceAll(RegExp(r'\s+'), ' ')}',
                          maxLines: _lotteryDescExpanded ? null : 1,
                          overflow: _lotteryDescExpanded
                              ? null
                              : TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: tokens.textSecondary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_lotteryDescExpanded ? '收起' : '展开',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: tokens.primary)),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (event.isOngoing) ...[
                      OutlinedButton.icon(
                        onPressed: _lotteryActionBusy
                            ? null
                            : () => _openLotteryPublish(editingEvent: eventMap),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('编辑'),
                        style: _lotteryPillButtonStyle(),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const LotteryScreen())),
                        icon: const Icon(Icons.visibility_outlined, size: 16),
                        label: const Text('用户端预览'),
                        style: _lotteryPillButtonStyle(),
                      ),
                    ] else
                      Text('已结束活动不可编辑',
                          style: TextStyle(
                              fontSize: 12, color: tokens.textTertiary)),
                    if (due)
                      FilledButton.tonalIcon(
                        onPressed: _lotteryActionBusy
                            ? null
                            : () => _manualDrawLotteryEvent(event.id),
                        icon: const Icon(Icons.flash_on, size: 16),
                        label: const Text('兜底手动补开'),
                        style: _lotteryPillButtonStyle(),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _lotteryActionBusy
                    ? null
                    : () => _deleteLotteryEvent(event.id),
                icon: Icon(Icons.delete_outline, size: 17, color: dangerFg),
                label: Text('删除活动', style: TextStyle(color: dangerFg)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _lotteryPillButtonStyle() => const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        shape: WidgetStatePropertyAll(StadiumBorder()),
      );

  Widget _buildLotteryParticipants(LotteryEvent event,
      List<Map<String, dynamic>> participants, int totalParticipants) {
    final tokens = AppThemeTokens.of(context);
    int weightOf(Map<String, dynamic> p) =>
        ((p['current_weight'] ?? p['weight'] ?? 1) as num).toInt();
    final maxWeight = participants.fold<int>(
        1, (m, p) => weightOf(p) > m ? weightOf(p) : m);
    final (dangerFg, _) = lotteryToneColors(context, LotteryTone.danger);
    final (warnFg, warnBg) = lotteryToneColors(context, LotteryTone.warning);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const LotterySectionTitle('参与者'),
              const SizedBox(width: 8),
              Text('$totalParticipants 人',
                  style: TextStyle(fontSize: 12.5, color: tokens.textSecondary)),
              const Spacer(),
              Text(event.isOngoing ? '实时权重' : '开奖时权重',
                  style: TextStyle(fontSize: 12.5, color: tokens.textTertiary)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        LotteryCard(
          padding: EdgeInsets.zero,
          child: participants.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('暂无参与者',
                        style: TextStyle(color: tokens.textSecondary)),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < participants.length; i++) ...[
                      if (i > 0)
                        Divider(
                            height: 1, indent: 68, color: tokens.divider),
                      Builder(builder: (context) {
                        final p = participants[i];
                        final user = p['user'] is Map
                            ? Map<String, dynamic>.from(p['user'] as Map)
                            : const <String, dynamic>{};
                        final userId = p['user_id'] ?? user['id'];
                        final nickname = '${user['nickname'] ?? '未知用户'}';
                        final avatar = '${user['avatar'] ?? ''}';
                        final weight = weightOf(p);
                        final isWinner = event.winnerId != null &&
                            (userId as num?)?.toInt() == event.winnerId;
                        return Container(
                          color: isWinner ? warnBg : null,
                          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                          child: Row(
                            children: [
                              CachedAvatar(
                                radius: 19,
                                imageUrl: avatar.isNotEmpty
                                    ? ApiConstants.fullUrl(avatar)
                                    : null,
                                fallbackText: nickname,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(nickname,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600,
                                                  color: tokens.textPrimary)),
                                        ),
                                        if (isWinner) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 7, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: tokens.card,
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                            ),
                                            child: Text('中奖',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: warnFg)),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'ID $userId${user['level'] != null ? ' · Lv.${user['level']}' : ''}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.textTertiary),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 56,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: weight / maxWeight,
                                    minHeight: 6,
                                    color: tokens.primary,
                                    backgroundColor: tokens.surfaceMuted,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text('×$weight',
                                    textAlign: TextAlign.end,
                                    semanticsLabel: '权重 $weight',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: tokens.textPrimary)),
                              ),
                              if (event.isOngoing)
                                IconButton(
                                  icon: Icon(Icons.remove_circle_outline,
                                      color: dangerFg),
                                  tooltip: '踢出（可重新参与）',
                                  onPressed: _lotteryActionBusy
                                      ? null
                                      : () => _kickLotteryParticipant(
                                            eventId:
                                                p['lottery_id'] ?? event.id,
                                            userId: userId,
                                            userLabel: nickname,
                                          ),
                                )
                              else
                                const SizedBox(width: 10),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildLotteryEmptyState(String message) {
    final tokens = AppThemeTokens.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemeStateArt(
            fallback: Icon(Icons.card_giftcard_rounded,
                size: 64, color: tokens.textTertiary),
          ),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: tokens.textSecondary)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
                _lotteryActionBusy ? null : () => _openLotteryPublish(),
            icon: const Icon(Icons.add),
            label: const Text('发布抽奖'),
          ),
        ],
      ),
    );
  }

  Future<void> _openLotteryPublish({
    Map<String, dynamic>? editingEvent,
    String? ongoingTitle,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LotteryPublishScreen(
          editingEvent: editingEvent,
          ongoingTitle: ongoingTitle,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final isEdit = editingEvent != null;
    if (!isEdit) _selectedLotteryEventId = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isEdit ? '抽奖活动已更新' : '抽奖已发布')),
    );
    _refreshLotteryTab();
  }

  Future<void> _manualDrawLotteryEvent(int eventId) async {
    if (_lotteryActionBusy) return;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: const Text('兜底手动补开'),
        content: const Text('该活动已过开奖时间且尚未开奖，确定手动补开吗？此操作不可逆。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认补开'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    setState(() => _lotteryActionBusy = true);
    try {
      await _dio.post('/admin/lottery/$eventId/draw');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('开奖成功')));
      _refreshLotteryTab(eventId: eventId);
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppFeedback.dioErrorMessage(e, fallback: '补开失败')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _lotteryActionBusy = false);
    }
  }

  Future<void> _deleteLotteryEvent(dynamic eventId) async {
    if (_lotteryActionBusy) return;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: const Text('删除抽奖'),
        content: const Text('确定删除该抽奖吗？参与记录也会一起删除，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;

    setState(() => _lotteryActionBusy = true);
    try {
      await _dio.delete('/super/lottery/$eventId');
      if (!mounted) return;
      _selectedLotteryEventId = null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('抽奖已删除')));
      _refreshLotteryTab();
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = data is Map
          ? ((data['message'] ?? data['error'])?.toString() ?? '删除失败')
          : '删除失败';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _lotteryActionBusy = false);
    }
  }

  Future<void> _kickLotteryParticipant({
    required dynamic eventId,
    required dynamic userId,
    required String userLabel,
  }) async {
    if (_lotteryActionBusy) return;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: const Text('踢出用户'),
        content: Text('确定要将 $userLabel 踢出本次抽奖吗？踢出后该用户仍可重新参与。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('踢出', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (!mounted || confirm != true) return;
    setState(() => _lotteryActionBusy = true);
    try {
      final res = await _dio.delete(
        '/super/lottery/participants/$eventId/$userId',
      );
      if (res.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已踢出该用户')));
        _refreshLotteryTab();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('踢出失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _lotteryActionBusy = false);
    }
  }
}
