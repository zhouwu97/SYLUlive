import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../models/water_section.dart';
import '../models/water_section_my_level.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/water_section_provider.dart';
import '../providers/water_moderator_provider.dart';
import '../widgets/pinned_post_summary_bar.dart';
import '../widgets/water_section/section_filter_header.dart';
import '../widgets/water_section/section_hero_header.dart';
import '../widgets/water_section/section_post_card.dart';
import '../widgets/water_section/section_tab_bar.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';
import 'water_section_manage_screen.dart';
import 'login_screen.dart';
import 'chat_list_screen.dart';

class WaterCategoryFeedScreen extends StatefulWidget {
  final WaterPostCategory category;
  final WaterSection? section;

  const WaterCategoryFeedScreen({
    super.key,
    required this.category,
    this.section,
  });

  @override
  State<WaterCategoryFeedScreen> createState() =>
      _WaterCategoryFeedScreenState();
}

class _WaterCategoryFeedScreenState extends State<WaterCategoryFeedScreen> {
  ScrollController? _sheetScrollController;
  String _currentSort = 'all';
  int? _selectedTagId;
  WaterSection? _resolvedSection;
  bool _sectionReady = false;
  bool _sortTouched = false;
  int _loadSerial = 0;
  WaterSectionMyLevel? _myLevel;

  @override
  void initState() {
    super.initState();
    _currentSort = _defaultSortFor(widget.section ?? _sectionFromCategory());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  @override
  void dispose() {
    // _sheetScrollController 由 DraggableScrollableSheet 管理，不需要手动 dispose
    super.dispose();
  }

  WaterSection _sectionFromCategory() =>
      WaterSection.fromLegacyCategory(widget.category);

  Future<void> _bootstrap() async {
    await _resolveSection(updateSortFromFreshSection: true);
    if (!mounted) return;
    await _loadMyLevel();
    if (!mounted) return;
    await _load();
  }

  Future<void> _resolveSection(
      {bool updateSortFromFreshSection = false}) async {
    final provider = context.read<WaterSectionProvider>();
    final moderatorProvider = context.read<WaterModeratorProvider>();
    if (provider.sections.isEmpty && !provider.isLoading) {
      await provider.loadSections();
    }
    if (!mounted) return;
    // 进入版块页时强制刷新权限，避免切号或罢免后残留管理入口。
    final slug = widget.section?.slug ?? widget.category.value;
    await moderatorProvider.loadMyPermission(slug, forceRefresh: true);
    final fresh =
        provider.getBySlug(slug) ?? widget.section ?? _sectionFromCategory();
    if (!mounted) return;
    setState(() {
      _resolvedSection = fresh;
      _sectionReady = true;
      if (updateSortFromFreshSection && !_sortTouched) {
        _currentSort = _defaultSortFor(fresh);
      }
      if (_selectedTagId != null &&
          !fresh.enabledTags.any((tag) => tag.id == _selectedTagId)) {
        _selectedTagId = null;
      }
    });
  }

  WaterSection get _activeSection =>
      _resolvedSection ?? widget.section ?? _sectionFromCategory();

  String _defaultSortFor(WaterSection section) =>
      defaultSortForSection(section);

  Future<void> _load() async {
    final serial = ++_loadSerial;
    final section = _activeSection;
    final sort = _currentSort;
    final tagId = _selectedTagId;
    await context.read<PostProvider>().loadPosts(
          boardId: 1,
          sort: sort,
          type: section.slug,
          tagId: tagId,
        );
    if (!mounted || serial != _loadSerial) return;
  }

  Future<void> _loadMyLevel() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      if (_myLevel != null && mounted) {
        setState(() => _myLevel = null);
      }
      return;
    }
    final service = context.read<WaterSectionProvider>().service;
    if (service == null) return;
    final slug = _activeSection.slug;
    try {
      final level = await service.fetchMyLevel(slug);
      if (!mounted || slug != _activeSection.slug) return;
      setState(() => _myLevel = level);
    } catch (e) {
      debugPrint('加载我的版块等级失败: $e');
    }
  }

  Future<void> _refresh() {
    final section = _activeSection;
    return Future.wait([
      _loadMyLevel(),
      context.read<PostProvider>().refresh(
            boardId: 1,
            sort: _currentSort,
            type: section.slug,
            tagId: _selectedTagId,
          ),
    ]).then((_) {});
  }

  Future<void> _loadMore() {
    final section = _activeSection;
    return context.read<PostProvider>().loadPosts(
          boardId: 1,
          sort: _currentSort,
          type: section.slug,
          tagId: _selectedTagId,
        );
  }

  Future<void> _changeSort(String sort) async {
    if (sort == _currentSort) return;
    setState(() {
      _currentSort = sort;
      _sortTouched = true;
    });
    if (_sheetScrollController?.hasClients == true) {
      _sheetScrollController!.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    await _load();
  }

  Future<void> _changeTag(int? tagId) async {
    final newTagId = (tagId == _selectedTagId) ? null : tagId;
    if (newTagId == _selectedTagId) return;
    setState(() => _selectedTagId = newTagId);
    await _load();
  }

  Future<void> _openComposer() async {
    final section = _activeSection;
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: 1,
          defaultPostType: section.slug,
        ),
      ),
    );
    if (published == true && mounted) {
      await _loadMyLevel();
      if (!mounted) return;
      await _refresh();
    }
  }

  Future<void> _openManageScreen() async {
    final slug = _activeSection.slug;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WaterSectionManageScreen(section: _activeSection),
      ),
    );
    if (!mounted) return;
    final fresh =
        await context.read<WaterSectionProvider>().refreshSection(slug);
    if (!mounted) return;
    if (fresh != null) {
      setState(() {
        _resolvedSection = fresh;
        if (_selectedTagId != null &&
            !fresh.enabledTags.any((tag) => tag.id == _selectedTagId)) {
          _selectedTagId = null;
        }
      });
    }
    await context
        .read<WaterModeratorProvider>()
        .loadMyPermission(slug, forceRefresh: true);
  }

  Widget _buildManageAction(bool isDark) {
    final slug = _activeSection.slug;
    final perm = context.watch<WaterModeratorProvider>().permissionOf(slug);
    if (!perm.isGlobalAdmin && !perm.canEditSection) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: _openManageScreen,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.tune_rounded,
          size: 18,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildNoticeBar(WaterSection section, bool isDark) {
    final text = section.noticeText.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    // Use the first non-empty line as the title
    final title = text
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '版主公告');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('版主公告',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                  child: Text(text, style: const TextStyle(fontSize: 14))),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        },
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1F1C14) : const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  color: isDark ? const Color(0xFF332A12) : const Color(0xFFFFEDBA),
                ),
                child: Text(
                  '公告',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFFFFD45E) : const Color(0xFFB37B00),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? const Color(0xFFFFEAB3) : const Color(0xFF8A5F00),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: isDark ? Colors.white38 : const Color(0xFFCC9933),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPost(Post post) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(
          postId: post.id,
          initialPost: post,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  Future<void> _toggleFollowSection() async {
    final section = _activeSection;
    final isFollowed = section.isFollowed;
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录')),
      );
      return;
    }
    final provider = context.read<WaterSectionProvider>();
    final postProvider = context.read<PostProvider>();
    try {
      await provider.toggleFollow(section.slug, !isFollowed);
      postProvider.invalidateFollowingFeed();
      await _resolveSection();
      if (mounted) {
        await _refresh();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(!isFollowed ? '已关注' : '已取消关注')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);

    return Scaffold(
      backgroundColor: background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Layer 1: Hero（背景 + 版块信息 + 等级 + 频道卡）──
              SectionHeroHeader(
                section: section,
                accentColor: categoryColor,
                isFollowing: section.isFollowed,
                isLoggedIn: context.read<AuthProvider>().isLoggedIn,
                onToggleFollow: _toggleFollowSection,
              ),

              // ── Layer 2: 顶部操作栏（返回 / 管理 / 发帖）──
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: _buildTopActionsBar(categoryColor, isDark),
                ),
              ),

              // ── Layer 3: 可拖拽圆角内容板 ──
              _buildContentSheet(section, categoryColor, isDark),

              // ── Layer 4: 悬浮按钮组 ──
              Positioned(
                right: 20,
                bottom: 24 + MediaQuery.paddingOf(context).bottom,
                child: _buildFloatingActions(categoryColor, isDark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部操作栏：返回、管理、发帖
  Widget _buildTopActionsBar(Color categoryColor, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _buildBackButton(),
          const Spacer(),
          _buildManageAction(isDark),
          _buildMessageAction(),
        ],
      ),
    );
  }

  /// DraggableScrollableSheet：圆角白板 + 排序/标签/帖子列表
  ///
  /// 状态语义：
  /// - 默认 [initialChildSize=0.66]：内容板盖上来，顶部约在屏幕 34% 处，
  ///   刚好压到 Hero 的等级卡/关注下面，不露大面积空背景。
  /// - 下拉 [minChildSize=0.24]：内容板收起到底部一小截，完整展示上方
  ///   版块背景和 Hero 头部内容（含频道卡）。
  /// - 上拉 [maxChildSize=0.94]：内容板展开到接近全屏，分类栏吸顶刷帖子。
  Widget _buildContentSheet(
      WaterSection section, Color categoryColor, bool isDark) {
    // sheet 用略亮的暗色当作 elevated surface，与 background 0xFF0D1117 区分
    final sheetColor = isDark ? const Color(0xFF171B24) : Colors.white;

    final hasCover = section.mobileCoverUrl.isNotEmpty;
    final initialChildSize = 0.66;
    final minChildSize = hasCover ? 0.24 : 0.66;
    final snapSizes = hasCover ? const [0.24, 0.66, 0.94] : const [0.66, 0.94];

    return DraggableScrollableSheet(
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: 0.94,
      snap: true,
      snapSizes: snapSizes,
      builder: (context, scrollController) {
        // 存储 scrollController 供 _changeSort 滚动到顶部使用
        _sheetScrollController = scrollController;

        return Container(
          // 关键：clipBehavior 让内部 pinned header 的纯色背景
          // 被裁剪在外层圆角内，避免覆盖圆角造成“上方是方的”视觉问题
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: sheetColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(32),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Selector<
              PostProvider,
              ({
                List<Post> posts,
                bool isLoading,
                bool hasLoaded,
                bool hasMore,
                int revision
              })>(
            selector: (context, provider) => (
              posts: provider.postsFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              ),
              isLoading: provider.isLoadingFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              ),
              hasLoaded: provider.hasLoadedFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              ),
              hasMore: provider.hasMoreFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              ),
              revision: provider.revisionFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              ),
            ),
            builder: (context, data, _) => _buildSheetContent(
              scrollController,
              isDark,
              data.posts,
              data.isLoading,
              data.hasLoaded,
              data.hasMore,
              categoryColor,
              section,
            ),
          ),
        );
      },
    );
  }

  /// sheet 内部：CustomScrollView + slivers
  Widget _buildSheetContent(
    ScrollController scrollController,
    bool isDark,
    List<Post> posts,
    bool isLoading,
    bool hasLoaded,
    bool hasMore,
    Color categoryColor,
    WaterSection section,
  ) {
    final pinnedPosts = posts.where((post) {
      return post.waterSectionPinned || post.isActivePinned;
    }).toList();

    final normalPosts = posts.where((post) {
      return !post.waterSectionPinned && !post.isActivePinned;
    }).toList();

    return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 360) {
            final provider = context.read<PostProvider>();
            final isLoadingNow = provider.isLoadingFor(
              1,
              sort: _currentSort,
              type: section.slug,
              tagId: _selectedTagId,
            );
            final hasMoreNow = provider.hasMoreFor(
              1,
              sort: _currentSort,
              type: section.slug,
              tagId: _selectedTagId,
            );
            if (!isLoadingNow && hasMoreNow) {
              _loadMore();
            }
          }
          return false;
        },
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            // 吸顶：小横条 + 排序/标签单行筛选
            SliverPersistentHeader(
              pinned: true,
              delegate: _SheetPinnedHeaderDelegate(
                height: 68,
                child: _buildSheetPinnedHeader(isDark, categoryColor, section),
              ),
            ),

            // body
            if (!_sectionReady ||
                (!hasLoaded && posts.isEmpty) ||
                (isLoading && posts.isEmpty))
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildLoadingState(isDark),
              )
            else if (pinnedPosts.isEmpty &&
                normalPosts.isEmpty &&
                section.noticeText.trim().isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(isDark),
              )
            else ...[
              if (section.noticeText.trim().isNotEmpty)
                SliverToBoxAdapter(
                  child: _buildNoticeBar(section, isDark),
                ),
              if (pinnedPosts.isNotEmpty)
                SliverToBoxAdapter(
                  child: PinnedPostSummaryBar(
                    posts: pinnedPosts,
                    isDark: isDark,
                    label: '置顶',
                    onOpenPost: _openPost,
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 128),
                sliver: SliverList.separated(
                  itemCount: normalPosts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 0),
                  itemBuilder: (context, index) {
                    final post = normalPosts[index];
                    return SectionPostCard(
                      post: post,
                      section: section,
                      accentColor: categoryColor,
                      onTap: () => _openPost(post),
                    );
                  },
                ),
              ),
              if (isLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 128),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (!hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 128),
                    child: Center(
                      child: Text(
                        '已经到底了',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.white38 : const Color(0xFF9AA0A6),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
  }

  /// sheet 吸顶头部：小横条 + 单行筛选栏
  ///
  /// 注意：颜色必须与 sheetColor 保持一致（dark: 0xFF171B24），否则
  /// 吸顶时白色块会与 sheet 圆角形成色差，看起来像两块拼接。
  /// 圆角由外层 Container 的 clipBehavior 负责，这里用纯色填充即可。
  Widget _buildSheetPinnedHeader(
      bool isDark, Color categoryColor, WaterSection section) {
    return Container(
      color: isDark ? const Color(0xFF171B24) : Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 38,
              height: 5,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.18)
                    : const Color(0xFFD9DDE5),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SectionFilterHeader(
            sortOptions: kSectionFeedSortOptions,
            currentSort: _currentSort,
            section: section,
            selectedTagId: _selectedTagId,
            accentColor: categoryColor,
            isDark: isDark,
            onSortChanged: _changeSort,
            onTagChanged: _changeTag,
          ),
          // 底部分隔线
          Container(
            height: 1,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : const Color(0xFFEDEFF3),
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 16,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildMessageAction() {
    return GestureDetector(
      onTap: () {
        final auth = context.read<AuthProvider>();
        if (!auth.isLoggedIn) {
          Navigator.push(
            context,
            PageRouteBuilder(
              opaque: false,
              pageBuilder: (_, __, ___) => const LoginScreen(),
            ),
          );
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.mail_outline_rounded,
          size: 18,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildFloatingActions(Color categoryColor, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: null,
          onPressed: _refresh,
          backgroundColor: isDark ? const Color(0xFF2C2F36) : Colors.white,
          foregroundColor: isDark ? Colors.white70 : Colors.black54,
          elevation: 4,
          child: const Icon(Icons.refresh_rounded, size: 20),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: null,
          onPressed: _openComposer,
          backgroundColor: categoryColor,
          foregroundColor: Colors.white,
          elevation: 4,
          child: const Icon(Icons.add_rounded, size: 28),
        ),
      ],
    );
  }

  Color _sectionColor(WaterSection section, bool isDark) {
    if (section.colorHex.isNotEmpty && section.colorHex != '#') {
      return colorHexToColor(section.colorHex);
    }
    return widget.category.color;
  }

  Color _mutedText(bool isDark) =>
      isDark ? Colors.white54 : const Color(0xFF8A93A3);

  Color _primaryText(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF151922);

  BoxDecoration _surfaceDecoration(bool isDark, {double radius = 18}) {
    return BoxDecoration(
      color: isDark ? const Color(0xFF171B24) : Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFEDEFF3),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);
    final icon = iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final emptyTitle = _emptyTitleFor(section);
    final emptyDesc = _emptyDescriptionFor(section);
    final publishLabel = section.publishActionText.isNotEmpty
        ? section.publishActionText
        : widget.category.publishActionText;
    final starterQuestions = section.starterQuestions.isNotEmpty
        ? section.starterQuestions
        : widget.category.starterQuestions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 96),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          decoration: _surfaceDecoration(isDark),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: categoryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                ),
                child: Icon(icon, size: 23, color: categoryColor),
              ),
              const SizedBox(height: 13),
              Text(
                emptyTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: _primaryText(isDark),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                emptyDesc,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: _mutedText(isDark),
                ),
              ),
              const SizedBox(height: 17),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: FilledButton.icon(
                  onPressed: _openComposer,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: Text(
                    publishLabel,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: categoryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              if (starterQuestions.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: starterQuestions.take(4).map((question) {
                    return Container(
                      constraints: const BoxConstraints(maxWidth: 190),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: categoryColor.withValues(
                            alpha: isDark ? 0.14 : 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        question,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: categoryColor,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _emptyTitleFor(WaterSection section) {
    switch (section.slug) {
      case 'freshman_help':
        return '还没有相关问题';
      case 'competition':
        return '还没有竞赛内容';
      case 'campus_life':
        return '这里还没有内容';
      default:
        if (section.emptyTitle.isNotEmpty &&
            !section.emptyTitle.contains('相关帖子')) {
          return section.emptyTitle;
        }
        return '这里还没有内容';
    }
  }

  String _emptyDescriptionFor(WaterSection section) {
    switch (section.slug) {
      case 'freshman_help':
        return '可以先问宿舍、报到、校园卡、军训这些新生最容易卡住的事。';
      case 'competition':
        return '可以发通知、找队友、写经验，也可以问学校认不认。';
      case 'campus_life':
        return '可以分享食堂、宿舍、校园卡、随手拍或校园见闻。';
      default:
        if (section.emptyDescription.isNotEmpty) {
          return section.emptyDescription;
        }
        return widget.category.emptyLeadText;
    }
  }

  Widget _buildLoadingState(bool isDark) {
    return Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: isDark ? Colors.white70 : null,
        ),
      ),
    );
  }
}

/// sheet 吸顶头部 delegate：小横条 + 单行筛选栏固定在面板顶部
class _SheetPinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _SheetPinnedHeaderDelegate({
    required this.height,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _SheetPinnedHeaderDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}
