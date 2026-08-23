import 'package:flutter/material.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../models/user.dart';
import '../models/post.dart';
import '../providers/social_provider.dart';
import '../providers/post_provider.dart';
import '../widgets/community_post_card.dart';
import '../widgets/poll/poll_post_card.dart';
import '../widgets/market_post_card.dart';
import '../widgets/cached_avatar.dart';
import 'social_list_screen.dart';
import 'image_viewer_screen.dart';
import 'chat_detail_screen.dart';
import 'competition/competition_award_screen.dart';

import '../widgets/level_progress_pill.dart';
import '../utils/app_navigation.dart';

class UserHomeScreen extends StatefulWidget {
  final int? userId;
  final BaseCacheManager? backgroundCacheManager;

  const UserHomeScreen({super.key, this.userId, this.backgroundCacheManager});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  User? _user;
  List<Post> _posts = [];
  List<Post> _marketPosts = [];
  int _marketTotal = 0;
  int _marketSoldCount = 0;
  int _currentTabIndex = 0;
  bool _isLoading = true;
  String? _errorMessage;
  int _accountSessionEpoch = -1;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted) return;
      if (_currentTabIndex != _tabController.index) {
        setState(() => _currentTabIndex = _tabController.index);
      }
    });
    if (widget.userId == null) {
      _user = context.read<AuthProvider>().user;
    }
  }

  int _loadGeneration = 0;

  Future<void> _loadData() async {
    final generation = ++_loadGeneration;
    final auth = context.read<AuthProvider>();
    final requestEpoch = auth.accountSessionEpoch;
    final requestViewerId = auth.user?.id;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final targetId = widget.userId ?? auth.user?.id;
      if (targetId == null) return;

      final provider = context.read<SocialProvider>();
      final isSelf = targetId == auth.user?.id;

      final postsFuture = provider.getUserPosts(targetId);
      final marketFuture = provider.getUserMarketPosts(targetId);

      User? loadedUser;
      if (isSelf) {
        await auth.refreshUser();
      } else {
        loadedUser = await provider.getUserProfile(targetId);
      }

      final posts = await postsFuture;
      final marketResult = await marketFuture;

      if (!mounted ||
          generation != _loadGeneration ||
          auth.accountSessionEpoch != requestEpoch ||
          auth.user?.id != requestViewerId) {
        return;
      }

      setState(() {
        _user = isSelf ? context.read<AuthProvider>().user : loadedUser;
        _posts = posts.where((post) => !_isMarketPost(post)).toList();
        _marketPosts = marketResult.items;
        _marketTotal = marketResult.total;
        _marketSoldCount = marketResult.sold;
      });
    } on SocialRequestException catch (error) {
      if (!mounted || error.sessionChanged) return;
      if (generation == _loadGeneration) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _errorMessage = '加载用户内容失败，请稍后重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onProfileSaved() {
    if (!mounted) return;
    setState(() {
      _user = context.read<AuthProvider>().user;
    });
  }

  bool _isMarketPost(Post post) {
    return post.boardId == 2 ||
        post.postType == 'market' ||
        post.postType == 'sell' ||
        post.postType == 'buy' ||
        post.postType == 'service' ||
        post.marketTags.isNotEmpty;
  }

  /// 当前主页用户的 id，作为详情页作者跳转的来源锚点。
  int? get _profileUserId {
    return _user?.id ?? widget.userId ?? context.read<AuthProvider>().user?.id;
  }

  /// 从个人主页统一打开帖子/商品详情。
  ///
  /// 进入详情后点头像的行为由来源决定：
  /// - 点到当前主页用户自己：maybePop 返回来源主页，避免 UserHome(A)->Detail(A)->UserHome(A) 套娃。
  /// - 点到其他用户：pushReplacement 进入对方主页，栈深度不增长，返回时回到来源主页。
  Future<void> _openProfilePostDetail(
    Post post, {
    bool isMarket = false,
  }) async {
    await AppNavigation.openPostDetail(
      context,
      post: post,
      isMarket: isMarket,
      sourceUserId: _profileUserId,
    );

    if (mounted) {
      await _loadData();
    }
  }

  String get _marketTabText {
    if (_currentTabIndex == 1) {
      return '售出 $_marketSoldCount单';
    }
    return '商品 $_marketTotal';
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authUser = context.watch<AuthProvider>().user;
    final auth = context.read<AuthProvider>();
    if (_accountSessionEpoch != auth.accountSessionEpoch) {
      _accountSessionEpoch = auth.accountSessionEpoch;
      _posts = [];
      _marketPosts = [];
      _marketTotal = 0;
      _marketSoldCount = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadData();
      });
    }
    final isSelfProfile =
        widget.userId == null || widget.userId == authUser?.id;
    final displayedUser = isSelfProfile ? authUser ?? _user : _user;

    if (displayedUser == null) {
      if (_isLoading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return Scaffold(
        appBar: AppBar(title: const Text('错误')),
        body: Center(child: Text(_errorMessage ?? '用户不存在或加载失败')),
      );
    }

    if (_errorMessage != null && !_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('加载失败')),
        body: RefreshIndicator(
          onRefresh: _loadData,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: 320,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, color: Colors.grey, size: 42),
                      const SizedBox(height: 12),
                      Text(_errorMessage!,
                          style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _loadData,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final user = displayedUser;
    final isMe = isSelfProfile;

    final pageBackground = isDark
        ? const Color(0xFF111214)
        : Theme.of(context).scaffoldBackgroundColor;

    // 标签栏和内容区共用的面板色
    final panelColor = isDark ? const Color(0xFF1A1B1E) : Colors.white;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= 820) {
          return _buildWideProfileLayout(
            context,
            user,
            isMe,
            isDark,
            pageBackground,
            panelColor,
            width,
          );
        }
        return _buildCompactProfileLayout(
          context,
          user,
          isMe,
          isDark,
          pageBackground,
          panelColor,
          width,
        );
      },
    );
  }

  Widget _buildWideProfileLayout(
    BuildContext context,
    User user,
    bool isMe,
    bool isDark,
    Color pageBackground,
    Color panelColor,
    double width,
  ) {
    return Scaffold(
      backgroundColor: pageBackground,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧资料栏
          SizedBox(
            width: width >= 1000 ? 380 : 320,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        color: panelColor,
                        child: Column(
                          children: [
                            // 顶部背景和资料堆叠
                            SizedBox(
                              height: 480,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _buildProfileBackground(context, user),

                                  // 渐变遮罩
                                  const DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        stops: [0.0, 0.42, 1.0],
                                        colors: [
                                          Colors.transparent,
                                          Color(0x22000000),
                                          Color(0xDD000000),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // 左上角返回
                                  Positioned(
                                    top: 12,
                                    left: 12,
                                    child: _buildCircleButton(
                                      icon: Icons.arrow_back,
                                      onTap: () => Navigator.maybePop(context),
                                    ),
                                  ),

                                  // 底部覆盖资料
                                  Positioned(
                                    left: 20,
                                    right: 20,
                                    bottom: 24,
                                    child: _buildProfileOverlay(
                                        context, user, isMe),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 右侧帖子区域
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(top: 16, right: 16, bottom: 16),
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorSize: TabBarIndicatorSize.label,
                    indicatorWeight: 3,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    labelColor: Theme.of(context).colorScheme.primary,
                    unselectedLabelColor:
                        isDark ? Colors.white60 : Colors.black54,
                    tabs: [
                      Tab(text: '帖子 ${_posts.length}'),
                      Tab(text: _marketTabText),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : _posts.isEmpty
                                ? const Center(child: Text('暂无帖子'))
                                : ListView.builder(
                                    padding: const EdgeInsets.all(16),
                                    itemCount: _posts.length,
                                    itemBuilder: (context, index) {
                                      return CommunityPostCard(
                                        post: _posts[index],
                                        disableAuthorNavigation: true,
                                        pollVariant:
                                            PollCardVariant.profileCompact,
                                        onTap: () => _openProfilePostDetail(
                                          _posts[index],
                                        ),
                                      );
                                    },
                                  ),
                        _buildMarketPostsList(
                          padding: const EdgeInsets.all(16),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactProfileLayout(
    BuildContext context,
    User user,
    bool isMe,
    bool isDark,
    Color pageBackground,
    Color panelColor,
    double screenWidth,
  ) {
    final heroHeight = (screenWidth * 1.03).clamp(390.0, 480.0);
    return Scaffold(
      backgroundColor: panelColor,
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadData();
        },
        child: NestedScrollView(
          controller: _scrollController,
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return <Widget>[
              SliverAppBar(
                expandedHeight: heroHeight,
                pinned: true,
                floating: false,
                elevation: 0,
                scrolledUnderElevation: 0,
                surfaceTintColor: Colors.transparent,
                backgroundColor: pageBackground,
                toolbarHeight: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 背景图
                      _buildProfileBackground(context, user),

                      // 下部渐暗遮罩
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.0, 0.42, 1.0],
                            colors: [
                              Colors.transparent,
                              Color(0x22000000),
                              Color(0xDD000000),
                            ],
                          ),
                        ),
                      ),

                      // 顶部按钮行（返回 + 私信）
                      Positioned(
                        top: MediaQuery.of(context).padding.top + 8,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildCircleButton(
                              icon: Icons.arrow_back,
                              onTap: () => Navigator.maybePop(context),
                            ),
                            if (!isMe)
                              _buildCircleButton(
                                icon: Icons.mail_outline,
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ChatDetailScreen(targetUser: user),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),

                      // 所有资料覆盖在背景图下半部分
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 64,
                        child: _buildProfileOverlay(context, user, isMe),
                      ),
                    ],
                  ),
                ),

                // 底部圆角标签栏
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(46),
                  child: Container(
                    height: 46,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: panelColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicatorSize: TabBarIndicatorSize.label,
                      indicatorWeight: 3,
                      indicatorColor: Theme.of(context).colorScheme.primary,
                      labelColor: Theme.of(context).colorScheme.primary,
                      unselectedLabelColor:
                          isDark ? Colors.white60 : Colors.black54,
                      labelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      tabs: [
                        Tab(text: '帖子 ${_posts.length}'),
                        Tab(text: _marketTabText),
                      ],
                    ),
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            controller: _tabController,
            children: [
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _posts.isEmpty
                      ? const Center(child: Text('暂无帖子'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                          itemCount: _posts.length,
                          itemBuilder: (context, index) {
                            return CommunityPostCard(
                              post: _posts[index],
                              disableAuthorNavigation: true,
                              pollVariant: PollCardVariant.profileCompact,
                              onTap: () => _openProfilePostDetail(
                                _posts[index],
                              ),
                            );
                          },
                        ),
              _buildMarketPostsList(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarketPostsList({required EdgeInsets padding}) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_marketPosts.isEmpty) {
      return const Center(child: Text('暂无上架商品'));
    }

    return ListView.builder(
      padding: padding,
      itemCount: _marketPosts.length,
      itemBuilder: (context, index) {
        final post = _marketPosts[index];
        return MarketPostCard(
          post: post,
          compact: false,
          onAuthorTap: (_) {},
          onTap: () => _openProfilePostDetail(post, isMarket: true),
        );
      },
    );
  }

  // ============ 顶部圆形按钮 ============

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: Colors.black26,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  // ============ 主页背景图（单层原图，cover 裁切，无模糊）============

  Widget _buildProfileBackground(BuildContext context, User user) {
    if (user.background.isEmpty) {
      return Image.asset(
        'assets/images/morenbeijing.jpeg',
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      );
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              imageUrls: [
                ApiConstants.fullUrl(user.background),
              ],
            ),
          ),
        );
      },
      child: ClipRect(
        child: CachedNetworkImage(
          imageUrl: ApiConstants.fullUrl(user.background),
          cacheManager: widget.backgroundCacheManager ?? PostImageCache.manager,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          placeholder: (_, __) => Container(
            color: const Color(0xFFEDEEF1),
          ),
          errorWidget: (_, __, ___) => Image.asset(
            'assets/images/morenbeijing.jpeg',
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  // ============ 覆盖在背景上的个人资料 ============

  Widget _buildProfileOverlay(BuildContext context, User user, bool isMe) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 第一行：头像 + 编辑/关注按钮
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () {
                if (user.avatar.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImageViewerScreen(
                        imageUrls: [ApiConstants.fullUrl(user.avatar)],
                      ),
                    ),
                  );
                }
              },
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                    width: 2,
                  ),
                ),
                child: CachedAvatar(
                  imageUrl: user.avatar.isNotEmpty
                      ? ApiConstants.fullUrl(user.avatar)
                      : null,
                  radius: 38,
                  fallbackText: user.nickname,
                ),
              ),
            ),
            const Spacer(),
            if (isMe)
              _buildOverlayButton(
                text: '编辑资料',
                onPressed: () => _showEditSheet(context, user),
              )
            else
              _buildFollowButton(context, user),
          ],
        ),

        // 第二行：昵称 + 等级
        const SizedBox(height: 16),
        Row(
          children: [
            Flexible(
              child: Text(
                user.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: Color(user.levelColorValue),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                user.levelLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),

        // 第三行：性别和公开用户 ID
        const SizedBox(height: 8),
        Row(
          children: [
            if (user.gender == 'female') ...[
              const Icon(Icons.female, size: 15, color: Colors.pinkAccent),
              const SizedBox(width: 5),
            ] else if (user.gender == 'male') ...[
              const Icon(
                Icons.male,
                size: 15,
                color: Colors.lightBlueAccent,
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                user.publicIdLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),

        // 统计数据：获赞、关注、粉丝
        const SizedBox(height: 14),
        Row(
          children: [
            _buildOverlayStat(user.totalLikesReceived.toString(), '获赞', null),
            const SizedBox(width: 28),
            _buildOverlayStat(
              user.followingCount.toString(),
              '关注',
              isMe
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SocialListScreen(
                            userId: user.id,
                            initialIndex: 0,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(width: 28),
            _buildOverlayStat(
              user.followersCount.toString(),
              '粉丝',
              isMe
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SocialListScreen(
                            userId: user.id,
                            initialIndex: 1,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
          ],
        ),

        // 等级进度胶囊
        const SizedBox(height: 14),
        LevelProgressPill(
          levelLabel: user.levelLabel,
          expText: '${user.exp}/${user.expToNextLevel}',
          progress: user.levelProgress,
          accentColor: Color(user.levelColorValue),
          darkOnImage: true,
        ),
      ],
    );
  }

  // ============ 覆盖层辅助组件 ============

  Widget _buildOverlayButton({
    required String text,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowButton(BuildContext context, User user) {
    if (user.isFollowing) {
      return _buildOverlayButton(
        text: '已关注',
        onPressed: () async {
          final success = await context.read<SocialProvider>().unfollow(
                user.id,
              );
          if (success && mounted) {
            setState(() {
              _user!.isFollowing = false;
              _user!.followersCount = (_user!.followersCount - 1).clamp(
                0,
                999999,
              );
            });
            context.read<AuthProvider>().refreshUser();
            context.read<PostProvider>().invalidateFollowingFeed();
          }
        },
      );
    } else {
      return Material(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: () async {
            final success = await context.read<SocialProvider>().follow(
                  user.id,
                );
            if (success && mounted) {
              setState(() {
                _user!.isFollowing = true;
                _user!.followersCount++;
              });
              context.read<AuthProvider>().refreshUser();
              context.read<PostProvider>().invalidateFollowingFeed();
            }
          },
          borderRadius: BorderRadius.circular(22),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 9),
            child: Text(
              '关注',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildOverlayStat(String count, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: count,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: ' $label',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 编辑资料悬浮窗 ----------------
  void _showEditSheet(BuildContext context, User user) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: _EditProfileSheet(
            user: user,
            onCompetitionAwards: () {
              final auth = context.read<AuthProvider>();
              final accountID = auth.user?.id;
              if (accountID == null) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CompetitionAwardScreen(
                    dio: auth.dio,
                    accountKey: accountID,
                  ),
                ),
              );
            },
            onSaved: () async {
              _onProfileSaved();
            }),
      ),
    );
  }
}

class AnimatedCount extends StatelessWidget {
  final int count;
  final TextStyle style;

  const AnimatedCount({super.key, required this.count, required this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: count.toDouble()),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutQuart,
      builder: (context, value, child) {
        return Text(value.toInt().toString(), style: style);
      },
    );
  }
}

class _EditProfileSheet extends StatefulWidget {
  final User user;
  final Future<void> Function() onSaved;
  final VoidCallback onCompetitionAwards;

  const _EditProfileSheet({
    required this.user,
    required this.onSaved,
    required this.onCompetitionAwards,
  });

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late TextEditingController _nicknameController;
  late String _selectedGender;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.user.nickname);
    _selectedGender = switch (widget.user.gender) {
      'male' || 'female' => widget.user.gender,
      _ => '',
    };
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadBackground() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      maxWidth: 1920,
      maxHeight: 1920,
      compressQuality: 85,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '调整背景图',
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          statusBarColor: Colors.black,
          backgroundColor: Colors.black,
          lockAspectRatio: false,
        ),
        IOSUiSettings(
          title: '调整背景图',
          aspectRatioLockEnabled: false,
          resetAspectRatioEnabled: true,
        ),
      ],
    );

    if (cropped == null) return;

    if (!mounted) return;
    final auth = context.read<AuthProvider>();

    try {
      setState(() => _isSaving = true);
      final croppedBytes = await cropped.readAsBytes();
      final croppedName =
          'background_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          croppedBytes,
          filename: croppedName,
          contentType: DioMediaType('image', 'jpeg'),
        ),
      });
      final uploadRes = await auth.dio.post('/upload', data: formData);
      if (uploadRes.statusCode == 200 && uploadRes.data['url'] != null) {
        final url = uploadRes.data['url'] as String;
        final response =
            await auth.dio.put('/user/background', data: {'background': url});

        await auth.applyProfileResponse(
          Map<String, dynamic>.from(response.data),
        );

        await widget.onSaved();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('背景更换成功')));
        }
      } else {
        debugPrint('上传失败 (${uploadRes.statusCode})');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            const SnackBar(content: Text('背景图上传失败，请稍后重试')),
          );
        }
      }
    } on DioException catch (e) {
      debugPrint(
        '背景上传 DioException: type=${e.type}, status=${e.response?.statusCode}',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          const SnackBar(content: Text('背景图上传失败，请稍后重试')),
        );
      }
    } catch (e) {
      debugPrint('背景上传异常: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          const SnackBar(content: Text('背景图上传失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _saveProfile() async {
    final newNickname = _nicknameController.text.trim();
    if (newNickname.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.put(
        '/user/profile',
        data: {'nickname': newNickname, 'gender': _selectedGender},
      );

      await auth.applyProfileResponse(
        Map<String, dynamic>.from(response.data),
      );

      await widget.onSaved();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('资料已保存')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 420,
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖动条
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '编辑资料',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 24),

              // 更改背景
              InkWell(
                onTap: _isSaving ? null : _pickAndUploadBackground,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.grey[800] : Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.image, color: Colors.blue),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('更改主页背景图')),
                      Icon(Icons.chevron_right, color: Colors.grey[500]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 竞赛经历是私有档案入口，不在公开主页直接展示。
              InkWell(
                key: const Key('profile-competition-award-entry'),
                onTap: _isSaving
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.onCompetitionAwards();
                      },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.grey[800] : Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.workspace_premium_outlined,
                        color: Colors.blue,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('竞赛经历')),
                      Icon(Icons.chevron_right, color: Colors.grey[500]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 昵称
              TextField(
                controller: _nicknameController,
                decoration: InputDecoration(
                  labelText: '昵称',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),

              // 性别：上下布局，三段按钮独占整行，避免系统显示缩放时被挤换行。
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '性别',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'male', label: Text('男生')),
                        ButtonSegment(value: 'female', label: Text('女生')),
                        ButtonSegment(value: '', label: Text('保密')),
                      ],
                      selected: {_selectedGender},
                      onSelectionChanged: (Set<String> newSelection) {
                        setState(() {
                          _selectedGender = newSelection.first;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 保存按钮
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          '保存',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
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
}
