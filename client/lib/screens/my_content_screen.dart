import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_constants.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';
import 'post_detail_screen.dart';
import 'dart:io' show File;

/// 我的内容管理页面
/// 查看并管理自己发布的帖子、评论、集市物品，支持多选删除
class MyContentScreen extends StatefulWidget {
  const MyContentScreen({super.key});

  @override
  State<MyContentScreen> createState() => _MyContentScreenState();
}

class _MyContentScreenState extends State<MyContentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isSelectionMode = false;
  final Set<int> _selectedIds = {};

  // 数据
  List<Post> _myPosts = [];
  List<Post> _myMarketPosts = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final currentUserId = authProvider.user?.id;
      if (currentUserId == null) {
        if (mounted) setState(() {
          _isLoading = false;
        });
        return;
      }

      // 直接从 API 获取用户所有帖子，不走 PostProvider 的 board 分页
      final res = await authProvider.dio.get('/user/$currentUserId/posts',
          queryParameters: {'limit': '999'});
      final allPosts = (res.data as List)
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList();

      // 按 board 拆分
      _myPosts = allPosts.where((p) => p.boardId != 2).toList();
      _myMarketPosts = allPosts.where((p) => p.boardId == 2).toList();

      if (mounted) setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _isLoading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  void _toggleSelectionMode() {
    if (mounted) setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelect(int id) {
    if (mounted) setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _onLongPressItem(int id) {
    if (mounted) setState(() {
      _isSelectionMode = true;
      _selectedIds.add(id);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '确认删除',
      message: '确定要删除选中的 ${_selectedIds.length} 项内容吗？删除后普通用户不可见，此操作不可撤销。',
    );

    if (!confirmed) return;

    final postProvider = context.read<PostProvider>();
    int deletedCount = 0;
    final errors = <String>[];

    for (final id in _selectedIds.toList()) {
      final result = await postProvider.deletePostDetailed(id);
      if (result.success) {
        deletedCount++;
        _myPosts.removeWhere((p) => p.id == id);
        _myMarketPosts.removeWhere((p) => p.id == id);
      } else if (result.errorMessage != null) {
        errors.add(result.errorMessage!);
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errors.isEmpty
              ? '已删除 $deletedCount 项'
              : '已删除 $deletedCount 项，${errors.first}'),
          backgroundColor:
              errors.isEmpty && deletedCount > 0 ? Colors.green : Colors.red,
        ),
      );
      if (mounted) setState(() {
        _selectedIds.clear();
        _isSelectionMode = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _toggleSelectionMode,
              )
            : const BackButton(),
        title: _isSelectionMode
            ? Text('已选择 ${_selectedIds.length} 项')
            : const Text('我的内容'),
        actions: [
          if (_isSelectionMode && _selectedIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _deleteSelected,
            ),
        ],
      ),
      body: Stack(
        children: [
          _buildBackground(themeProvider, isDark),
          SafeArea(
            child: Column(
              children: [
                // Tab栏
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: Theme.of(context).primaryColor,
                    indicatorWeight: 3,
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 12),
                    dividerColor: Colors.transparent,
                    tabs: [
                      Tab(
                          text:
                              '我的帖子${_myPosts.isEmpty ? '' : ' (${_myPosts.length})'}'),
                      Tab(
                          text:
                              '我的集市${_myMarketPosts.isEmpty ? '' : ' (${_myMarketPosts.length})'}'),
                    ],
                  ),
                ),

                // Tab内容
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorMessage != null
                          ? _buildErrorView(isDark)
                          : TabBarView(
                              controller: _tabController,
                              children: [
                                _buildPostsList(_myPosts, isDark),
                                _buildMarketList(_myMarketPosts, isDark),
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

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    // 使用全局背景设置，与 profile_screen 保持一致
    if (themeProvider.isBackgroundVisible && themeProvider.getBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getBackgroundImageFor(context)!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildDefaultBackground(isDark))
                : Image.network(bgPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildDefaultBackground(isDark)),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3)),
      ]);
    }
    return _buildDefaultBackground(isDark);
  }

  Widget _buildDefaultBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: ResizeImage(
              const AssetImage('assets/images/morenbeijing.jpeg'),
              width: 1080),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1A1A2E),
                        const Color(0xFF16213E),
                        const Color(0xFF0F3460)
                      ]
                    : [
                        const Color(0xFF667EEA),
                        const Color(0xFF764BA2),
                        const Color(0xFFF093FB)
                      ],
              ),
            ),
          ),
        ),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25)),
      ],
    );
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(28),
        borderRadius: 20,
        blur: 12,
        opacity: 0.12,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off,
              size: 48, color: isDark ? Colors.white30 : Colors.grey[400]),
          const SizedBox(height: 14),
          Text(_errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 15)),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      ),
    );
  }

  // ---- 帖子列表 ----

  Widget _buildPostsList(List<Post> posts, bool isDark) {
    if (posts.isEmpty) {
      return _buildEmptyState(
          '暂无帖子', '发布你的第一条帖子吧', Icons.article_outlined, isDark);
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: posts.length,
        itemBuilder: (context, index) {
          final post = posts[index];
          return _buildPostItem(post, isDark);
        },
      ),
    );
  }

  Widget _buildPostItem(Post post, bool isDark) {
    final isSelected = _selectedIds.contains(post.id);
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      onTap: _isSelectionMode
          ? () => _toggleSelect(post.id)
          : () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PostDetailScreen(postId: post.id, initialPost: post),
                ),
              );
            },
      onLongPress: _isSelectionMode ? null : () => _onLongPressItem(post.id),
      child: Row(
        children: [
          if (_isSelectionMode) ...[
            Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelect(post.id),
              activeColor: Theme.of(context).primaryColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.title.isNotEmpty ? post.title : post.content,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.access_time,
                        size: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(post.createdAt),
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.grey[500]),
                    ),
                    const SizedBox(width: 12),
                    if (post.images.isNotEmpty) ...[
                      Icon(Icons.image,
                          size: 12,
                          color: isDark ? Colors.white38 : Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        '${post.images.length}',
                        style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.grey[500]),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (!_isSelectionMode)
            Icon(Icons.chevron_right,
                color: isDark ? Colors.white30 : Colors.grey[400]),
        ],
      ),
    );
  }

  // ---- 集市列表 ----

  Widget _buildMarketList(List<Post> posts, bool isDark) {
    if (posts.isEmpty) {
      return _buildEmptyState('暂无商品', '发布你的商品吧', Icons.store_outlined, isDark);
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: posts.length,
        itemBuilder: (context, index) {
          final post = posts[index];
          return _buildMarketItem(post, isDark);
        },
      ),
    );
  }

  Widget _buildMarketItem(Post post, bool isDark) {
    final isSelected = _selectedIds.contains(post.id);
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      onTap: _isSelectionMode
          ? () => _toggleSelect(post.id)
          : () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PostDetailScreen(
                    postId: post.id,
                    isMarket: true,
                    initialPost: post,
                  ),
                ),
              );
            },
      onLongPress: _isSelectionMode ? null : () => _onLongPressItem(post.id),
      child: Row(
        children: [
          if (_isSelectionMode) ...[
            Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelect(post.id),
              activeColor: Theme.of(context).primaryColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 8),
          ],
          // 图片缩略图
          if (post.images.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                ApiConstants.fullUrl(post.images.first.url),
                width: 60,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 60,
                  height: 60,
                  color: isDark ? Colors.white12 : Colors.grey[200],
                  child: Icon(Icons.image,
                      color: isDark ? Colors.white30 : Colors.grey[400]),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.title.isNotEmpty ? post.title : post.content,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (post.price > 0) ...[
                      Text(
                        '¥${post.price.toStringAsFixed(post.price.truncateToDouble() == post.price ? 0 : 2)}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFFF6B6B),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    _buildTypeTag(post.postType),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.access_time,
                        size: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(post.createdAt),
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.grey[500]),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!_isSelectionMode)
            Icon(Icons.chevron_right,
                color: isDark ? Colors.white30 : Colors.grey[400]),
        ],
      ),
    );
  }

  Widget _buildTypeTag(String type) {
    String label;
    Color color;
    switch (type) {
      case 'sell':
        label = '出售';
        color = Colors.green;
        break;
      case 'buy':
        label = '求购';
        color = Colors.orange;
        break;
      case 'proxy':
        label = '代课';
        color = Colors.blue;
        break;
      case 'exposure':
        label = '曝光';
        color = Colors.red;
        break;
      default:
        label = type.isNotEmpty ? type : '其他';
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildEmptyState(
      String title, String subtitle, IconData icon, bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 64, color: isDark ? Colors.white60 : Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                  fontSize: 18,
                  color: isDark ? Colors.white70 : Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? Colors.white.withOpacity(0.4)
                      : Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}
