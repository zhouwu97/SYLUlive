import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/course_evaluation.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/course_evaluation_provider.dart';
import '../providers/post_provider.dart';
import '../providers/poll_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/image_decode_size.dart';
import '../utils/post_route.dart';
import '../widgets/course/course_evaluation_form_sheet.dart';
import '../widgets/glass_container.dart';
import '../widgets/app_cached_image.dart';
import '../widgets/community_post_card.dart';
import '../widgets/poll/poll_post_card.dart';
import '../widgets/post_media/post_media_view.dart';
import 'create_post_screen.dart';
import 'poll/poll_composer_screen.dart';
import 'dart:io' show File;

/// 我的内容管理页面
/// 查看并管理自己发布的帖子、评论、集市物品与学科评价，支持多选删除
class MyContentScreen extends StatefulWidget {
  /// 初始打开的页签：0 帖子、1 集市、2 学科评价。
  final int? initialTabIndex;

  /// 深链定位的学科评价提交 ID。通知中心按 related_id 打开第三页签并定位。
  final int? focusCourseEvaluationId;

  const MyContentScreen({
    super.key,
    this.initialTabIndex,
    this.focusCourseEvaluationId,
  });

  @override
  State<MyContentScreen> createState() => _MyContentScreenState();
}

class _MyContentScreenState extends State<MyContentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isSelectionMode = false;
  final Set<int> _selectedIds = {};

  List<Post> _myPosts = [];
  List<Post> _myMarketPosts = [];
  bool _isLoading = true;
  String? _errorMessage;
  int _accountSessionEpoch = -1;
  int? _sessionUserId;

  /// 学科评价页签：滚动控制器与深链定位。
  final ScrollController _evaluationScrollController = ScrollController();
  final Map<int, GlobalKey> _evaluationItemKeys = {};
  int? _highlightEvaluationId;

  @override
  void initState() {
    super.initState();
    final initialIndex = widget.initialTabIndex == null
        ? 0
        : widget.initialTabIndex!.clamp(0, 2);
    _tabController = TabController(length: 3, vsync: this, initialIndex: initialIndex);
    _tabController.addListener(_onTabChanged);
    _evaluationScrollController.addListener(_onEvaluationScroll);
    if (widget.focusCourseEvaluationId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _locateFocusEvaluation();
      });
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 2 && mounted) {
      final provider = context.read<CourseEvaluationProvider>();
      if (!provider.isLoadingMine &&
          provider.mine.isEmpty &&
          provider.mineError == null) {
        provider.loadMine(refresh: true);
      }
    }
    setState(() {});
  }

  void _onEvaluationScroll() {
    if (!_evaluationScrollController.hasClients) return;
    final position = _evaluationScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      final provider = context.read<CourseEvaluationProvider>();
      if (provider.mineHasMore &&
          !provider.isLoadingMoreMine &&
          !provider.isLoadingMine) {
        provider.loadMoreMine();
      }
    }
  }

  /// 通知深链定位：打开第三页签并定位到对应记录；
  /// 翻页仍找不到时保持普通列表，不阻塞浏览。
  Future<void> _locateFocusEvaluation() async {
    final provider = context.read<CourseEvaluationProvider>();
    if (provider.mine.isEmpty) {
      await provider.loadMine(refresh: true);
    }
    if (!mounted) return;
    for (var attempt = 0; attempt < 5; attempt++) {
      final found = provider.mine.any(
        (item) => item.id == widget.focusCourseEvaluationId,
      );
      if (found) {
        if (mounted) {
          setState(() => _highlightEvaluationId = widget.focusCourseEvaluationId);
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        final key = _evaluationItemKeys[widget.focusCourseEvaluationId];
        final itemContext = key?.currentContext;
        if (itemContext != null) {
          await Scrollable.ensureVisible(
            itemContext,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: 0.15,
          );
        }
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() => _highlightEvaluationId = null);
          }
        });
        return;
      }
      if (!provider.mineHasMore || provider.isLoadingMoreMine) break;
      await provider.loadMoreMine();
      if (!mounted) return;
    }
  }

  void _syncSessionScope(AuthProvider auth) {
    if (_accountSessionEpoch == auth.accountSessionEpoch) {
      return;
    }

    _accountSessionEpoch = auth.accountSessionEpoch;
    _sessionUserId = auth.user?.id;
    _myPosts = [];
    _myMarketPosts = [];
    _selectedIds.clear();
    _isSelectionMode = false;
    _errorMessage = null;
    _isLoading = auth.user != null;
    _evaluationItemKeys.clear();
    _highlightEvaluationId = null;

    if (auth.user != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadData();
          // 学科评价数据由 Provider 随账号隔离，此处只需按需重新拉取。
          if (_tabController.index == 2) {
            context.read<CourseEvaluationProvider>().loadMine(refresh: true);
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _evaluationScrollController.removeListener(_onEvaluationScroll);
    _evaluationScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final authProvider = context.read<AuthProvider>();
      final currentUserId = authProvider.user?.id;
      final requestEpoch = authProvider.accountSessionEpoch;
      if (currentUserId == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      // 直接从 API 获取用户所有帖子，不走 PostProvider 的 board 分页
      final res = await authProvider.dio.get(
        '/user/$currentUserId/posts',
        queryParameters: {'limit': '999'},
      );
      final data = res.data is Map ? res.data['data'] : res.data;
      final allPosts = (data as List)
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted ||
          authProvider.accountSessionEpoch != requestEpoch ||
          authProvider.user?.id != currentUserId ||
          _sessionUserId != currentUserId) {
        return;
      }

      // 按 board 拆分
      if (mounted) {
        setState(() {
          _myPosts = allPosts.where((p) => p.boardId != 2).toList();
          _myMarketPosts = allPosts.where((p) => p.boardId == 2).toList();
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '加载失败: $e';
        });
      }
    }
  }

  void _toggleSelectionMode() {
    if (mounted) {
      setState(() {
        _isSelectionMode = !_isSelectionMode;
        if (!_isSelectionMode) {
          _selectedIds.clear();
        }
      });
    }
  }

  void _toggleSelect(int id) {
    if (mounted) {
      setState(() {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      });
    }
  }

  void _onLongPressItem(int id) {
    if (mounted) {
      setState(() {
        _isSelectionMode = true;
        _selectedIds.add(id);
      });
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) {
      return;
    }

    final postProvider = context.read<PostProvider>();
    final pollProvider = context.read<PollProvider>();
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '确认删除',
      message: '确定要删除选中的 ${_selectedIds.length} 项内容吗？删除后普通用户不可见，此操作不可撤销。',
    );

    if (!confirmed) {
      return;
    }

    int deletedCount = 0;
    final errors = <String>[];

    for (final id in _selectedIds.toList()) {
      final post = [..._myPosts, ..._myMarketPosts]
          .where((item) => item.id == id)
          .firstOrNull;
      if (post?.isPoll == true) {
        final deleted = await pollProvider.deletePoll(post!.pollMeta!.id);
        if (deleted) {
          deletedCount++;
          _myPosts.removeWhere((p) => p.id == id);
        } else {
          errors.add(pollProvider.mutationError(post.pollMeta!.id) ?? '删除投票失败');
        }
        continue;
      }
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
          content: Text(
            errors.isEmpty
                ? '已删除 $deletedCount 项'
                : '已删除 $deletedCount 项，${errors.first}',
          ),
          backgroundColor:
              errors.isEmpty && deletedCount > 0 ? Colors.green : Colors.red,
        ),
      );
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _isSelectionMode = false;
        });
      }
    }
  }

  Future<void> _openPostDetail(Post post, {bool isMarket = false}) async {
    await Navigator.push(
        context, buildPostDetailRoute(post, isMarket: isMarket));
    if (mounted) {
      await _loadData(silent: true);
    }
  }

  Future<void> _editPost(Post post) async {
    if (post.isPoll) {
      final updated = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (_) => PollComposerScreen(editingPost: post)));
      if (updated == true && mounted) {
        await _loadData(silent: true);
      }
      return;
    }
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: post.boardId,
          defaultPostType: post.postType,
          editingPost: post,
        ),
      ),
    );
    if (updated == true && mounted) {
      await _loadData(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    _syncSessionScope(authProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final evaluationProvider = context.watch<CourseEvaluationProvider>();
    final evaluationCount = evaluationProvider.mine.length;

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
          Positioned.fill(
            child: _buildBackground(themeProvider, isDark),
          ),
          SafeArea(
            child: Column(
              children: [
                // Tab栏
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
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
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    unselectedLabelStyle: const TextStyle(fontSize: 12),
                    dividerColor: Colors.transparent,
                    tabs: [
                      Tab(
                        text:
                            '我的帖子${_myPosts.isEmpty ? '' : ' (${_myPosts.length})'}',
                      ),
                      Tab(
                        text:
                            '我的集市${_myMarketPosts.isEmpty ? '' : ' (${_myMarketPosts.length})'}',
                      ),
                      Tab(
                        text:
                            '学科评价${evaluationCount == 0 ? '' : ' ($evaluationCount)'}',
                      ),
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
                                _buildCourseEvaluationList(isDark),
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
    if (themeProvider.shouldShowCustomBackground &&
        themeProvider.getCustomBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getCustomBackgroundImageFor(context)!;
      return Stack(
        fit: StackFit.expand,
        children: [
          ThemeProvider.isBundledAssetBackground(bgPath)
              ? Image.asset(
                  ThemeProvider.resolveBundledAssetPath(bgPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                )
              : ThemeProvider.isLocalFileBackground(bgPath)
                  ? Image.file(
                      File(bgPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    )
                  : AppCachedImage.public(
                      imageUrl: bgPath,
                      fit: BoxFit.cover,
                      memCacheWidth: 2048,
                      memCacheHeight: 2048,
                      errorWidget: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3),
          ),
        ],
      );
    }
    return _buildDefaultBackground(isDark);
  }

  Widget _buildDefaultBackground(bool isDark) {
    return ColoredBox(
      color: isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
    );
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(28),
        borderRadius: 20,
        blur: 12,
        opacity: 0.12,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: isDark ? Colors.white30 : Colors.grey[400],
            ),
            const SizedBox(height: 14),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.grey[600],
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 帖子列表 ----

  Widget _buildPostsList(List<Post> posts, bool isDark) {
    if (posts.isEmpty) {
      return _buildEmptyState(
        '暂无帖子',
        '发布你的第一条帖子吧',
        Icons.article_outlined,
        isDark,
      );
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
    if (post.isPoll && !_isSelectionMode) {
      return Column(
        children: [
          CommunityPostCard(
              post: post,
              pollVariant: PollCardVariant.profileCompact,
              onTap: () => _openPostDetail(post)),
          Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                  onPressed: () => _editPost(post),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'))),
        ],
      );
    }
    final isSelected = _selectedIds.contains(post.id);
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      onTap: _isSelectionMode
          ? () => _toggleSelect(post.id)
          : () => _openPostDetail(post),
      onLongPress: _isSelectionMode ? null : () => _onLongPressItem(post.id),
      child: Row(
        children: [
          if (_isSelectionMode) ...[
            Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelect(post.id),
              activeColor: Theme.of(context).primaryColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
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
                    Icon(
                      Icons.access_time,
                      size: 12,
                      color: isDark ? Colors.white38 : Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(post.createdAt),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (post.images.isNotEmpty) ...[
                      Icon(
                        Icons.image,
                        size: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${post.images.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.grey[500],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (!_isSelectionMode)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '编辑帖子',
                  icon: Icon(
                    Icons.edit_outlined,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                  onPressed: () => _editPost(post),
                ),
                Icon(
                  Icons.chevron_right,
                  color: isDark ? Colors.white30 : Colors.grey[400],
                ),
              ],
            ),
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
    final coverSelection = post.images.isEmpty
        ? null
        : PostMediaView.resourceForPostImage(
            post.images.first,
            const ImageDecodeTarget(width: 120, height: 120),
          );
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      onTap: _isSelectionMode
          ? () => _toggleSelect(post.id)
          : () => _openPostDetail(post, isMarket: true),
      onLongPress: _isSelectionMode ? null : () => _onLongPressItem(post.id),
      child: Row(
        children: [
          if (_isSelectionMode) ...[
            Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelect(post.id),
              activeColor: Theme.of(context).primaryColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
          ],
          // 图片缩略图
          if (post.images.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AppCachedImage.public(
                // 60dp 缩略图走状态安全的最低可用档位；大图变体 pending/failed
                // 时保持占位，不能把接口回退的 origin 当作 thumb 下载。
                imageUrl: coverSelection?.url ?? '',
                width: 60,
                height: 60,
                fit: BoxFit.cover,
                memCacheWidth: 120,
                memCacheHeight: 120,
                maxWidthDiskCache: 480,
                maxHeightDiskCache: 480,
                errorWidget: (_, __, ___) => Container(
                  width: 60,
                  height: 60,
                  color: isDark ? Colors.white12 : Colors.grey[200],
                  child: Icon(
                    Icons.image,
                    color: isDark ? Colors.white30 : Colors.grey[400],
                  ),
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
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFFF6B6B),
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
                    Icon(
                      Icons.access_time,
                      size: 12,
                      color: isDark ? Colors.white38 : Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(post.createdAt),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!_isSelectionMode)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '编辑帖子',
                  icon: Icon(
                    Icons.edit_outlined,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                  onPressed: () => _editPost(post),
                ),
                Icon(
                  Icons.chevron_right,
                  color: isDark ? Colors.white30 : Colors.grey[400],
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ---- 学科评价列表 ----

  /// 学科评价页签：cursor 分页，pending/published/needs_edit 均可打开
  /// 同一表单编辑原记录；深链定位由 _locateFocusEvaluation 完成。
  Widget _buildCourseEvaluationList(bool isDark) {
    return Consumer<CourseEvaluationProvider>(
      builder: (_, provider, __) {
        if (provider.isLoadingMine && provider.mine.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (provider.mineError != null && provider.mine.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  provider.mineError!,
                  style: TextStyle(
                    color: isDark ? Colors.white60 : Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => provider.loadMine(refresh: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试'),
                ),
              ],
            ),
          );
        }
        if (provider.mine.isEmpty) {
          return _buildEmptyState(
            '暂无学科评价',
            '从课表课程详情提交你的第一条课程评价',
            Icons.rate_review_outlined,
            isDark,
          );
        }

        return RefreshIndicator(
          onRefresh: () => provider.loadMine(refresh: true),
          child: ListView.builder(
            controller: _evaluationScrollController,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            itemCount: provider.mine.length + (provider.mineHasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= provider.mine.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: provider.isLoadingMoreMine
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton.icon(
                            onPressed: provider.loadMoreMine,
                            icon: const Icon(Icons.expand_more, size: 18),
                            label: const Text('加载更多'),
                          ),
                  ),
                );
              }
              final submission = provider.mine[index];
              return _buildCourseEvaluationItem(submission, isDark);
            },
          ),
        );
      },
    );
  }

  Widget _buildCourseEvaluationItem(
    CourseEvaluationSubmission submission,
    bool isDark,
  ) {
    final isHighlighted = submission.id == _highlightEvaluationId;
    final statusColor = switch (submission.status) {
      CourseEvaluationStatus.published => Colors.green,
      CourseEvaluationStatus.needsEdit => Colors.orange,
      CourseEvaluationStatus.pending => Colors.blue,
    };
    final statusLabel = switch (submission.status) {
      CourseEvaluationStatus.published => '已发布',
      CourseEvaluationStatus.needsEdit => '需修改',
      CourseEvaluationStatus.pending => '待审核',
    };
    final subColor = isDark ? Colors.white60 : Colors.grey[600];

    final itemKey = _evaluationItemKeys.putIfAbsent(
      submission.id,
      () => GlobalKey(),
    );

    return GlassContainer(
      key: itemKey,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      borderColor: isHighlighted
          ? Theme.of(context).primaryColor
          : (isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFECEEF1)),
      onTap: () => _editCourseEvaluation(submission),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${submission.subjectDisplayName} · ${submission.teacherDisplayName}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ...List.generate(5, (index) {
                return Icon(
                  index < submission.star ? Icons.star : Icons.star_border,
                  size: 14,
                  color: Colors.amber,
                );
              }),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '更新于 ${_formatTime(submission.updatedAt ?? submission.createdAt ?? DateTime.now())}',
                  style: TextStyle(fontSize: 12, color: subColor),
                ),
              ),
              Text(
                'v${submission.revision}',
                style: TextStyle(fontSize: 11, color: subColor),
              ),
            ],
          ),
          if (submission.comment.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              submission.comment,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black87,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (submission.status == CourseEvaluationStatus.needsEdit &&
              submission.reviewReason.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                '驳回原因：${submission.reviewReason}',
                style: TextStyle(fontSize: 12, color: statusColor, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _editCourseEvaluation(submission),
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: Text(
                submission.status == CourseEvaluationStatus.needsEdit
                    ? '修改并重新提交'
                    : '编辑',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editCourseEvaluation(CourseEvaluationSubmission submission) async {
    await CourseEvaluationFormSheet.show(
      context,
      courseName: submission.courseName,
      teacherName: submission.teacherName,
      submission: submission,
    );
    if (!mounted) return;
    // 编辑后按需刷新列表（pending → published 等状态迁移）。
    await context.read<CourseEvaluationProvider>().loadMine(refresh: true);
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
        label = '办事';
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    String title,
    String subtitle,
    IconData icon,
    bool isDark,
  ) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.grey[400],
              ),
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
