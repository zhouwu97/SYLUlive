import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../models/water_section.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/water_section_provider.dart';
import '../providers/water_moderator_provider.dart';
import '../widgets/pinned_post_summary_bar.dart';
import '../widgets/post_card.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';
import 'water_section_manage_screen.dart';

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

class _SortOption {
  final String label;
  final String sort;
  const _SortOption({required this.label, required this.sort});
}

const _sortOptions = [
  _SortOption(label: '综合', sort: 'all'),
  _SortOption(label: '最新', sort: 'time'),
  _SortOption(label: '精华', sort: 'featured'),
  _SortOption(label: '关注', sort: 'following'),
];

class _WaterCategoryFeedScreenState extends State<WaterCategoryFeedScreen> {
  final _scrollController = ScrollController();
  String _currentSort = 'all';
  int? _selectedTagId;
  WaterSection? _resolvedSection;
  bool _sectionReady = false;
  bool _sortTouched = false;
  int _loadSerial = 0;

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
    _scrollController.dispose();
    super.dispose();
  }

  WaterSection _sectionFromCategory() =>
      WaterSection.fromLegacyCategory(widget.category);

  Future<void> _bootstrap() async {
    await _resolveSection(updateSortFromFreshSection: true);
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

  bool get _isFollowing => _currentSort == 'following';

  Future<void> _load() async {
    if (_isFollowing && !context.read<AuthProvider>().isLoggedIn) {
      return;
    }
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

  Future<void> _refresh() {
    if (_isFollowing && !context.read<AuthProvider>().isLoggedIn) {
      return Future.value();
    }
    final section = _activeSection;
    return context.read<PostProvider>().refresh(
          boardId: 1,
          sort: _currentSort,
          type: section.slug,
          tagId: _selectedTagId,
        );
  }

  Future<void> _loadMore() {
    if (_isFollowing && !context.read<AuthProvider>().isLoggedIn) {
      return Future.value();
    }
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
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    await _load();
  }

  Future<void> _changeTag(int? tagId) async {
    if (tagId == _selectedTagId) return;
    setState(() => _selectedTagId = tagId);
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
    if (!perm.isGlobalAdmin && !perm.isModerator) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: TextButton.icon(
        onPressed: _openManageScreen,
        icon: Icon(Icons.admin_panel_settings_rounded,
            size: 16, color: Theme.of(context).colorScheme.primary),
        label: Text(
          '管理',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);
    final title =
        section.title.isNotEmpty ? section.title : widget.category.label;
    final publishLabel = section.publishActionText.isNotEmpty
        ? section.publishActionText
        : widget.category.publishActionText;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0D1117) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          // 管理员 / 超管可以看到管理入口
          _buildManageAction(isDark),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _openComposer,
              style: TextButton.styleFrom(
                foregroundColor: categoryColor,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: Text(publishLabel),
            ),
          ),
        ],
      ),
      floatingActionButton: null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 360) {
              final provider = context.read<PostProvider>();
              final section = _activeSection;
              final isLoading = provider.isLoadingFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              );
              final hasMore = provider.hasMoreFor(
                1,
                sort: _currentSort,
                type: section.slug,
                tagId: _selectedTagId,
              );
              if (!isLoading && hasMore) {
                _loadMore();
              }
            }
            return false;
          },
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
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
                builder: (context, data, _) => _buildScrollContent(
                  isDark,
                  data.posts,
                  data.isLoading,
                  data.hasLoaded,
                  data.hasMore,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollContent(
    bool isDark,
    List<Post> posts,
    bool isLoading,
    bool hasLoaded,
    bool hasMore,
  ) {
    final showLoginPlaceholder =
        _isFollowing && !context.read<AuthProvider>().isLoggedIn;

    final pinnedPosts = posts.where((post) {
      return post.waterSectionPinned || post.isActivePinned;
    }).toList();

    final normalPosts = posts.where((post) {
      return !post.waterSectionPinned && !post.isActivePinned;
    }).toList();

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(isDark)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _WaterCategoryTabHeader(
            isDark: isDark,
            child: _buildTagBar(isDark),
          ),
        ),
        if (showLoginPlaceholder)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildFollowingPlaceholder(isDark),
          )
        else if (!_sectionReady ||
            (!hasLoaded && posts.isEmpty) ||
            (isLoading && posts.isEmpty))
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildLoadingState(isDark),
          )
        else if (pinnedPosts.isEmpty && normalPosts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(isDark),
          )
        else ...[
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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
            sliver: SliverList.separated(
              itemCount: normalPosts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 0),
              itemBuilder: (context, index) {
                final post = normalPosts[index];
                return PostCard(
                  post: post,
                  showCategoryBadge: false,
                  onTap: () => _openPost(post),
                );
              },
            ),
          ),
          if (isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 96),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (!hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 96),
                child: Center(
                  child: Text(
                    '已经到底了',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A6),
                    ),
                  ),
                ),
              ),
            ),
        ],
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

  Widget _buildHeader(bool isDark) {
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);
    final icon = iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final subtitle =
        section.subtitle.isNotEmpty ? section.subtitle : widget.category.hint;
    final tagCount = section.enabledTags.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: _surfaceDecoration(isDark),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: categoryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: categoryColor, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title.isNotEmpty
                        ? section.title
                        : widget.category.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: _primaryText(isDark),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: _mutedText(isDark),
                    ),
                  ),
                ],
              ),
            ),
            if (tagCount > 0) ...[
              const SizedBox(width: 10),
              _buildSmallMeta('$tagCount 个标签', isDark),
            ],
            const SizedBox(width: 10),
            _buildFollowButton(section, categoryColor, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildFollowButton(WaterSection section, Color color, bool isDark) {
    final isFollowed = section.isFollowed;
    final isLoggedIn = context.read<AuthProvider>().isLoggedIn;
    return GestureDetector(
      onTap: () async {
        if (!isLoggedIn) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先登录')),
          );
          return;
        }
        final provider = context.read<WaterSectionProvider>();
        try {
          await provider.toggleFollow(section.slug, !isFollowed);
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
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isFollowed
              ? (isDark ? Colors.white10 : const Color(0xFFF4F6F8))
              : color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          isFollowed ? '已关注' : '关注',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isFollowed ? _mutedText(isDark) : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildSmallMeta(String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF4F6F8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _mutedText(isDark),
        ),
      ),
    );
  }

  Widget _buildTagBar(bool isDark) {
    final section = _activeSection;
    final tags = section.enabledTags;
    final categoryColor = _sectionColor(section, isDark);
    return Container(
      color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Container(
        height: 42,
        decoration: _surfaceDecoration(isDark, radius: 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              right: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                itemCount: tags.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 4),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildTagChip(
                      '全部',
                      _selectedTagId == null,
                      categoryColor,
                      isDark,
                      onTap: () => _changeTag(null),
                    );
                  }
                  final tag = tags[index - 1];
                  return _buildTagChip(
                    tag.name,
                    _selectedTagId == tag.id,
                    categoryColor,
                    isDark,
                    onTap: () => _changeTag(tag.id),
                  );
                },
              ),
            ),
            Positioned(
              top: 3,
              right: 4,
              child: _buildSortMenuButton(categoryColor, isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagChip(
    String label,
    bool selected,
    Color color,
    bool isDark, {
    required VoidCallback onTap,
  }) {
    final foreground = selected
        ? color
        : isDark
            ? Colors.white60
            : const Color(0xFF667085);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: isDark ? 0.18 : 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSortMenuButton(Color color, bool isDark) {
    final isDefaultSort = _currentSort == 'all';
    return PopupMenuButton<String>(
      tooltip: '排序',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (context) => _sortOptions
          .map((o) => PopupMenuItem<String>(
                value: o.sort,
                child: Row(
                  children: [
                    Icon(
                      _currentSort == o.sort
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 16,
                      color: _currentSort == o.sort ? color : null,
                    ),
                    const SizedBox(width: 8),
                    Text(o.label),
                  ],
                ),
              ))
          .toList(),
      onSelected: (v) => _changeSort(v),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.14 : 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Icon(Icons.tune_rounded, size: 18, color: color),
                ),
              ),
            ),
            if (!isDefaultSort)
              Positioned(
                top: 7,
                right: 7,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
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

  Widget _buildFollowingPlaceholder(bool isDark) {
    final section = _activeSection;
    final categoryColor = section.colorHex.isNotEmpty
        ? colorHexToColor(section.colorHex)
        : widget.category.color;
    final label =
        section.title.isNotEmpty ? section.title : widget.category.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171B24) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFEDEFF3),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: categoryColor.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 30,
                  color: categoryColor,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '登录后查看关注内容',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '关注你感兴趣的同学后，这里会显示他们在「$label」里的帖子。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaterCategoryTabHeader extends SliverPersistentHeaderDelegate {
  final bool isDark;
  final Widget child;

  _WaterCategoryTabHeader({required this.isDark, required this.child});

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _WaterCategoryTabHeader oldDelegate) {
    return oldDelegate.isDark != isDark || oldDelegate.child != child;
  }
}
