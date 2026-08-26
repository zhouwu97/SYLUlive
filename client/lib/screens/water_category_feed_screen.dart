import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../models/water_section.dart';
import '../models/water_section_my_level.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/water_moderator_provider.dart';
import '../providers/water_section_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/post_route.dart';
import '../widgets/community_post_card.dart';
import '../widgets/pinned_post_summary_bar.dart';
import '../widgets/poll/poll_post_card.dart';
import '../widgets/post_card.dart';
import '../widgets/water_section/section_filter_header.dart';
import '../widgets/water_section/section_floating_dock.dart';
import '../widgets/water_section/section_post_card.dart';
import '../widgets/water_section/section_avatar.dart';
import 'create_post_screen.dart';
import 'water_section_manage_screen.dart';

class WaterCategoryFeedScreen extends StatefulWidget {
  final WaterPostCategory category;
  final WaterSection? section;
  final String? initialFilterKey;

  const WaterCategoryFeedScreen({
    super.key,
    required this.category,
    this.section,
    this.initialFilterKey,
  });

  @override
  State<WaterCategoryFeedScreen> createState() =>
      _WaterCategoryFeedScreenState();
}

class _WaterCategoryFeedScreenState extends State<WaterCategoryFeedScreen> {
  late final ScrollController _scrollController;
  String _selectedFilterKey = 'mode:recommend';
  WaterSection? _resolvedSection;
  bool _sectionReady = false;
  bool _sortTouched = false;
  int _loadSerial = 0;
  WaterSectionMyLevel? _myLevel;
  bool _isRefreshing = false;
  bool _isCompact = false;
  bool _fabVisible = true;
  double? _lastScrollOffset;
  double _downwardScroll = 0;
  bool? _optimisticIsFollowed;
  bool _followPending = false;
  int _myLevelRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    if (widget.section != null) {
      _resolvedSection = widget.section;
      _sectionReady = true;
    }
    if (widget.initialFilterKey != null &&
        _isSupportedFilterKey(widget.initialFilterKey!)) {
      _selectedFilterKey = widget.initialFilterKey!;
    } else {
      _selectedFilterKey = _filterKeyForSort(
        _defaultSortFor(widget.section ?? _sectionFromCategory()),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _myLevelRequestGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  WaterSection _sectionFromCategory() =>
      WaterSection.fromLegacyCategory(widget.category);

  WaterSection get _activeSection =>
      _resolvedSection ?? widget.section ?? _sectionFromCategory();

  String _defaultSortFor(WaterSection section) =>
      defaultSortForSection(section);

  String _filterKeyForSort(String sort) {
    switch (sort) {
      case 'time':
        return 'mode:latest';
      case 'featured':
        return 'mode:featured';
      default:
        return 'mode:recommend';
    }
  }

  bool _isSupportedFilterKey(String key) {
    return key == 'mode:recommend' ||
        key == 'mode:latest' ||
        key == 'mode:featured' ||
        key.startsWith('tag:');
  }

  MapEntry<String, int?> _resolveFilterKey(String key) {
    if (key == 'mode:latest') return const MapEntry('time', null);
    if (key == 'mode:featured') return const MapEntry('featured', null);
    if (key.startsWith('tag:')) {
      return MapEntry('all', int.tryParse(key.substring(4)));
    }
    return const MapEntry('all', null);
  }

  Future<void> _bootstrap() async {
    if (_sectionReady) {
      await Future.wait<void>([
        _load(),
        _loadMyLevel(),
        _resolveSection(),
      ]);
      return;
    }
    await _resolveSection(updateSortFromFreshSection: true);
    if (!mounted) return;
    await Future.wait<void>([_load(), _loadMyLevel()]);
  }

  Future<void> _resolveSection(
      {bool updateSortFromFreshSection = false}) async {
    final provider = context.read<WaterSectionProvider>();
    final moderatorProvider = context.read<WaterModeratorProvider>();
    if (provider.sections.isEmpty && !provider.isLoading) {
      await provider.loadSections();
    }
    if (!mounted) return;
    final slug = widget.section?.slug ?? widget.category.value;
    await moderatorProvider.loadMyPermission(slug, forceRefresh: true);
    final fresh =
        provider.getBySlug(slug) ?? widget.section ?? _sectionFromCategory();
    if (!mounted) return;
    setState(() {
      _resolvedSection = fresh;
      _sectionReady = true;
      if (updateSortFromFreshSection && !_sortTouched) {
        _selectedFilterKey = _filterKeyForSort(_defaultSortFor(fresh));
      }
      if (_selectedFilterKey.startsWith('tag:')) {
        final tagId = int.tryParse(_selectedFilterKey.substring(4));
        if (tagId != null && !fresh.enabledTags.any((tag) => tag.id == tagId)) {
          _selectedFilterKey = 'mode:recommend';
        }
      }
    });
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    final section = _activeSection;
    final filter = _resolveFilterKey(_selectedFilterKey);
    await context.read<PostProvider>().refresh(
          boardId: 1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        );
    if (!mounted || serial != _loadSerial) return;
  }

  Future<void> _loadMyLevel() async {
    final auth = context.read<AuthProvider>();
    final requestGeneration = ++_myLevelRequestGeneration;
    if (!auth.isLoggedIn) {
      if (_myLevel != null && mounted) setState(() => _myLevel = null);
      return;
    }
    final accountId = auth.user?.id;
    final accountSessionEpoch = auth.accountSessionEpoch;
    final sectionSlug = _activeSection.slug;
    if (accountId == null || accountId <= 0) return;
    final service = context.read<WaterSectionProvider>().service;
    if (service == null) return;
    try {
      final level = await service.fetchMyLevel(sectionSlug);
      if (mounted &&
          requestGeneration == _myLevelRequestGeneration &&
          sectionSlug == _activeSection.slug &&
          _sameAccountSession(auth, accountId, accountSessionEpoch)) {
        setState(() => _myLevel = level);
      }
    } catch (error) {
      if (requestGeneration == _myLevelRequestGeneration &&
          _sameAccountSession(auth, accountId, accountSessionEpoch)) {
        debugPrint('加载我的版块等级失败: $error');
      }
    }
  }

  bool _sameAccountSession(
    AuthProvider auth,
    int? accountId,
    int accountSessionEpoch,
  ) {
    return auth.user?.id == accountId &&
        auth.accountSessionEpoch == accountSessionEpoch;
  }

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await Future.wait<void>([_loadMyLevel(), _load()]);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadMore() {
    final filter = _resolveFilterKey(_selectedFilterKey);
    return context.read<PostProvider>().loadPosts(
          boardId: 1,
          sort: filter.key,
          type: _activeSection.slug,
          tagId: filter.value,
        );
  }

  Future<void> _changeFilter(String key) async {
    if (key == _selectedFilterKey) return;
    setState(() {
      _selectedFilterKey = key;
      _sortTouched = true;
    });
    await _scrollToTop();
    await _load();
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients || _scrollController.offset <= 0) return;
    await _scrollController.animateTo(
      0,
      duration: AppMotion.tab,
      curve: AppMotion.standard,
    );
  }

  Future<void> _openComposer() async {
    final section = _activeSection;
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            CreatePostScreen(boardId: 1, defaultPostType: section.slug),
      ),
    );
    if (published == true && mounted) {
      await _loadMyLevel();
      if (mounted) await _refresh();
    }
  }

  Future<void> _openPost(Post post) async {
    final changed =
        await Navigator.of(context).push<dynamic>(buildPostDetailRoute(post));
    if (changed == true && mounted) await _refresh();
  }

  Future<void> _openManageScreen() async {
    final slug = _activeSection.slug;
    final sectionProvider = context.read<WaterSectionProvider>();
    final moderatorProvider = context.read<WaterModeratorProvider>();
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => WaterSectionManageScreen(section: _activeSection)),
    );
    if (!mounted) return;
    final fresh = await sectionProvider.refreshSection(slug);
    if (fresh != null && mounted) setState(() => _resolvedSection = fresh);
    await moderatorProvider.loadMyPermission(slug, forceRefresh: true);
  }

  Future<void> _toggleFollowSection() async {
    if (_followPending) return;
    final section = _activeSection;
    final isFollowed = _optimisticIsFollowed ?? section.isFollowed;
    final auth = context.read<AuthProvider>();
    final sectionProvider = context.read<WaterSectionProvider>();
    final postProvider = context.read<PostProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    final accountId = auth.user?.id;
    final accountSessionEpoch = auth.accountSessionEpoch;
    if (accountId == null || accountId <= 0) return;
    setState(() {
      _followPending = true;
      _optimisticIsFollowed = !isFollowed;
    });
    try {
      final success =
          await sectionProvider.toggleFollow(section.slug, !isFollowed);
      if (!_sameAccountSession(auth, accountId, accountSessionEpoch)) return;
      if (!success) {
        throw StateError(sectionProvider.error ?? '操作失败，请稍后重试');
      }
      postProvider.invalidateFollowingFeed();
      await _resolveSection();
      if (mounted &&
          _sameAccountSession(auth, accountId, accountSessionEpoch)) {
        setState(() => _optimisticIsFollowed = null);
        await _refresh();
        if (mounted &&
            _sameAccountSession(auth, accountId, accountSessionEpoch)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(!isFollowed ? '已关注' : '已取消关注')),
          );
        }
      }
    } catch (error) {
      if (mounted &&
          _sameAccountSession(auth, accountId, accountSessionEpoch)) {
        setState(() => _optimisticIsFollowed = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _followPending = false;
          _optimisticIsFollowed = null;
        });
      }
    }
  }

  void _handleScroll(ScrollNotification notification) {
    final offset = notification.metrics.pixels;
    final compact = offset > 72;
    if (_isCompact != compact) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _isCompact = compact);
      });
    }
    if (notification is ScrollStartNotification) {
      _lastScrollOffset = offset;
      _downwardScroll = 0;
      return;
    }
    final last = _lastScrollOffset;
    _lastScrollOffset = offset;
    if (last == null) return;
    final delta = offset - last;
    if (delta > 0) {
      _downwardScroll += delta;
      if (_downwardScroll > 16 && _fabVisible) {
        setState(() => _fabVisible = false);
      }
    } else if (delta < 0) {
      _downwardScroll = 0;
      if (!_fabVisible) setState(() => _fabVisible = true);
    }
    if (offset >= notification.metrics.maxScrollExtent - 360) {
      final filter = _resolveFilterKey(_selectedFilterKey);
      final provider = context.read<PostProvider>();
      final loading = provider.isLoadingFor(
        1,
        sort: filter.key,
        type: _activeSection.slug,
        tagId: filter.value,
      );
      final hasMore = provider.hasMoreFor(
        1,
        sort: filter.key,
        type: _activeSection.slug,
        tagId: filter.value,
      );
      if (!loading && hasMore) unawaited(_loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = _activeSection;
    final filter = _resolveFilterKey(_selectedFilterKey);
    return Selector<
        PostProvider,
        ({
          List<Post> posts,
          List<Post> pinnedPosts,
          bool isLoading,
          bool hasLoaded,
          bool hasMore,
          String? error,
          int revision
        })>(
      selector: (context, provider) => (
        posts: provider.postsFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        pinnedPosts: provider.pinnedPostsFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        isLoading: provider.isLoadingFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        hasLoaded: provider.hasLoadedFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        hasMore: provider.hasMoreFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        error: provider.errorFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
        revision: provider.revisionFor(
          1,
          sort: filter.key,
          type: section.slug,
          tagId: filter.value,
        ),
      ),
      builder: (context, data, _) => _buildPage(context, section, data),
    );
  }

  Widget _buildPage(
    BuildContext context,
    WaterSection section,
    ({
      List<Post> posts,
      List<Post> pinnedPosts,
      bool isLoading,
      bool hasLoaded,
      bool hasMore,
      String? error,
      int revision
    }) data,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = _sectionColor(section, dark);
    final background =
        dark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight;
    final pinned = data.pinnedPosts
        .where((post) => post.waterSectionPinned || post.isActivePinned)
        .toList(growable: false);
    final normal = data.posts
        .where((post) => !pinned.any((item) => item.id == post.id))
        .where((post) => !post.isActivePinned && !post.waterSectionPinned)
        .toList(growable: false);

    return Scaffold(
      backgroundColor: background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  _handleScroll(notification);
                  return false;
                },
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: CustomScrollView(
                    key: const ValueKey('water-section-feed-scroll'),
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: [
                      _buildAppBar(section, dark),
                      SliverToBoxAdapter(
                        child: _buildSectionSummary(section, accent, dark),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _SectionHeaderDelegate(
                          height: SectionFilterHeader.height,
                          child: SectionFilterHeader(
                            currentFilterKey: _selectedFilterKey,
                            accentColor: accent,
                            isDark: dark,
                            onFilterChanged: _changeFilter,
                          ),
                        ),
                      ),
                      if (section.noticeText.trim().isNotEmpty)
                        SliverToBoxAdapter(
                            child: _buildNoticeBar(section, dark)),
                      if (pinned.isNotEmpty)
                        SliverToBoxAdapter(
                          child: PinnedPostSummaryBar(
                            posts: pinned,
                            isDark: dark,
                            label: '置顶',
                            onOpenPost: _openPost,
                          ),
                        ),
                      if (!_sectionReady ||
                          (!data.hasLoaded && data.posts.isEmpty) ||
                          (data.isLoading && data.posts.isEmpty))
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildLoadingState(dark),
                        )
                      else if (data.error != null && data.posts.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildErrorState(dark),
                        )
                      else if (normal.isEmpty &&
                          section.noticeText.trim().isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildEmptyState(dark),
                        )
                      else ...[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.md,
                            AppSpacing.sm,
                            AppSpacing.md,
                            _feedBottomInset(context),
                          ),
                          sliver: SliverList.builder(
                            itemCount: normal.length,
                            itemBuilder: (context, index) => _buildPost(
                              normal[index],
                              section,
                              accent,
                              dark,
                            ),
                          ),
                        ),
                        if (data.isLoading)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 18),
                              child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                right: AppSpacing.lg,
                bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                child: IgnorePointer(
                  ignoring: !_fabVisible,
                  child: AnimatedOpacity(
                    opacity: _fabVisible ? 1 : 0,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : AppMotion.micro,
                    child: SectionFloatingDock(
                      onCompose: _openComposer,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPost(Post post, WaterSection section, Color accent, bool dark) {
    if (post.isPoll) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: CommunityPostCard(
          post: post,
          postVariant: PostCardVariant.homeFeed,
          pollVariant: PollCardVariant.homeCompact,
          onTap: () => _openPost(post),
        ),
      );
    }
    return SectionPostCard(
      post: post,
      section: section,
      accentColor: accent,
      isDark: dark,
      onTap: () => _openPost(post),
    );
  }

  SliverAppBar _buildAppBar(WaterSection section, bool dark) {
    final title = section.title.isNotEmpty ? section.title : section.slug;
    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      backgroundColor:
          dark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
      leading: Semantics(
        button: true,
        label: '返回',
        child: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        ),
      ),
      title: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.micro,
        child: _isCompact
            ? Text(
                title,
                key: const ValueKey('compact-section-title'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              )
            : const SizedBox(key: ValueKey('expanded-section-title')),
      ),
      actions: [
        IconButton(
          tooltip: '版块更多操作',
          onPressed: () => _showSectionActions(section),
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ],
    );
  }

  Widget _buildSectionSummary(WaterSection section, Color accent, bool dark) {
    final title = section.title.isNotEmpty ? section.title : section.slug;
    final subtitle = section.subtitle.isNotEmpty
        ? section.subtitle
        : (section.description.isNotEmpty ? section.description : '校园交流与互助');
    final followed = _optimisticIsFollowed ?? section.isFollowed;
    final muted =
        dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final levelNumber = _myLevel?.level ?? section.myLevel?.level ?? 1;
    final levelTitle = _myLevel?.title ?? section.myLevel?.title ?? '';
    final levelText = !followed
        ? '本版 Lv.0 · 关注后开始积攒经验'
        : '本版 Lv.$levelNumber${levelTitle.isNotEmpty ? ' $levelTitle' : ''}';

    return Container(
      width: double.infinity,
      color: accent.withValues(alpha: dark ? 0.10 : 0.08),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionAvatar(
                section: section,
                size: 48,
                radius: AppRadius.md,
                accentColor: accent,
                isDark: dark,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: dark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              SizedBox(
                height: 34,
                child: FilledButton(
                  onPressed: _followPending ? null : _toggleFollowSection,
                  style: FilledButton.styleFrom(
                    backgroundColor: followed
                        ? accent.withValues(alpha: dark ? 0.18 : 0.12)
                        : accent,
                    foregroundColor: followed ? accent : Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: _followPending
                      ? Semantics(
                          label: '关注状态更新中',
                          child: const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        )
                      : Text(followed ? '已关注' : '+ 关注'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                '${section.postCount} 帖 · ${section.followerCount} 关注',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            levelText,
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      ),
    );
  }

  Future<void> _showSectionActions(WaterSection section) async {
    final permission =
        context.read<WaterModeratorProvider>().permissionOf(section.slug);
    final user = context.read<AuthProvider>().user;
    final canManage = user?.isAdmin == true ||
        user?.isSuperAdmin == true ||
        permission.isGlobalAdmin ||
        permission.isModerator;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('版块说明'),
              subtitle: Text(section.description.isNotEmpty
                  ? section.description
                  : '暂无版块说明'),
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('举报版块'),
              onTap: () {
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('举报入口即将上线')),
                );
              },
            ),
            if (canManage)
              ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('管理版块'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openManageScreen();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoticeBar(WaterSection section, bool dark) {
    final title = section.noticeText
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '版主公告');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: dark
              ? AppColors.warningSurfaceDark
              : AppColors.warningSurfaceLight,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            Text(
              '公告',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: dark ? AppColors.warning : const Color(0xFFB37B00),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: dark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimaryLight,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18),
          ],
        ),
      ),
    );
  }

  double _feedBottomInset(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + 52 + AppSpacing.xl;

  Widget _buildEmptyState(bool dark) {
    final section = _activeSection;
    final accent = _sectionColor(section, dark);
    final title = _emptyTitleFor(section);
    final description = _emptyDescriptionFor(section);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            iconKeyToIconData(section.iconKey, fallbackSlug: section.slug),
            size: 34,
            color: accent,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.xs),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _mutedText(dark)),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _openComposer,
            icon: const Icon(Icons.edit_rounded, size: 16),
            label: Text(section.publishActionText),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(bool dark) {
    return Center(
      child: FilledButton.tonalIcon(
        onPressed: _refresh,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('加载失败，重试'),
      ),
    );
  }

  Widget _buildLoadingState(bool dark) {
    return Center(
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: dark ? AppColors.textSecondaryDark : AppColors.brandPrimary,
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
        return section.emptyTitle.isNotEmpty ? section.emptyTitle : '这里还没有内容';
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
        return section.emptyDescription.isNotEmpty
            ? section.emptyDescription
            : widget.category.emptyLeadText;
    }
  }

  Color _sectionColor(WaterSection section, bool dark) {
    if (section.colorHex.isNotEmpty && section.colorHex != '#') {
      return colorHexToColor(section.colorHex);
    }
    return widget.category.color;
  }

  Color _mutedText(bool dark) =>
      dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
}

class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _SectionHeaderDelegate({required this.height, required this.child});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      child;

  @override
  bool shouldRebuild(covariant _SectionHeaderDelegate oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}
