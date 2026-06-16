import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class SuperAdminScreen extends StatefulWidget {
  const SuperAdminScreen({super.key});
  @override
  State<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends State<SuperAdminScreen>
    with SingleTickerProviderStateMixin {
  late Dio _dio;
  late TabController _tabController;
  List<dynamic> _users = [];
  List<dynamic> _pendingInvitations = [];
  List<dynamic> _adminLogs = [];
  String _searchQuery = '';
  late Future<Response<dynamic>> _lotteryFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _dio = context.read<AuthProvider>().dio;
    _lotteryFuture = _loadLotteryParticipants();
    _loadAll();
  }

  @override
  void dispose() {
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

  Future<void> _loadUsers() async {
    try {
      final res = await _dio.get('/super/users', queryParameters: {
        if (_searchQuery.isNotEmpty) 'search': _searchQuery,
      });
      _users = res.data as List;
    } catch (_) {}
  }

  Future<void> _loadInvitations() async {
    try {
      final res = await _dio.get('/super/invitations/pending');
      _pendingInvitations = res.data as List;
    } catch (_) {}
  }

  Future<Response<dynamic>> _loadLotteryParticipants() {
    return _dio.get('/super/lottery/participants');
  }

  void _refreshLotteryTab() {
    if (mounted) {
      setState(() {
        _lotteryFuture = _loadLotteryParticipants();
      });
    }
  }

  Future<void> _approveInvitation(dynamic inv, bool approve) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
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
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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
        data: {
          'reject': !approve,
          'reason': reason,
        },
      );
      if (mounted) {
        // 本地移除该代办
        if (mounted)
          setState(() =>
              _pendingInvitations.removeWhere((i) => i['id'] == inv['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(approve ? '已提交同意审批' : '已驳回'),
              backgroundColor: approve ? Colors.green : Colors.red),
        );
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      final message = data is Map && data['error'] != null
          ? data['error'].toString()
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('超级管理员面板'),
        leading: const BackButton(),
        actions: [
          IconButton(
            icon: const Icon(Icons.smart_toy),
            tooltip: '全局 AI 配置',
            onPressed: _showGlobalAiConfigDialog,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '用户管理'),
            Tab(text: '管理员审批'),
            Tab(text: '管理日志'),
            Tab(text: '抽奖管理'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildUsersTab(),
          _buildApprovalsTab(),
          _buildAdminLogsTab(),
          _buildLotteryTab(),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          decoration: const InputDecoration(
              hintText: '搜索学号/昵称...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder()),
          onChanged: (v) {
            _searchQuery = v;
            _loadUsers();
          },
        ),
      ),
      Expanded(
        child: _users.isEmpty
            ? const Center(child: Text('暂无用户'))
            : ListView.builder(
                itemCount: _users.length,
                itemBuilder: (_, i) => _buildUserItem(_users[i]),
              ),
      ),
    ]);
  }

  Widget _buildUserItem(dynamic user) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
            child: Text((user['nickname'] ?? '?').toString().substring(0, 1))),
        title: Text(user['nickname'] ?? '未知'),
        subtitle:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('学号: ${user['student_id']}'),
          Text('角色: ${user['role']} | 诚信: ${user['credit_score']}%'),
          Text(
              '云考余额: ¥${(((user['ai_balance_cents'] ?? 0) as num).toDouble() / 100).toStringAsFixed(2)}'),
        ]),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _handleUserAction(user, v),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'recharge', child: Text('云考充值')),
            const PopupMenuItem(value: 'role', child: Text('修改角色')),
            const PopupMenuItem(value: 'reset', child: Text('重置密码')),
            if (user['role'] != 'super_admin')
              const PopupMenuItem(value: 'delete', child: Text('删除用户')),
          ],
        ),
      ),
    );
  }

  void _handleUserAction(dynamic user, String action) {
    if (action == 'recharge')
      _showRechargeDialog(user);
    else if (action == 'role')
      _showChangeRoleDialog(user);
    else if (action == 'reset')
      _resetPassword(user['id']);
    else if (action == 'delete') _deleteUser(user['id']);
  }

  void _showRechargeDialog(dynamic user) {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController(text: '云考余额充值');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云考余额充值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('用户: ${user['nickname']} (${user['student_id']})'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '充值金额 (元)',
                border: OutlineInputBorder(),
                hintText: '例如 9.90',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注',
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
          ElevatedButton(
            onPressed: () async {
              final yuan = double.tryParse(amountCtrl.text.trim());
              if (yuan == null || yuan <= 0) {
                return;
              }
              final cents = (yuan * 100).round();
              try {
                await _dio.post(
                    '/super/users/${user['id']}/ai_balance/recharge',
                    data: {
                      'amount_cents': cents,
                      'note': noteCtrl.text.trim(),
                    });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(
                            '已为 ${user['nickname']} 充值 ¥${yuan.toStringAsFixed(2)}')),
                  );
                }
                if (mounted) {
                  Navigator.pop(ctx);
                }
                _loadUsers();
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('充值失败')),
                  );
                }
              }
            },
            child: const Text('确认充值'),
          ),
        ],
      ),
    ).then((_) {
      amountCtrl.dispose();
      noteCtrl.dispose();
    });
  }

  Widget _buildApprovalsTab() {
    if (_pendingInvitations.isEmpty)
      return const Center(child: Text('暂无待审批的申请'));
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _pendingInvitations.length,
        itemBuilder: (_, i) {
          final inv = _pendingInvitations[i];
          final user = inv['user'] ?? {};
          final inviter = inv['inviter'] ?? {};
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      CircleAvatar(
                          radius: 18,
                          child: Text((user['nickname'] ?? '?')
                              .toString()
                              .substring(0, 1))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(user['nickname'] ?? '未知',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            Text(
                                '学号: ${user['student_id']} | 诚信: ${user['credit_score']}%',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                            Text('邀请人: ${inviter['nickname'] ?? '未知'}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ])),
                    ]),
                    const SizedBox(height: 12),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton.icon(
                        onPressed: () => _approveInvitation(inv, false),
                        icon: const Icon(Icons.close,
                            size: 16, color: Colors.red),
                        label: const Text('驳回',
                            style: TextStyle(color: Colors.red)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _approveInvitation(inv, true),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('同意'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white),
                      ),
                    ]),
                  ]),
            ),
          );
        },
      ),
    );
  }

  // --- 以下为原有用户管理逻辑 ---
  void _showChangeRoleDialog(dynamic user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改角色'),
        content: Text('用户: ${user['nickname']}'),
        actions: [
          if (user['role'] != 'super_admin')
            TextButton(
                onPressed: () {
                  _changeRole(user['id'], 'user');
                  Navigator.pop(ctx);
                },
                child: const Text('普通用户')),
          TextButton(
              onPressed: () {
                _changeRole(user['id'], 'admin');
                Navigator.pop(ctx);
              },
              child: const Text('管理员')),
        ],
      ),
    );
  }

  Future<void> _changeRole(int uid, String role) async {
    try {
      await _dio.put('/super/users/$uid/role', data: {'role': role});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('角色修改成功')));
        _loadUsers();
      }
    } catch (_) {}
  }

  Future<void> _resetPassword(int uid) async {
    try {
      await _dio.post('/super/users/$uid/reset_password');
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('密码已重置')));
    } catch (_) {}
  }

  Future<void> _deleteUser(int uid) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('确认删除'),
              content: const Text('不可撤销'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    child: const Text('删除')),
              ],
            ));
    if (ok == true) {
      try {
        await _dio.delete('/super/users/$uid');
        _loadUsers();
      } catch (_) {}
    }
  }

  Future<void> _showGlobalAiConfigDialog() async {
    final keyCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final inputTokenCtrl = TextEditingController(text: '2');
    final outputTokenCtrl = TextEditingController(text: '4');
    final cacheHitCtrl = TextEditingController(text: '1');
    final minLiveCtrl = TextEditingController(text: '2');
    String currentProvider = 'custom';

    // 先加载当前的配置
    try {
      final res = await _dio.get('/super/ai_config');
      urlCtrl.text = res.data['base_url'] ?? '';
      keyCtrl.text = res.data['api_key'] ?? '';
      modelCtrl.text = res.data['model_name'] ?? '';
      inputTokenCtrl.text =
          (res.data['input_price_per_1k_cents'] ?? '2').toString();
      outputTokenCtrl.text =
          (res.data['output_price_per_1k_cents'] ?? '4').toString();
      cacheHitCtrl.text = (res.data['cache_hit_price_cents'] ?? '1').toString();
      minLiveCtrl.text = (res.data['min_live_price_cents'] ?? '2').toString();

      final url = urlCtrl.text.toLowerCase();
      if (url.contains('deepseek'))
        currentProvider = 'deepseek';
      else if (url.contains('moonshot'))
        currentProvider = 'kimi';
      else if (url.contains('bigmodel.cn'))
        currentProvider = 'zhipu';
      else if (url.contains('dashscope'))
        currentProvider = 'qwen';
      else if (url.contains('xiaomi') || url.contains('mimo'))
        currentProvider = 'mimo';
      else if (url.contains('openai.com')) currentProvider = 'openai';
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('加载配置失败')));
    }

    bool isFetchingModels = false;
    Future<void> fetchModels(StateSetter setDialogState) async {
      if (urlCtrl.text.isEmpty || keyCtrl.text.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请先填写 Base URL 和 API Key')));
        return;
      }
      setDialogState(() => isFetchingModels = true);
      try {
        final dio = Dio();
        String url = urlCtrl.text.trim();
        if (!url.endsWith('/models')) {
          url = url.endsWith('/') ? '${url}models' : '$url/models';
        }
        final res = await dio.get(
          url,
          options: Options(
              headers: {'Authorization': 'Bearer ${keyCtrl.text.trim()}'}),
        );
        if (res.statusCode == 200 && res.data['data'] != null) {
          final List data = res.data['data'];
          final availableModels = data.map((e) => e['id'].toString()).toList();
          if (availableModels.isNotEmpty) {
            if (mounted) {
              showModalBottomSheet(
                context: context,
                builder: (ctx) => ListView.builder(
                  itemCount: availableModels.length,
                  itemBuilder: (ctx, index) => ListTile(
                    title: Text(availableModels[index]),
                    onTap: () {
                      setDialogState(() {
                        modelCtrl.text = availableModels[index];
                      });
                      Navigator.pop(ctx);
                    },
                  ),
                ),
              );
            }
          } else {
            if (mounted)
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('未获取到模型列表')));
          }
        } else {
          if (mounted)
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('获取失败')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('请求失败: $e')));
      } finally {
        setDialogState(() => isFetchingModels = false);
      }
    }

    void applyProviderDefaults(String provider) {
      if (provider == 'deepseek') {
        urlCtrl.text = 'https://api.deepseek.com/v1';
        modelCtrl.text = 'deepseek-v4-flash';
      } else if (provider == 'kimi') {
        urlCtrl.text = 'https://api.moonshot.cn/v1';
        modelCtrl.text = 'moonshot-v1-8k';
      } else if (provider == 'zhipu') {
        urlCtrl.text = 'https://open.bigmodel.cn/api/paas/v4';
        modelCtrl.text = 'glm-4-flash';
      } else if (provider == 'qwen') {
        urlCtrl.text = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
        modelCtrl.text = 'qwen-turbo';
      } else if (provider == 'openai') {
        urlCtrl.text = 'https://api.openai.com/v1';
        modelCtrl.text = 'gpt-4o-mini';
      } else if (provider == 'mimo') {
        urlCtrl.text = 'https://api.xiaomimimo.com/v1';
        modelCtrl.text = 'mimo-v2.5-pro';
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          title: const Text('系统全局 AI 兜底配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('此配置为系统默认的官方大模型。\n当用户未填写自定义 API Key 时，会走此配置并按余额扣费。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '建议把官方接口价格设置得低于市场直连价。\n缓存命中会走更低单价，未命中才按真实 token 结算。',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: currentProvider,
                  decoration: const InputDecoration(
                    labelText: '快速预设提供商',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'deepseek', child: Text('DeepSeek')),
                    DropdownMenuItem(value: 'kimi', child: Text('Kimi (月之暗面)')),
                    DropdownMenuItem(value: 'zhipu', child: Text('智谱清言')),
                    DropdownMenuItem(value: 'qwen', child: Text('通义千问')),
                    DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                    DropdownMenuItem(value: 'mimo', child: Text('小米 MiMo')),
                    DropdownMenuItem(
                        value: 'custom', child: Text('自定义 (Custom)')),
                  ],
                  onChanged: (val) {
                    setDialogState(() {
                      currentProvider = val!;
                      applyProviderDefaults(currentProvider);
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key (必填)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: modelCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Model Name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    isFetchingModels
                        ? const CircularProgressIndicator()
                        : IconButton(
                            icon: const Icon(Icons.sync),
                            onPressed: () => fetchModels(setDialogState),
                            tooltip: '获取可用模型',
                          ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: inputTokenCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '输入 1K token 单价 (分)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: outputTokenCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '输出 1K token 单价 (分)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cacheHitCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '缓存命中价格 (分)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: minLiveCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '实时调用最低价格 (分)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await _dio.put('/super/ai_config', data: {
                    'base_url': urlCtrl.text.trim(),
                    'api_key': keyCtrl.text.trim(),
                    'model_name': modelCtrl.text.trim(),
                    'input_price_per_1k_cents':
                        int.tryParse(inputTokenCtrl.text.trim()) ?? 2,
                    'output_price_per_1k_cents':
                        int.tryParse(outputTokenCtrl.text.trim()) ?? 4,
                    'cache_hit_price_cents':
                        int.tryParse(cacheHitCtrl.text.trim()) ?? 1,
                    'min_live_price_cents':
                        int.tryParse(minLiveCtrl.text.trim()) ?? 2,
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('系统 AI 配置已更新')));
                  }
                  Navigator.pop(ctx);
                } catch (_) {
                  if (mounted)
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('更新失败')));
                }
              },
              child: const Text('保存全局配置'),
            ),
          ],
        );
      }),
    );

    keyCtrl.dispose();
    urlCtrl.dispose();
    modelCtrl.dispose();
    inputTokenCtrl.dispose();
    outputTokenCtrl.dispose();
    cacheHitCtrl.dispose();
    minLiveCtrl.dispose();
  }
  // ====== 管理员日志 Tab ======

  Widget _buildAdminLogsTab() {
    if (_adminLogs.isEmpty) {
      return const Center(child: Text('暂无明显管理员操作日志'));
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

    return Card(
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
            Text(
              '$action — $target',
              style: const TextStyle(fontSize: 13),
            ),
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
                  label: const Text('追回经验',
                      style: TextStyle(color: Colors.red, fontSize: 12)),
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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
              final amount = int.tryParse(amountCtrl.text) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的追回数量')),
                );
                return;
              }
              try {
                await _dio.post('/super/admin_logs/revoke_exp', data: {
                  'admin_id': adminId,
                  'amount': amount,
                  'reason': reasonCtrl.text.trim(),
                });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('经验已追回')),
                  );
                  _loadAdminLogs();
                }
                Navigator.pop(ctx);
              } on DioException catch (e) {
                final msg = e.response?.data?['error'] ?? '操作失败';
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
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
          return Center(child: Text('加载失败: ${snapshot.error}'));
        }
        if (snapshot.data?.statusCode == 404) {
          return _buildLotteryEmptyState('暂无抽奖活动');
        }

        final data = snapshot.data?.data;
        if (data == null) return _buildLotteryEmptyState('暂无数据');

        final event = data['event'];
        final participants = (data['participants'] as List)
            .map((e) => e as Map<String, dynamic>)
            .toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '当前活动: ${event['title'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _refreshLotteryTab,
                        icon: const Icon(Icons.refresh),
                      ),
                      FilledButton.icon(
                        onPressed: _showCreateLotteryDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('发布抽奖'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('奖品: ${event['prize_name'] ?? ''}'),
                  Text('开奖时间: ${_formatLotteryDateTime(event['draw_time'])}'),
                  Text('参与人数: ${participants.length}'),
                ],
              ),
            ),
            Expanded(
              child: participants.isEmpty
                  ? const Center(child: Text('暂无参与者'))
                  : ListView.builder(
                      itemCount: participants.length,
                      itemBuilder: (context, index) {
                        final p = participants[index];
                        final user = p['user'];
                        final nickname = '${user['nickname'] ?? '未知用户'}';
                        final avatar = '${user['avatar'] ?? ''}';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundImage: avatar.isNotEmpty
                                ? NetworkImage(avatar.startsWith('http')
                                    ? avatar
                                    : 'https://sylu.zhouwu.ccwu.cc$avatar')
                                : null,
                            child: avatar.isEmpty
                                ? Text(nickname.isNotEmpty ? nickname[0] : '?')
                                : null,
                          ),
                          title: Text(nickname),
                          subtitle: Text(
                              '学号: ${user['student_id']} | 权重: ${p['weight']}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle,
                                color: Colors.red),
                            tooltip: '踢出',
                            onPressed: () => _kickLotteryParticipant(
                              eventId: event['id'],
                              userId: user['id'],
                              userLabel: nickname,
                            ),
                          ),
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
            onPressed: _showCreateLotteryDialog,
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
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _kickLotteryParticipant({
    required dynamic eventId,
    required dynamic userId,
    required String userLabel,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('踢出用户'),
        content: Text('确定要将 $userLabel 踢出本次抽奖吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('踢出', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm != true) return;
    try {
      final res =
          await _dio.delete('/super/lottery/participants/$eventId/$userId');
      if (res.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已踢出该用户')));
        _refreshLotteryTab();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('踢出失败: $e')));
      }
    }
  }

  Future<void> _showCreateLotteryDialog() async {
    final titleCtrl = TextEditingController();
    final prizeCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    DateTime drawTime = DateTime.now().add(const Duration(hours: 1));

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('发布抽奖'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: '抽奖标题'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: prizeCtrl,
                  decoration: const InputDecoration(labelText: '奖品名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '活动说明'),
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title:
                      Text(_formatLotteryDateTime(drawTime.toIso8601String())),
                  subtitle: const Text('开奖时间'),
                  onTap: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: drawTime,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date == null) return;
                    if (!ctx.mounted) return;
                    final time = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(drawTime),
                    );
                    if (time == null) return;
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
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.pop(ctx, false);
                },
                child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final navigator = Navigator.of(ctx);
                final title = titleCtrl.text.trim();
                final prize = prizeCtrl.text.trim();
                if (title.isEmpty || prize.isEmpty) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('请填写标题和奖品')),
                  );
                  return;
                }
                if (!drawTime.isAfter(DateTime.now())) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('开奖时间必须晚于当前时间')),
                  );
                  return;
                }
                try {
                  await _dio.post('/super/lottery', data: {
                    'title': title,
                    'prize_name': prize,
                    'description': descCtrl.text.trim(),
                    'draw_time': drawTime.toUtc().toIso8601String(),
                  });
                  FocusManager.instance.primaryFocus?.unfocus();
                  if (navigator.mounted) navigator.pop(true);
                } on DioException catch (e) {
                  final data = e.response?.data;
                  final msg = data is Map && data['error'] != null
                      ? data['error'].toString()
                      : '发布失败';
                  messenger.showSnackBar(
                    SnackBar(content: Text(msg), backgroundColor: Colors.red),
                  );
                }
              },
              child: const Text('发布'),
            ),
          ],
        ),
      ),
    );

    titleCtrl.dispose();
    prizeCtrl.dispose();
    descCtrl.dispose();

    if (created == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('抽奖已发布')));
      _refreshLotteryTab();
    }
  }
}
