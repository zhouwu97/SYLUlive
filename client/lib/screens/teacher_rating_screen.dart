import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/post_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'post_detail_screen.dart';
import 'dart:io' show File;

class TeacherRatingScreen extends StatefulWidget {
  const TeacherRatingScreen({super.key});
  @override
  State<TeacherRatingScreen> createState() => _TeacherRatingScreenState();
}

class _TeacherRatingScreenState extends State<TeacherRatingScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<dynamic> _teachers = [];
  List<dynamic> _posts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _loading = true);
    final dio = context.read<AuthProvider>().dio;
    final postProvider = context.read<PostProvider>();
    try {
      // 加载教师列表
      final tRes = await dio.get('/teachers');
      _teachers = (tRes.data as List?) ?? [];
      // 加载避雷板块帖子 (boardId=3)
      await postProvider.loadPosts(boardId: 3);
      if (mounted) {
        setState(() {
          _posts = postProvider.postsFor(3);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addTeacher() async {
    final nameCtrl = TextEditingController();
    final deptCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('添加教师'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: '教师姓名',
                hintText: '不可重复',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: deptCtrl,
              decoration: const InputDecoration(labelText: '院系（选填）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    deptCtrl.dispose();
    if (ok != true || nameCtrl.text.trim().isEmpty) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.post(
        '/teachers',
        data: {
          'name': nameCtrl.text.trim(),
          'department': deptCtrl.text.trim(),
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('教师已提交，等待管理员验证'),
            backgroundColor: Colors.green,
          ),
        );
        _loadData();
      }
    } on DioException catch (e) {
      final msg = (e.response?.data is Map)
          ? (e.response!.data as Map)['error']?.toString() ?? '添加失败'
          : '添加失败';
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
    }
  }

  Future<void> _rateTeacher(dynamic teacher) async {
    final commentCtrl = TextEditingController();
    final rating = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('打分 ${teacher['name']}'),
        content: const Text('请选择推荐或不推荐。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'negative'),
            child: const Text('👎 不推荐', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'positive'),
            child: const Text('👍 推荐', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
    commentCtrl.dispose();
    if (rating == null) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.post(
        '/teachers/${teacher['id']}/rate',
        data: {'star': rating == 'positive' ? 5 : 1, 'comment': ''},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('评价成功'), backgroundColor: Colors.green),
        );
        _loadData();
      }
    } on DioException catch (e) {
      final msg = (e.response?.data is Map)
          ? (e.response!.data as Map)['error']?.toString() ?? '评价失败'
          : '评价失败';
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('避雷'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: '添加教师',
            onPressed: _addTeacher,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBg(themeProvider, isDark),
          SafeArea(
            child: Column(
              children: [
                // 警告横幅
                _buildWarningBanner(isDark),
                // Tab
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: Colors.red[400],
                    indicatorWeight: 3,
                    labelStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    unselectedLabelStyle: const TextStyle(fontSize: 12),
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: '排行榜'),
                      Tab(text: '讨论'),
                    ],
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildRankTab(isDark),
                            _buildPostsTab(isDark),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBg(ThemeProvider p, bool d) {
    if (p.isBackgroundVisible && p.getBackgroundImageFor(context) != null) {
      final bg = p.getBackgroundImageFor(context)!;
      final isAsset = !bg.startsWith('http') && !bg.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$bg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _gradient(d),
                )
              : bg.startsWith('/')
              ? Image.file(
                  File(bg),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _gradient(d),
                )
              : Image.network(
                  bg,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _gradient(d),
                ),
          Container(
            color: d
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3),
          ),
        ],
      );
    }
    return _gradient(d);
  }

  Widget _gradient(bool d) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: d
            ? [
                const Color(0xFF1A1A2E),
                const Color(0xFF16213E),
                const Color(0xFF0F3460),
              ]
            : [
                const Color(0xFF667EEA),
                const Color(0xFF764BA2),
                const Color(0xFFF093FB),
              ],
      ),
    ),
  );

  Widget _buildWarningBanner(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '严禁辱骂、攻击教师。违规：1次删帖禁言7天，2次禁言1个月，3次永久禁言。',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white70 : Colors.red[800],
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRankTab(bool isDark) {
    if (_teachers.isEmpty)
      return _empty('暂无教师', '点击右上角 + 添加教师', Icons.school, isDark);
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: _teachers.length,
        itemBuilder: (_, i) {
          final t = _teachers[i];
          final pos = t['positive_count'] ?? 0;
          final neg = t['negative_count'] ?? 0;
          return GlassContainer(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            borderRadius: 14,
            blur: 8,
            opacity: isDark ? 0.12 : 0.35,
            child: Row(
              children: [
                // 排名
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: i < 3
                        ? (i == 0
                              ? Colors.amber
                              : i == 1
                              ? Colors.grey[400]
                              : Colors.brown[300])
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: i < 3
                            ? Colors.white
                            : (isDark ? Colors.white54 : Colors.grey[600]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            t['name'] ?? '',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          if (t['verified'] != true) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '待验证',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (t['department'] != null &&
                          t['department'].toString().isNotEmpty)
                        Text(
                          t['department'],
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                ),
                // 评价按钮
                Column(
                  children: [
                    Text(
                      '👍 $pos',
                      style: TextStyle(fontSize: 12, color: Colors.green),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '👎 $neg',
                      style: TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.rate_review_outlined, size: 20),
                  color: isDark ? Colors.white38 : Colors.grey[500],
                  onPressed: () => _rateTeacher(t),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPostsTab(bool isDark) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: _posts.isEmpty
          ? ListView(
              children: [_empty('暂无讨论', '点击右下角 + 发起讨论', Icons.forum, isDark)],
            )
          : ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
              itemCount: _posts.length,
              itemBuilder: (_, i) => PostCard(
                post: _posts[i],
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PostDetailScreen(
                      postId: _posts[i].id,
                      initialPost: _posts[i],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _empty(String t, String s, IconData ic, bool d) => Center(
    child: GlassContainer(
      padding: const EdgeInsets.all(32),
      borderRadius: 20,
      blur: 15,
      opacity: 0.1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 64, color: d ? Colors.white60 : Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            t,
            style: TextStyle(
              fontSize: 18,
              color: d ? Colors.white70 : Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s,
            style: TextStyle(
              fontSize: 14,
              color: d ? Colors.white.withOpacity(0.4) : Colors.grey[400],
            ),
          ),
        ],
      ),
    ),
  );
}
