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

  String _lotteryStatusLabel(dynamic status) {
    switch ((status as num?)?.toInt()) {
      case 0:
        return '进行中';
      case 1:
        return '已开奖';
      case 2:
        return '已流拍';
      case 3:
        return '已取消';
      default:
        return '已结束';
    }
  }

  bool _isLotteryDue(dynamic drawTimeRaw) {
    final dt = DateTime.tryParse('${drawTimeRaw ?? ''}');
    if (dt == null) return false;
    return !dt.isAfter(DateTime.now());
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
        final event = Map<String, dynamic>.from(rawEvent);
        final eventID = (event['id'] as num?)?.toInt();
        final status = (event['status'] as num?)?.toInt() ?? 0;
        final isOngoing = status == 0;
        final isDue = _isLotteryDue(event['draw_time']);
        final hasAnyOngoing = isOngoing ||
            _lotteryEvents.any((e) => (e['status'] as num?)?.toInt() == 0);
        final participants = ((data['participants'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        final totalParticipants =
            (data['total'] as num?)?.toInt() ?? participants.length;
        final winner = event['winner'] is Map
            ? Map<String, dynamic>.from(event['winner'] as Map)
            : null;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_lotteryEvents.length > 1) ...[
                    DropdownButtonFormField<int>(
                      key: ValueKey<int?>(eventID),
                      initialValue: _lotteryEvents.any(
                              (e) => (e['id'] as num?)?.toInt() == eventID)
                          ? eventID
                          : null,
                      decoration: const InputDecoration(
                        labelText: '切换查看抽奖期次',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: _lotteryEvents.map((item) {
                        final id = (item['id'] as num?)?.toInt() ?? 0;
                        final label =
                            '#${item['id']} ${item['title'] ?? ''}（${_lotteryStatusLabel(item['status'])}）';
                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (nextId) {
                        if (nextId != null) {
                          _refreshLotteryTab(eventId: nextId);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '当前查看: ${event['title'] ?? ''}（${_lotteryStatusLabel(status)}）',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed:
                            _lotteryActionBusy ? null : () => _refreshLotteryTab(),
                        icon: const Icon(Icons.refresh),
                      ),
                      FilledButton.icon(
                        onPressed: _lotteryActionBusy
                            ? null
                            : () => _showLotteryEventDialog(
                                  hasOngoingEvent: hasAnyOngoing,
                                ),
                        icon: const Icon(Icons.add),
                        label: const Text('发布抽奖'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('奖品: ${event['prize_name'] ?? ''}'),
                  if ('${event['description'] ?? ''}'.trim().isNotEmpty)
                    Text('说明: ${event['description']}'),
                  Text('开奖时间: ${_formatLotteryDateTime(event['draw_time'])}'),
                  Text('参与人数: $totalParticipants'),
                  if (winner != null)
                    Text('中奖者: ${winner['nickname'] ?? '未知用户'}'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (isOngoing && eventID != null)
                        OutlinedButton.icon(
                          onPressed: _lotteryActionBusy
                              ? null
                              : () => _showLotteryEventDialog(
                                    editingEvent: event,
                                  ),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('编辑活动'),
                        ),
                      if (isOngoing && isDue && eventID != null)
                        FilledButton.tonalIcon(
                          onPressed: _lotteryActionBusy
                              ? null
                              : () => _manualDrawLotteryEvent(eventID),
                          icon: const Icon(Icons.flash_on, size: 18),
                          label: const Text('兜底手动补开'),
                        ),
                      if (eventID != null)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                          onPressed: _lotteryActionBusy
                              ? null
                              : () => _deleteLotteryEvent(eventID),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除活动'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: participants.isEmpty
                  ? const Center(
                      child: AppContentSurface.reading(child: Text('暂无参与者')),
                    )
                  : ListView.builder(
                      itemCount: participants.length,
                      itemBuilder: (context, index) {
                        final p = participants[index];
                        final user = p['user'] is Map
                            ? Map<String, dynamic>.from(p['user'] as Map)
                            : const <String, dynamic>{};
                        final nickname = '${user['nickname'] ?? '未知用户'}';
                        final avatar = '${user['avatar'] ?? ''}';
                        final displayWeight =
                            p['current_weight'] ?? p['weight'] ?? 1;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundImage: avatar.isNotEmpty
                                ? NetworkImage(
                                    ApiConstants.fullUrl(avatar),
                                  )
                                : null,
                            child: avatar.isEmpty
                                ? Text(nickname.isNotEmpty ? nickname[0] : '?')
                                : null,
                          ),
                          title: Text(nickname),
                          subtitle: Text(
                            '用户 ID：${p['user_id'] ?? user['id']} | 实时权重: $displayWeight',
                          ),
                          trailing: isOngoing
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.remove_circle,
                                    color: Colors.red,
                                  ),
                                  tooltip: '踢出（可重新参与）',
                                  onPressed: _lotteryActionBusy
                                      ? null
                                      : () => _kickLotteryParticipant(
                                            eventId: p['lottery_id'] ?? eventID,
                                            userId: p['user_id'] ?? user['id'],
                                            userLabel: nickname,
                                          ),
                                )
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLotteryEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _lotteryActionBusy
                ? null
                : () => _showLotteryEventDialog(),
            icon: const Icon(Icons.add),
            label: const Text('发布抽奖'),
          ),
        ],
      ),
    );
  }

  String _formatLotteryDateTime(dynamic value) {
    final text = '${value ?? ''}';
    final dt = DateTime.tryParse(text);
    if (dt == null) return text;
    final beijing = dt.toUtc().add(const Duration(hours: 8));
    return _formatBeijingWallTime(beijing);
  }

  String _formatBeijingWallTime(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  DateTime _nowBeijingWallTime() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  bool _isFutureBeijingWallTime(DateTime value) {
    return _beijingWallTimeToUtc(value).isAfter(DateTime.now().toUtc());
  }

  String _beijingWallTimeToRfc3339(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final h = value.hour.toString().padLeft(2, '0');
    final min = value.minute.toString().padLeft(2, '0');
    return '$y-$m-${d}T$h:$min:00+08:00';
  }

  DateTime _beijingWallTimeToUtc(DateTime value) {
    return DateTime.utc(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
    ).subtract(const Duration(hours: 8));
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

  Future<void> _showLotteryEventDialog({
    Map<String, dynamic>? editingEvent,
    bool hasOngoingEvent = false,
  }) async {
    final isEdit = editingEvent != null;
    final titleCtrl =
        TextEditingController(text: '${editingEvent?['title'] ?? ''}');
    final prizeCtrl =
        TextEditingController(text: '${editingEvent?['prize_name'] ?? ''}');
    final descCtrl =
        TextEditingController(text: '${editingEvent?['description'] ?? ''}');
    final messenger = ScaffoldMessenger.of(context);
    DateTime drawTime = _nowBeijingWallTime().add(const Duration(hours: 1));
    if (isEdit) {
      final parsed = DateTime.tryParse('${editingEvent['draw_time'] ?? ''}');
      if (parsed != null) {
        final bj = parsed.toUtc().add(const Duration(hours: 8));
        drawTime = DateTime(bj.year, bj.month, bj.day, bj.hour, bj.minute);
      }
    }
    var submitting = false;

    final saved = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppAlertDialog(
          title: Text(isEdit ? '编辑抽奖活动' : '发布抽奖'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isEdit && hasOngoingEvent) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '提示：发布新抽奖将自动取消当前进行中的抽奖活动。',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                ],
                TextField(
                  controller: titleCtrl,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '抽奖标题'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: prizeCtrl,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '奖品名称'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '活动说明'),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(_formatBeijingWallTime(drawTime)),
                  subtitle: const Text('开奖时间（北京时间）'),
                  onTap: submitting
                      ? null
                      : () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          final nowBj = _nowBeijingWallTime();
                          final date = await showDatePicker(
                            context: ctx,
                            initialDate: drawTime.isBefore(nowBj)
                                ? nowBj
                                : drawTime,
                            firstDate: nowBj,
                            lastDate: nowBj.add(
                              const Duration(days: 365),
                            ),
                          );
                          if (date == null) return;
                          if (!ctx.mounted) return;
                          final time = await showTimePicker(
                            context: ctx,
                            initialTime: TimeOfDay.fromDateTime(drawTime),
                          );
                          if (time == null) return;
                          if (!ctx.mounted) return;
                          setDialogState(() {
                            drawTime = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              time.hour,
                              time.minute,
                            );
                          });
                        },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting
                  ? null
                  : () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      Navigator.pop(ctx, false);
                    },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      final navigator = Navigator.of(ctx);
                      final title = titleCtrl.text.trim();
                      final prize = prizeCtrl.text.trim();
                      if (title.isEmpty || prize.isEmpty) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('请填写标题和奖品')),
                        );
                        return;
                      }
                      if (!_isFutureBeijingWallTime(drawTime)) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('开奖时间必须晚于当前时间')),
                        );
                        return;
                      }
                      setDialogState(() => submitting = true);
                      try {
                        final payload = {
                          'title': title,
                          'prize_name': prize,
                          'description': descCtrl.text.trim(),
                          'draw_time': _beijingWallTimeToRfc3339(drawTime),
                        };
                        if (isEdit) {
                          await _dio.put(
                            '/super/lottery/${editingEvent['id']}',
                            data: payload,
                          );
                        } else {
                          await _dio.post('/super/lottery', data: payload);
                        }
                        FocusManager.instance.primaryFocus?.unfocus();
                        if (navigator.mounted) navigator.pop(true);
                      } on DioException catch (e) {
                        final data = e.response?.data;
                        final msg = data is Map
                            ? ((data['message'] ?? data['error'])?.toString() ??
                                (isEdit ? '更新失败' : '发布失败'))
                            : (isEdit ? '更新失败' : '发布失败');
                        messenger.showSnackBar(
                          SnackBar(
                              content: Text(msg), backgroundColor: Colors.red),
                        );
                        if (ctx.mounted) {
                          setDialogState(() => submitting = false);
                        }
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isEdit ? '保存' : '发布'),
            ),
          ],
        ),
      ),
    );

    titleCtrl.dispose();
    prizeCtrl.dispose();
    descCtrl.dispose();

    if (saved == true && mounted) {
      if (!isEdit) {
        _selectedLotteryEventId = null;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text(isEdit ? '抽奖活动已更新' : '抽奖已发布')),
      );
      _refreshLotteryTab();
    }
  }
}
