import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../models/water_section.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/water_section_provider.dart';
import '../providers/water_moderator_provider.dart';
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
  _SortOption(label: '默认排序', sort: 'all'),
  _SortOption(label: '最新发布', sort: 'time'),
  _SortOption(label: '精华内容', sort: 'featured'),
  _SortOption(label: '关注的人', sort: 'following'),
];

class _WaterCategoryFeedScreenState extends State<WaterCategoryFeedScreen> {
  final _scrollController = ScrollController();
  String _currentSort = 'all';
  int? _selectedTagId;
  WaterSection? _resolvedSection;

  @override
  void initState() {
    super.initState();
    _currentSort = _defaultSortFor(widget.section ?? _sectionFromCategory());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveSection();
      _load();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  WaterSection _sectionFromCategory() =>
      WaterSection.fromLegacyCategory(widget.category);

  Future<void> _resolveSection() async {
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
    setState(() => _resolvedSection = fresh);
  }

  WaterSection get _activeSection =>
      _resolvedSection ?? widget.section ?? _sectionFromCategory();

  String _defaultSortFor(WaterSection section) =>
      defaultSortForSection(section);

  bool get _isFollowing => _currentSort == 'following';

  Future<void> _load() {
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
    setState(() => _currentSort = sort);
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WaterSectionManageScreen(section: _activeSection),
      ),
    );
    if (!mounted) return;
    await context
        .read<WaterModeratorProvider>()
        .loadMyPermission(_activeSection.slug, forceRefresh: true);
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
    bool hasMore,
  ) {
    final showLoginPlaceholder =
        _isFollowing && !context.read<AuthProvider>().isLoggedIn;

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
        else if (isLoading && posts.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (posts.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyState(isDark))
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
            sliver: SliverList.separated(
              itemCount: posts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 0),
              itemBuilder: (context, index) {
                final post = posts[index];
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

  Widget _buildHeader(bool isDark) {
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);
    final icon = iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final subtitle =
        section.subtitle.isNotEmpty ? section.subtitle : widget.category.hint;
    final tagShowcase = section.enabledTags.take(5).toList();
    final fallbackQuick =
        tagShowcase.isEmpty ? widget.category.quickTags : const <String>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Color.alphaBlend(
                      categoryColor.withValues(alpha: 0.22),
                      const Color(0xFF171B24),
                    ),
                    const Color(0xFF171B24),
                  ]
                : [
                    categoryColor.withValues(alpha: 0.12),
                    Colors.white,
                  ],
          ),
          border: Border.all(
            color: categoryColor.withValues(alpha: isDark ? 0.22 : 0.15),
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: categoryColor.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: categoryColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: categoryColor, size: 24),
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
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color:
                              isDark ? Colors.white : const Color(0xFF16181D),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color:
                              isDark ? Colors.white60 : const Color(0xFF6D7480),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (tagShowcase.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tagShowcase.map((tag) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color:
                          categoryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '#${tag.name}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: categoryColor,
                      ),
                    ),
                  );
                }).toList(),
              )
            else if (fallbackQuick.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: fallbackQuick.map((tag) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color:
                          categoryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '#$tag',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: categoryColor,
                      ),
                    ),
                  );
                }).toList(),
              ),
            if (section.noticeText.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: categoryColor.withValues(alpha: isDark ? 0.10 : 0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 15, color: categoryColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        section.noticeText,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          color: isDark ? Colors.white70 : categoryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTagBar(bool isDark) {
    final section = _activeSection;
    final tags = section.enabledTags;
    final categoryColor = _sectionColor(section, isDark);
    final currentSortLabel = _sortOptions
        .firstWhere((o) => o.sort == _currentSort,
            orElse: () => _sortOptions.first)
        .label;
    return Container(
      color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171B24) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEFF3),
          ),
        ),
        child: Row(
          children: [
            Expanded(
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
            const SizedBox(width: 4),
            _buildSortMenuButton(currentSortLabel, categoryColor, isDark),
            const SizedBox(width: 6),
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

  Widget _buildSortMenuButton(String label, Color color, bool isDark) {
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 16, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final section = _activeSection;
    final categoryColor = _sectionColor(section, isDark);
    final icon = iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final labelTitle =
        section.title.isNotEmpty ? section.title : widget.category.label;
    final emptyTitle = section.emptyTitle.isNotEmpty
        ? section.emptyTitle
        : '还没有「$labelTitle」相关帖子';
    final emptyDesc = section.emptyDescription.isNotEmpty
        ? section.emptyDescription
        : widget.category.emptyLeadText;
    final publishLabel = section.publishActionText.isNotEmpty
        ? section.publishActionText
        : widget.category.publishActionText;
    final starterQuestions = section.starterQuestions.isNotEmpty
        ? section.starterQuestions
        : widget.category.starterQuestions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
      child: Column(
        children: [
          _buildPrimaryEmptyCard(
              isDark, categoryColor, icon, emptyTitle, emptyDesc, publishLabel),
          const SizedBox(height: 12),
          _buildStarterQuestionCard(isDark, categoryColor, starterQuestions),
        ],
      ),
    );
  }

  Widget _buildPrimaryEmptyCard(
    bool isDark,
    Color categoryColor,
    IconData icon,
    String emptyTitle,
    String emptyDesc,
    String publishLabel,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: categoryColor.withValues(alpha: 0.12),
            ),
            child: Icon(icon, size: 30, color: categoryColor),
          ),
          const SizedBox(height: 15),
          Text(
            emptyTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            emptyDesc,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    onPressed: _openComposer,
                    icon: const Icon(Icons.edit_rounded, size: 17),
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
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _showPostTips,
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 17),
                    label: const Text(
                      '发帖建议',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: categoryColor,
                      side: BorderSide(
                        color: categoryColor.withValues(alpha: 0.30),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStarterQuestionCard(
    bool isDark,
    Color categoryColor,
    List<String> starterQuestions,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '常见方向',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '不知道发什么，可以从这些开始',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
          const SizedBox(height: 12),
          if (starterQuestions.isEmpty)
            Text(
              '还没有常见方向，可以补充。',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: starterQuestions.map((question) {
                return Container(
                  constraints: const BoxConstraints(maxWidth: 190),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        categoryColor.withValues(alpha: isDark ? 0.14 : 0.08),
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
      ),
    );
  }

  void _showPostTips() {
    final section = _activeSection;
    final fallback = widget.category;
    final categoryColor = section.colorHex.isNotEmpty
        ? colorHexToColor(section.colorHex)
        : fallback.color;
    final starterQuestions = section.starterQuestions.isNotEmpty
        ? section.starterQuestions
        : fallback.starterQuestions;
    final publishLabel = section.publishActionText.isNotEmpty
        ? section.publishActionText
        : fallback.publishActionText;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.18)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '可以发什么？',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : const Color(0xFF20232A),
                  ),
                ),
                const SizedBox(height: 14),
                for (final question in starterQuestions) ...[
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: categoryColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          question,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF374151),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _openComposer();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: categoryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(
                      publishLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
  double get minExtent => 50;

  @override
  double get maxExtent => 50;

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
