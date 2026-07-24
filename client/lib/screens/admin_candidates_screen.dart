import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/admin_user_summary.dart';
import '../providers/auth_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/cached_avatar.dart';
import '../config/api_constants.dart';

class AdminCandidatesScreen extends StatefulWidget {
  const AdminCandidatesScreen({super.key});

  @override
  State<AdminCandidatesScreen> createState() => _AdminCandidatesScreenState();
}

class _AdminCandidatesScreenState extends State<AdminCandidatesScreen> {
  List<AdminUserSummary> _candidates = [];
  bool _isLoading = false;
  bool _hasSearched = false;
  String? _errorMessage;
  final _searchController = TextEditingController();

  int? _totalUsers;
  int? _eduUsers;
  int? _otherUsers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchStats();
      _loadCandidates();
    });
  }

  Future<void> _fetchStats() async {
    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get('/admin/candidates/stats');
      if (mounted) {
        setState(() {
          _totalUsers = res.data['total'];
          _eduUsers = res.data['edu'];
          _otherUsers = res.data['other'];
        });
      }
    } catch (e) {
      // ignore
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates({String? keyword}) async {
    final q = keyword ?? _searchController.text.trim();

    setState(() {
      _isLoading = true;
      _hasSearched = q.isNotEmpty;
      _errorMessage = null;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get(
        '/admin/candidates',
        queryParameters: q.isEmpty ? null : {'q': q},
      );

      if (mounted) {
        setState(() {
          _candidates = ((res.data as List?) ?? const [])
              .whereType<Map>()
              .map(
                (value) => AdminUserSummary.fromJson(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _searchCandidates() async {
    await _loadCandidates(keyword: _searchController.text.trim());
  }

  Future<void> _inviteAdmin(AdminUserSummary candidate) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _showReasonDialog(
      title: '邀�?${candidate.nickname} 成为管理�?,
      label: '给候选人的邀请理�?,
      hint: '例如：社区贡献活跃、处理问题客观，希望邀请你参与管理',
      helperText: '该用户会看到这段文字，并决定是否接受邀请�?,
      confirmText: '发送邀�?,
    );
    if (!mounted || reason == null) return;

    try {
      await dio.post(
        '/admin/invite/${candidate.id}',
        data: {'reason': reason},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('邀请已发送，用户同意后进入管理员代办'),
          backgroundColor: Colors.green,
        ),
      );
      setState(
          () => _candidates.removeWhere((item) => item.id == candidate.id));
    } on DioException catch (e) {
      if (!mounted) return;
      String msg = '邀请失�?;
      if (e.response?.data is Map) {
        msg = (e.response!.data as Map)['error']?.toString() ?? msg;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  Future<String?> _showReasonDialog({
    required String title,
    required String label,
    required String hint,
    required String helperText,
    required String confirmText,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            helperText: helperText,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx, reason);
            },
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int value, bool isDark) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('管理员候选人')),
      body: Column(
        children: [
          if (_totalUsers != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: GlassContainer(
                padding: const EdgeInsets.symmetric(vertical: 16),
                borderRadius: 16,
                blur: 8,
                opacity: isDark ? 0.05 : 0.8,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildStatItem('总用�?, _totalUsers!, isDark),
                    _buildStatItem('教务账号', _eduUsers!, isDark),
                    _buildStatItem('其他', _otherUsers!, isDark),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: GlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              borderRadius: 12,
              blur: 8,
              opacity: isDark ? 0.1 : 0.4,
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _searchCandidates(),
                decoration: InputDecoration(
                  icon: const Icon(Icons.search, color: Colors.grey),
                  hintText: '输入用户 ID、学�?账号或昵称搜索候选人',
                  hintStyle: const TextStyle(fontSize: 13),
                  border: InputBorder.none,
                  suffixIcon: _searchController.text.trim().isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            _loadCandidates();
                          },
                        )
                      : IconButton(
                          icon: const Icon(Icons.arrow_forward,
                              color: Colors.blue),
                          onPressed: _searchCandidates,
                        ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(child: Text(_errorMessage!))
                    : _candidates.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                _hasSearched ? '未找到候选人' : '暂无符合条件的候选人',
                                style: TextStyle(
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.black54),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _candidates.length,
                            itemBuilder: (context, index) {
                              final candidate = _candidates[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                color: isDark ? Colors.grey[850] : Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                child: ListTile(
                                  leading: CachedAvatar(
                                    imageUrl: candidate.avatar.isEmpty
                                        ? null
                                        : ApiConstants.fullUrl(candidate.avatar),
                                    fallbackText: candidate.nickname,
                                    radius: 20,
                                  ),
                                  title: Text(
                                    candidate.nickname.isEmpty
                                        ? '未知用户'
                                        : candidate.nickname,
                                  ),
                                  subtitle: Text(
                                    '${candidate.publicIdLabel}\n${candidate.accountLabel}',
                                  ),
                                  isThreeLine: true,
                                  trailing: FilledButton.tonal(
                                    onPressed: () => _inviteAdmin(candidate),
                                    child: const Text('邀�?),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
