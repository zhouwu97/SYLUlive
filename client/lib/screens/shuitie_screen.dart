import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_bootstrap.dart';
import '../config/api_constants.dart';
import '../models/water_section.dart';
import '../config/water_post_taxonomy.dart';
import '../widgets/water_section/section_avatar.dart';
import '../theme/app_motion.dart';
import '../utils/responsive_util.dart';
import '../utils/app_feedback.dart';
import '../utils/search_focus_gate.dart';

import '../models/announcement.dart' as model;
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/water_section_provider.dart';
import '../services/feed_event_service.dart';
import '../services/feed_session_service.dart';
import '../services/post_cache_service.dart';
import '../services/root_page_state_service.dart';
import '../widgets/glass_container.dart';
import '../widgets/home_service_drawer.dart';
import '../widgets/pinned_post_summary_bar.dart';
import '../widgets/community_post_card.dart';
import '../widgets/feed/feed_exposure_tracker.dart';
import '../widgets/feed/feed_post_action_menu.dart';
import '../widgets/report_sheet.dart';
import 'announcement_screen.dart';
import 'chat_list_screen.dart';
import 'create_post_screen.dart';
import 'poll/poll_composer_screen.dart';
import 'check_in_calendar_screen.dart';
import 'competition_center_screen.dart';
import 'edu_grade_screen.dart';
import 'exam_schedule_screen.dart';
import 'feedback_screen.dart';
import 'login_screen.dart';
import 'post_detail_screen.dart';
import 'poll/poll_detail_screen.dart';
import 'search_results_screen.dart';
import 'water_section_directory_screen.dart';
import 'toolbox_screen.dart';
import 'user_home_screen.dart';
import 'water_category_feed_route.dart';

// ---- Feed Mode 统一配置 ----

class FeedModeConfig {
  final String key;
  final String label;

  /// 远程排序参数。为 null 表示该模式不支持远程加载。
  final String? remoteSort;

  /// 是否支持远程加载帖子。
  final bool supportsRemoteLoading;

  const FeedModeConfig({
    required this.key,
    required this.label,
    required this.remoteSort,
    required this.supportsRemoteLoading,
  });
}

/// 标签显示顺序：最新、综合、精华、关注
/// 默认选中：综合 (index 1)
const List<FeedModeConfig> kFeedModes = [
  FeedModeConfig(
    key: 'new',
    label: '最新',
    remoteSort: 'time',
    supportsRemoteLoading: true,
  ),
  FeedModeConfig(
    key: 'all',
    label: '综合',
    remoteSort: 'all',
    supportsRemoteLoading: true,
  ),
  FeedModeConfig(
    key: 'featured',
    label: '精华',
    remoteSort: 'featured',
    supportsRemoteLoading: true,
  ),
  FeedModeConfig(
    key: 'following',
    label: '关注',
    remoteSort: 'following',
    supportsRemoteLoading: true,
  ),
];

const int kDefaultFeedModeIndex = 1; // 综合

class ShuitieScreen extends StatefulWidget {
  /// 可选注入仅用于测试；生产环境创建内部实例。
  final FeedSessionService? feedSessionService;
  final FeedEventService? feedEventService;

  const ShuitieScreen(
      {super.key, this.feedSessionService, this.feedEventService});

  @override
  State<ShuitieScreen> createState() => _ShuitieScreenState();
}

class _ShuitieScreenState extends State<ShuitieScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Map<String, ScrollController> _feedScrollControllers;

  // FEED-3：事件会话与批量上报（注入或内部默认）。
  late final FeedSessionService _feedSessionService;
  late final FeedEventService _feedEventService;

  late AnimationController _feedSwitchController;
  Animation<double>? _feedSettleAnimation;
  int? _feedTargetIndex;
  double _feedVisualIndexValue = kDefaultFeedModeIndex.toDouble();
  late final ValueNotifier<double> _feedVisualIndexListenable;
  double _feedSwipeStartVisualIndex = kDefaultFeedModeIndex.toDouble();
  double _feedSwipeDx = 0;
  double? _pendingRestoredScrollOffset;

  // 后台新鲜度探测：列表未在顶部时不直接覆写，显示“内容有更新”浮条。
  bool _freshnessBannerVisible = false;
  String _freshnessBannerLabel = '内容有更新';
  // 桌面分屏模式：评论入口请求打开详情时聚焦评论输入框。
  bool _selectedFocusReply = false;
  static const double _freshnessNearTopThreshold = 160;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _autoRefreshTimer;
  Timer? _announcementDelayTimer;
  List<model.Announcement> _announcements = [];
  List<model.Announcement> _unreadAnnouncements = [];
  bool _wasLoggedIn = false;
  bool _checkinStatusLoaded = false;
  bool _checkinStatusLoading = false;
  String _feedMode = kFeedModes[kDefaultFeedModeIndex].key; // 'all'
  String _searchQuery = '';
  List<Post> _searchResults = [];
  bool _checkedIn = false;
  int _streakDays = 0;
  bool _followingExpanded = false;
  Post? _selectedPost;
  int? _selectedUserId;

  // FEED-3 桌面分屏：当前打开帖子的 open/dwell 归因上下文。
  _SplitOrigin? _splitOrigin;

  static const _autoRefreshInterval = Duration(seconds: 60);
  static const _feedTriggerDistance = 72.0;
  static const _feedTriggerVelocity = 520.0;

  // ---- 配置辅助 ----
  FeedModeConfig get _currentConfig =>
      kFeedModes.firstWhere((m) => m.key == _feedMode);

  int get _currentModeIndex => kFeedModes.indexWhere((m) => m.key == _feedMode);

  double get _feedVisualIndex => _feedVisualIndexValue;

  void _setFeedVisualIndex(double value) {
    _feedVisualIndexValue =
        value.clamp(0.0, (kFeedModes.length - 1).toDouble());
    _feedVisualIndexListenable.value = _feedVisualIndexValue;
  }

  String? get _currentRemoteSort => _currentConfig.remoteSort;

  bool get _showCheckInDot => _checkinStatusLoaded && !_checkedIn;

  bool _canLoadFeedMode(String mode) {
    if (mode != 'following') return true;
    return context.read<AuthProvider>().isLoggedIn;
  }

  @override
  void initState() {
    super.initState();

    // FEED-3：首次进入 Feed 即开启一个事件会话。
    _feedSessionService = widget.feedSessionService ?? FeedSessionService();
    _feedSessionService.newSession();
    _feedEventService =
        widget.feedEventService ?? FeedEventService(getSharedDio());

    _feedScrollControllers = {
      for (final mode in kFeedModes)
        mode.key: ScrollController(keepScrollOffset: true),
    };
    _feedVisualIndexListenable =
        ValueNotifier<double>(_currentModeIndex.toDouble());

    WidgetsBinding.instance.addObserver(this);
    _feedSwitchController = AnimationController(
      vsync: this,
      duration: AppMotion.tab,
    )..addListener(_handleFeedSettleTick);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreCommunityState();
      if (!mounted) return;
      final postProvider = context.read<PostProvider>();
      final initialSort = _currentRemoteSort;
      if (initialSort != null && _canLoadFeedMode(_feedMode)) {
        postProvider.loadPosts(boardId: 1, sort: initialSort);
      }
      _startAutoRefresh();
      _ensureCheckinStatusLoaded();

      // 预热水帖版块缓存，供服务抽屉使用
      context.read<WaterSectionProvider>().loadSections();

      // 延迟加载其他非核心数据
      _announcementDelayTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          unawaited(_loadAnnouncements());
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_currentConfig.supportsRemoteLoading && _canLoadFeedMode(_feedMode)) {
        unawaited(_probeFeedFreshness());
      }
      _loadAnnouncements();
      unawaited(_ensureCheckinStatusLoaded(force: true));
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused) {
      unawaited(_persistCommunityState());
      _feedEventService.flushNow(); // 应用进入后台时尝试清空事件队列
      _stopAutoRefresh();
    }
  }

  Future<void> _restoreCommunityState() async {
    final validModes = kFeedModes.map((mode) => mode.key).toSet();
    final state = await RootPageStateStore.instance.readCommunityFeedState(
      validModes: validModes,
    );
    if (!mounted || state == null || !_canLoadFeedMode(state.mode)) return;
    setState(() {
      _feedMode = state.mode;
      _pendingRestoredScrollOffset = state.scrollOffset;
    });
    _setFeedVisualIndex(_currentModeIndex.toDouble());
    _scheduleRestoredScroll();
  }

  Future<void> _persistCommunityState({String? mode}) async {
    final currentMode = mode ?? _feedMode;
    final controller = _feedScrollControllers[currentMode];
    final offset = controller?.hasClients == true ? controller!.offset : 0.0;
    await RootPageStateStore.instance.saveCommunityFeedState(
      mode: currentMode,
      scrollOffset: offset.isFinite && offset >= 0 ? offset : 0,
    );
  }

  void _scheduleRestoredScroll() {
    final offset = _pendingRestoredScrollOffset;
    if (offset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingRestoredScrollOffset == null) return;
      final controller = _feedScrollControllers[_feedMode];
      if (controller?.hasClients != true) return;
      final position = controller!.position;
      if (offset > 0 && position.maxScrollExtent <= 0) return;
      controller.jumpTo(offset.clamp(0, position.maxScrollExtent).toDouble());
      _pendingRestoredScrollOffset = null;
    });
  }

  void _startAutoRefresh() {
    _stopAutoRefresh();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted) return;
      if (_currentConfig.supportsRemoteLoading && _canLoadFeedMode(_feedMode)) {
        unawaited(_probeFeedFreshness());
      }
      _loadAnnouncements();
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoRefresh();
    _announcementDelayTimer?.cancel();
    _announcementDelayTimer = null;
    unawaited(_persistCommunityState());

    for (final controller in _feedScrollControllers.values) {
      controller.dispose();
    }

    _searchController.dispose();
    _searchFocusNode.dispose();
    _feedSwitchController
      ..removeListener(_handleFeedSettleTick)
      ..dispose();
    _feedVisualIndexListenable.dispose();
    _feedEventService.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    final sessionGeneration = authProvider.sessionGeneration;
    final unreadFuture = _loadUnreadAnnouncements(authProvider);
    try {
      final response = await _getAnnouncements(
        authProvider,
        unreadOnly: false,
      );
      final all = _parseAnnouncements(response);
      final loadedUnread = await unreadFuture;
      final unread = authProvider.isLoggedIn &&
              authProvider.sessionGeneration == sessionGeneration
          ? loadedUnread
          : <model.Announcement>[];
      if (!mounted) return;
      setState(() {
        _announcements = all;
        _unreadAnnouncements = unread;
      });
    } catch (e) {
      debugPrint('加载公告失败: $e');
    }
  }

  Future<List<model.Announcement>> _loadUnreadAnnouncements(
    AuthProvider authProvider,
  ) async {
    if (!authProvider.isLoggedIn) return [];
    try {
      final response = await _getAnnouncements(
        authProvider,
        unreadOnly: true,
      );
      return _parseAnnouncements(response);
    } catch (e) {
      debugPrint('加载未读公告失败: $e');
      return [];
    }
  }

  Future<Response<dynamic>> _getAnnouncements(
    AuthProvider authProvider, {
    required bool unreadOnly,
  }) async {
    final primaryPath = unreadOnly
        ? '${ApiConstants.noticesPath}/unread'
        : ApiConstants.noticesPath;
    final fallbackPath =
        unreadOnly ? '/announcements/unread' : '/announcements';
    try {
      return await authProvider.dio.get(primaryPath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return authProvider.dio.get(fallbackPath);
      }
      rethrow;
    }
  }

  List<model.Announcement> _parseAnnouncements(Response<dynamic> response) {
    if (response.statusCode != 200 || response.data is! List) return [];
    return (response.data as List)
        .map((item) => model.Announcement.fromJson(item))
        .toList()
      ..sort(model.Announcement.compareForDisplay);
  }

  Future<void> _runSearch(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;

    _searchFocusNode.unfocus();
    _searchController.clear();
    if (mounted) {
      setState(() {
        _searchQuery = '';
        _searchResults = [];
      });
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(query: query, boardId: 1),
      ),
    );
  }

  bool _exitSearchInputMode() {
    return consumeSearchInputExit(
      hasFocus: _searchFocusNode.hasFocus,
      unfocus: _searchFocusNode.unfocus,
    );
  }

  void _onSearchChanged(String value) {
    setState(() {});
  }

  void _handleFeedSettleTick() {
    final animation = _feedSettleAnimation;
    if (animation == null || !mounted) return;
    _setFeedVisualIndex(animation.value);
  }

  Future<void> _animateFeedIndicatorTo(
    int targetIndex, {
    double? begin,
    Duration duration = AppMotion.tab,
  }) async {
    final start = (begin ?? _feedVisualIndex).clamp(
      0.0,
      (kFeedModes.length - 1).toDouble(),
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _feedSwitchController.stop();
      _feedSettleAnimation = null;
      _setFeedVisualIndex(targetIndex.toDouble());
      return;
    }
    _feedSwitchController.stop();
    _feedSwitchController.duration = duration;
    final animation = Tween<double>(
      begin: start,
      end: targetIndex.toDouble(),
    ).animate(CurvedAnimation(
      parent: _feedSwitchController,
      curve: AppMotion.movement,
    ));
    _feedSettleAnimation = animation;
    _setFeedVisualIndex(start);
    try {
      await _feedSwitchController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted && identical(animation, _feedSettleAnimation)) {
      _setFeedVisualIndex(targetIndex.toDouble());
    }
  }

  Future<void> _changeFeedMode(String mode) async {
    if (_feedMode == mode) return;
    final newIndex = kFeedModes.indexWhere((m) => m.key == mode);
    if (newIndex < 0) return;
    final startVisual = _feedVisualIndex;
    unawaited(_persistCommunityState());

    // 切换信息流时丢弃上一模式的暂存探测结果与浮条。
    final previousSort = _currentRemoteSort;
    if (previousSort != null) {
      context
          .read<PostProvider>()
          .clearPendingFreshSnapshot(boardId: 1, sort: previousSort);
    }
    _refreshFeedMode(mode);
    setState(() {
      _feedMode = mode;
      _feedTargetIndex = null;
      _freshnessBannerVisible = false;
    });

    // 内容立即换，只有顶部 indicator 使用 120ms 的可 retarget 过渡。
    await _animateFeedIndicatorTo(newIndex, begin: startVisual);
    unawaited(_persistCommunityState());
  }

  void _refreshFeedMode(String mode) {
    if (!_canLoadFeedMode(mode)) return;

    final config = kFeedModes.firstWhere((m) => m.key == mode);
    if (!config.supportsRemoteLoading || config.remoteSort == null) return;
    final sort = config.remoteSort!;
    final postProvider = context.read<PostProvider>();

    final now = DateTime.now();
    final lastRefresh = postProvider.lastSuccessfulRefreshAtFor(1, sort: sort);
    final hasLoaded = postProvider.hasLoadedFor(1, sort: sort);
    if (hasLoaded &&
        lastRefresh != null &&
        now.difference(lastRefresh) < const Duration(seconds: 60)) {
      return;
    }

    if (hasLoaded) {
      unawaited(postProvider.refresh(boardId: 1, sort: sort));
    } else {
      unawaited(postProvider.loadPosts(boardId: 1, sort: sort));
    }
  }

  List<Post> _resolveVisiblePosts(List<Post> posts, String mode) {
    if (_searchQuery.isNotEmpty) return _searchResults;

    // UX-2.8：排序/过滤权威在服务端（sort=time/all/featured/following）。
    // 客户端只做原样透传，不再做 3 天过滤、take(12) 或 createdAt 二次排序，
    // 避免“最新”时间线与服务端不一致。
    return posts;
  }

  Future<void> _refresh() async {
    if (!_currentConfig.supportsRemoteLoading) return;
    if (!_canLoadFeedMode(_feedMode)) return;
    final modeAtStart = _feedMode;
    final sortAtStart = _currentRemoteSort;
    if (sortAtStart == null) return;
    final postProvider = context.read<PostProvider>();
    await Future.wait([
      postProvider.refresh(boardId: 1, sort: sortAtStart),
    ]);
    if (!mounted) return;
    // 如果在刷新期间用户已切换了模式，丢弃本次结果，避免数据污染
    if (_feedMode != modeAtStart) return;
    if (_searchQuery.isNotEmpty) {
      await _runSearch(_searchQuery);
    }
  }

  /// 后台自动刷新语义：先探测，不打断阅读。
  ///
  /// 用户接近顶部时温和应用（与手动刷新同一条路径）；
  /// 已向下浏览时只暂存快照并显示“内容有更新”浮条，由用户决定何时应用。
  Future<void> _probeFeedFreshness() async {
    if (!_currentConfig.supportsRemoteLoading) return;
    if (!_canLoadFeedMode(_feedMode)) return;
    final modeAtStart = _feedMode;
    final sortAtStart = _currentRemoteSort;
    if (sortAtStart == null) return;
    final postProvider = context.read<PostProvider>();

    final controller = _feedScrollControllers[modeAtStart];
    final nearTop = controller?.hasClients != true ||
        controller!.offset < _freshnessNearTopThreshold;
    if (nearTop) {
      await _refresh();
      return;
    }

    final result = await postProvider.probeFreshness(
      boardId: 1,
      sort: sortAtStart,
    );
    if (!mounted || result == null) return;
    if (_feedMode != modeAtStart) {
      // 探测期间用户切换了信息流：丢弃暂存，避免陈旧快照被误应用。
      postProvider.clearPendingFreshSnapshot(boardId: 1, sort: sortAtStart);
      return;
    }
    setState(() {
      _freshnessBannerVisible = true;
      // “最新”信息流的新增数量可信；其它排序可能变化，保守只提示有更新。
      _freshnessBannerLabel = modeAtStart == 'new' && result.newPostCount > 0
          ? '有 ${result.newPostCount} 条新内容'
          : '内容有更新';
    });
  }

  Future<void> _applyFreshnessBanner() async {
    final sortAtStart = _currentRemoteSort;
    if (sortAtStart == null) return;
    final postProvider = context.read<PostProvider>();
    final applied = await postProvider.applyPendingFreshSnapshot(
      boardId: 1,
      sort: sortAtStart,
    );
    if (!mounted) return;
    if (applied) {
      final controller = _feedScrollControllers[_feedMode];
      if (controller?.hasClients == true) {
        controller!.jumpTo(0);
      }
    }
    setState(() {
      _freshnessBannerVisible = false;
    });
  }

  Widget _buildFreshnessBanner() {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      elevation: 3,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: const ValueKey('feed-freshness-banner'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => unawaited(_applyFreshnessBanner()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: colors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                _freshnessBannerLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _ensureCheckinStatusLoaded({bool force = false}) async {
    if (_checkinStatusLoading) return;
    if (!force && _checkinStatusLoaded) return;

    _checkinStatusLoading = true;
    try {
      final succeeded = await _loadCheckinStatus();
      if (mounted && succeeded) {
        _checkinStatusLoaded = true;
      }
    } finally {
      _checkinStatusLoading = false;
    }
  }

  Future<bool> _loadCheckinStatus() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return false;
    try {
      final resp = await auth.dio.get('/user/checkin/status');
      if (resp.statusCode != 200 || !mounted) {
        return false;
      }
      setState(() {
        _checkedIn = resp.data['checked_in'] ?? false;
        _streakDays = resp.data['streak_days'] ?? 0;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleFeedSwipeStart(DragStartDetails details) {
    _feedSwitchController.stop();
    _feedSwipeDx = 0;
    _feedSwipeStartVisualIndex = _currentModeIndex.toDouble();
    _setFeedVisualIndex(_feedSwipeStartVisualIndex);
    setState(() {
      _feedTargetIndex = null;
    });
  }

  void _handleFeedSwipeUpdate(DragUpdateDetails details) {
    _feedSwipeDx += details.primaryDelta ?? 0;
    final targetIndex = _targetFeedIndexForDx(_feedSwipeDx);
    if (targetIndex == null) {
      _feedTargetIndex = null;
      _setFeedVisualIndex(_feedSwipeStartVisualIndex);
      return;
    }

    final width = MediaQuery.sizeOf(context).width;
    final progress = (_feedSwipeDx.abs() / width).clamp(0.0, 1.0);
    _feedTargetIndex = targetIndex;
    _setFeedVisualIndex(
      _feedSwipeStartVisualIndex + (_feedSwipeDx < 0 ? 1 : -1) * progress,
    );
  }

  Future<void> _handleFeedSwipe(DragEndDetails details) async {
    final velocity = details.primaryVelocity ?? 0;
    final nextIndex = _targetFeedIndexForDx(
      velocity.abs() >= _feedTriggerVelocity ? velocity : _feedSwipeDx,
    );
    final shouldSwitch = nextIndex != null &&
        (_feedSwipeDx.abs() >= _feedTriggerDistance ||
            velocity.abs() >= _feedTriggerVelocity);
    _feedSwipeDx = 0;

    if (shouldSwitch) {
      await _changeFeedMode(kFeedModes[nextIndex].key);
    } else {
      await _animateFeedIndicatorTo(_currentModeIndex);
      _feedTargetIndex = null;
    }
  }

  int? _targetFeedIndexForDx(double dx) {
    if (dx == 0) return null;
    final currentIndex = _currentModeIndex;
    if (currentIndex < 0) return null;
    final direction = dx < 0 ? 1 : -1;
    final targetIndex = currentIndex + direction;
    if (targetIndex < 0 || targetIndex >= kFeedModes.length) return null;
    return targetIndex;
  }

  Future<void> _settleFeedMode({
    int? targetIndex,
    required bool commit,
  }) async {
    if (commit && targetIndex != null && targetIndex != _currentModeIndex) {
      await _changeFeedMode(kFeedModes[targetIndex].key);
      return;
    }
    await _animateFeedIndicatorTo(_currentModeIndex);
    _feedTargetIndex = null;
  }

  void _openMessages() {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      Navigator.pushNamed(context, '/login');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatListScreen()),
    );
  }

  void _openWaterSectionDirectoryKeepingPanel() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => const WaterSectionDirectoryScreen(),
      ),
    );
  }

  void _openWaterSectionKeepingPanel(WaterSection section) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => WaterCategoryFeedRoute.fromSection(section),
      ),
    );
  }

  /// 打开页面但不关闭校园服务侧边栏：直接在 rootNavigator 上 push，
  /// 返回时露出下方仍在的侧边栏。与社区版块入口行为一致。
  void _openPageKeepingPanel(Widget page) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  void _openCheckInCalendar() {
    final auth = context.read<AuthProvider>();
    final page = auth.isLoggedIn
        ? CheckInCalendarScreen(autoCheckIn: !_checkedIn)
        : const LoginScreen();
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => page))
        .then((_) {
      if (mounted && auth.isLoggedIn) {
        unawaited(_ensureCheckinStatusLoaded(force: true));
      }
    });
  }

  /// 打开成绩页（保留侧边栏），保留原有的渐入+轻位移+缩放动画与登录判断。
  void _openGradeKeepingPanel() {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn || auth.user == null) {
      _openPageKeepingPanel(const LoginScreen());
      return;
    }

    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => const EduGradeScreen(),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.incoming,
            reverseCurve: AppMotion.outgoing,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.035),
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: 0.995,
                  end: 1.0,
                ).animate(curved),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openHomeServicePanel() async {
    await _ensureCheckinStatusLoaded(force: true);
    if (!mounted) return;

    final themeProvider = context.read<ThemeProvider>();
    final isCustomMode = !themeProvider.isCleanBackgroundMode;

    await showGeneralDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: '关闭校园服务',
      barrierColor: Colors.black.withValues(alpha: isCustomMode ? 0.22 : 0.28),
      transitionDuration: const Duration(milliseconds: 230),
      pageBuilder: (dialogContext, __, ___) {
        final width = MediaQuery.sizeOf(dialogContext).width;

        return Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: (width * 0.86).clamp(0.0, 390.0),
              height: double.infinity,
              child: HomeServiceDrawer(
                checkedIn: _checkedIn,
                streakDays: _streakDays,
                checkInLoading: false,
                showCheckInDot: _showCheckInDot,
                announcements: _announcements,
                unreadAnnouncements: _unreadAnnouncements,
                waterSections:
                    context.read<WaterSectionProvider>().activeSections,
                onCheckIn: () {
                  _closePanelThenOpen(dialogContext, _openCheckInCalendar);
                },
                onOpenToolbox: () {
                  _openPageKeepingPanel(const ToolboxScreen());
                },
                onOpenAnnouncements: _openAnnouncements,
                onOpenCompetitions: () {
                  _openPageKeepingPanel(const CompetitionCenterScreen());
                },
                onOpenGrades: () {
                  _openGradeKeepingPanel();
                },
                onOpenExamSchedule: () {
                  _openPageKeepingPanel(const ExamScheduleScreen());
                },
                onOpenFeedback: () {
                  _openPageKeepingPanel(const FeedbackScreen());
                },
                onOpenWaterSectionDirectory: () {
                  _openWaterSectionDirectoryKeepingPanel();
                },
                onOpenWaterSection: (WaterSection section) {
                  _openWaterSectionKeepingPanel(section);
                },
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, __, child) {
        return SlideTransition(
          position: Tween(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openAnnouncements() async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => AnnouncementScreen(
          onAnnouncementRead: _handleAnnouncementRead,
        ),
      ),
    );
    if (mounted) await _loadAnnouncements();
  }

  void _handleAnnouncementRead(int announcementId) {
    if (!mounted) return;
    setState(() {
      _unreadAnnouncements.removeWhere((item) => item.id == announcementId);
    });
  }

  void _closePanelThenOpen(BuildContext dialogContext, VoidCallback openPage) {
    Navigator.of(dialogContext, rootNavigator: true).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openPage();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authProvider = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final cleanLightMode = themeProvider.isCleanBackgroundMode && !isDark;
    final showCustomBackground = themeProvider.shouldShowCustomBackground;

    // 阅读型首页在简洁模式下使用深色状态栏；自定义背景保留浅色图标。
    SystemChrome.setSystemUIOverlayStyle(
      (cleanLightMode ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light)
          .copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );

    if (authProvider.isLoggedIn != _wasLoggedIn) {
      if (!_wasLoggedIn && authProvider.isLoggedIn) {
        _checkinStatusLoaded = false;
      } else if (_wasLoggedIn && !authProvider.isLoggedIn) {
        _checkinStatusLoaded = false;
        _checkedIn = false;
        _streakDays = 0;
      }
      _wasLoggedIn = authProvider.isLoggedIn;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 登录/退出时清除关注信息流，避免跨账号数据残留
        context.read<PostProvider>().invalidateFollowingFeed();
        if (_currentConfig.supportsRemoteLoading &&
            _canLoadFeedMode(_feedMode)) {
          _refresh();
        }
        _ensureCheckinStatusLoaded();
        _loadAnnouncements();
      });
    }

    final useDesktopShell = ResponsiveUtil.useDesktopShell(context);

    return Scaffold(
      backgroundColor: showCustomBackground
          ? Colors.transparent
          : (isDark ? const Color(0xFF101219) : kCleanWarmBackgroundLight),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          useDesktopShell
              ? _buildDesktopLayout(isDark)
              : _buildMobileLayout(isDark),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧 Master 列表
        Container(
          width: 380,
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.05),
                width: 1,
              ),
            ),
          ),
          child: Stack(children: [_buildMobileLayout(isDark)]),
        ),
        // 右侧 Detail 详情
        Expanded(
          child: _selectedPost == null && _selectedUserId == null
              ? _buildEmptyDetailState(isDark)
              : _buildRightDetailContainer(isDark),
        ),
      ],
    );
  }

  Widget _buildRightDetailContainer(bool isDark) {
    final selectedUserId = _selectedUserId;
    if (selectedUserId != null) {
      return ColoredBox(
        color: isDark ? const Color(0xFF131720) : Colors.white,
        child: UserHomeScreen(
          key: ValueKey('user-$selectedUserId'),
          userId: selectedUserId,
        ),
      );
    }

    final content = ClipRect(
      child: _selectedPost!.isPoll
          ? PollDetailScreen(
              key: ValueKey(_selectedPost!.id),
              pollId: _selectedPost!.pollMeta!.id,
              initialPost: _selectedPost,
              isDesktopSplitMode: true,
              hideBackButton: true,
              onAuthorTap: _openUserInSplit,
            )
          : PostDetailScreen(
              key: ValueKey(_selectedPost!.id),
              postId: _selectedPost!.id,
              isMarket: false,
              initialPost: _selectedPost,
              isDesktopSplitMode: true,
              hideBackButton: true,
              focusReplyComposer: _selectedFocusReply,
              onAuthorTap: _openUserInSplit,
            ),
    );

    return ColoredBox(
      color: isDark ? const Color(0xFF131720) : Colors.white,
      child: content,
    );
  }

  void _openPostInSplit(Post post,
      {bool focusReply = false, String feedKind = '', int position = 0}) {
    if (!mounted) return;
    _finalizeSplitDwell(newPostId: post.id);
    _recordSplitOpen(post, feedKind: feedKind, position: position);
    setState(() {
      _selectedPost = post;
      _selectedUserId = null;
      _selectedFocusReply = focusReply;
    });
    if (focusReply) {
      // PostDetailScreen 在 initState 读取 focusReplyComposer 后重置，
      // 避免同帖重复打开时再次弹键盘。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedFocusReply) {
          setState(() => _selectedFocusReply = false);
        }
      });
    }
  }

  // ── FEED-3 open/dwell 归因 ───────────────────────────────────────

  /// 结束当前分屏帖子的停留计时（切换到另一帖/用户/关闭时调用）。
  void _finalizeSplitDwell({int? newPostId}) {
    final prev = _splitOrigin;
    _splitOrigin = null;
    if (prev == null || (newPostId != null && prev.postId == newPostId)) {
      return;
    }
    final dwellMs = DateTime.now().difference(prev.openedAt).inMilliseconds;
    if (dwellMs > 0) {
      _feedEventService.enqueue(FeedEvent(
        feedSessionId: prev.sessionId,
        feedKind: prev.feedKind,
        algorithmVersion: prev.algorithm,
        type: 'dwell',
        postId: prev.postId,
        dwellMs: dwellMs,
      ));
    }
  }

  /// 记录分屏打开事件的归因上下文。
  void _recordSplitOpen(Post post,
      {required String feedKind, required int position}) {
    final sessionId = _feedSessionService.currentSessionId;
    if (sessionId == null) return;
    final kind = feedKind.isEmpty ? (_currentRemoteSort ?? 'all') : feedKind;
    final algorithm =
        PostCacheService.expectedAlgorithmVersion(boardId: 1, sort: kind);
    _feedEventService.enqueue(FeedEvent(
      feedSessionId: sessionId,
      feedKind: kind,
      algorithmVersion: algorithm,
      type: 'open',
      postId: post.id,
      position: position,
    ));
    _splitOrigin = _SplitOrigin(
      postId: post.id,
      sessionId: sessionId,
      feedKind: kind,
      algorithm: algorithm,
      openedAt: DateTime.now(),
    );
  }

  /// 移动端：打开详情前记 open，返回后记 dwell（不侵入详情页）。
  void _openFeedDetail(Post post,
      {required String sort, required int position}) {
    final sessionId = _feedSessionService.currentSessionId;
    final algorithm =
        PostCacheService.expectedAlgorithmVersion(boardId: 1, sort: sort);
    final openedAt = DateTime.now();
    if (sessionId != null) {
      _feedEventService.enqueue(FeedEvent(
        feedSessionId: sessionId,
        feedKind: sort,
        algorithmVersion: algorithm,
        type: 'open',
        postId: post.id,
        position: position,
      ));
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => post.isPoll
            ? PollDetailScreen(
                pollId: post.pollMeta!.id,
                initialPost: post,
              )
            : PostDetailScreen(
                postId: post.id,
                isMarket: false,
                initialPost: post,
              ),
      ),
    ).then((_) {
      if (sessionId == null || !mounted) return;
      final dwellMs = DateTime.now().difference(openedAt).inMilliseconds;
      if (dwellMs > 0) {
        _feedEventService.enqueue(FeedEvent(
          feedSessionId: sessionId,
          feedKind: sort,
          algorithmVersion: algorithm,
          type: 'dwell',
          postId: post.id,
          dwellMs: dwellMs,
        ));
      }
    });
  }

  void _openUserInSplit(int userId) {
    if (!mounted) return;
    _finalizeSplitDwell();
    if (MediaQuery.of(context).size.width <= 600) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserHomeScreen(userId: userId)),
      );
      return;
    }
    setState(() {
      _selectedPost = null;
      _selectedUserId = userId;
    });
  }

  // ── FEED-3 卡片操作菜单 ──────────────────────────────────────────

  Future<void> _handlePostAction(Post post, FeedPostAction action) async {
    final postProvider = context.read<PostProvider>();
    switch (action) {
      case FeedPostAction.notInterested:
        final source = _currentRemoteSort ?? 'all';
        final undo = await postProvider.markPostNotInterestedOptimistic(
          post,
          source: source,
        );
        if (undo == null) {
          _showFeedSnack('操作失败，请重试');
          return;
        }
        _showUndoSnackBar(
          message: '已减少此帖推荐',
          onUndo: () => unawaited(_undoFeedVisibility(undo)),
        );
      case FeedPostAction.hideAuthor:
        final undo = await postProvider.hideAuthorOptimistic(post.authorId);
        if (undo == null) {
          _showFeedSnack('操作失败，请重试');
          return;
        }
        _showUndoSnackBar(
          message: '已不再展示该用户',
          onUndo: () => unawaited(_undoFeedVisibility(undo)),
        );
      case FeedPostAction.report:
        showReportSheet(context, targetId: post.id, targetType: 'post');
      case FeedPostAction.edit:
        await _openEditPost(post);
      case FeedPostAction.delete:
        await _confirmDeletePost(post);
    }
  }

  Future<void> _openEditPost(Post post) async {
    if (post.isPoll) {
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PollComposerScreen(editingPost: post),
        ),
      );
      return;
    }
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: post.boardId,
          defaultPostType: post.postType,
          editingPost: post,
        ),
      ),
    );
  }

  Future<void> _confirmDeletePost(Post post) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除帖子'),
        content: const Text('删除后不可恢复，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE54848))),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<PostProvider>().deletePost(post.id);
    }
  }

  void _showUndoSnackBar({
    required String message,
    required VoidCallback onUndo,
  }) {
    if (!mounted) return;
    AppFeedback.action(
      message,
      context: context,
      actionLabel: '撤销',
      onAction: onUndo,
    );
  }

  void _showFeedSnack(String message) {
    if (!mounted) return;
    AppFeedback.error(message, context: context);
  }

  Future<void> _undoFeedVisibility(FeedVisibilityUndo undo) async {
    final restored =
        await context.read<PostProvider>().undoFeedVisibility(undo);
    if (!restored && mounted) {
      AppFeedback.error('撤销失败，当前隐藏状态未改变', context: context);
    }
  }

  Widget _buildEmptyDetailState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 80,
            color: isDark ? Colors.white24 : Colors.black12,
          ),
          const SizedBox(height: 16),
          Text(
            '点击左侧帖子查看详情',
            style: TextStyle(
              fontSize: 16,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedTabs(bool isDark) {
    const tabWidth = 48.0;
    final activeColor = isDark ? Colors.white : Colors.black87;
    final inactiveColor = isDark ? Colors.white54 : Colors.black45;

    return SizedBox(
      width: tabWidth * kFeedModes.length,
      height: 44,
      child: ValueListenableBuilder<double>(
        valueListenable: _feedVisualIndexListenable,
        builder: (context, visualIndex, child) {
          return Stack(
            children: [
              // 只有 indicator 订阅连续进度，内容状态在点击时立即更新。
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Transform.translate(
                    offset: Offset(visualIndex * tabWidth, 0),
                    child: SizedBox(
                      width: tabWidth,
                      height: 3,
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: List.generate(kFeedModes.length, (index) {
                  final config = kFeedModes[index];
                  final activeT = (1 - (visualIndex - index).abs()).clamp(
                    0.0,
                    1.0,
                  );
                  final color =
                      Color.lerp(inactiveColor, activeColor, activeT)!;

                  return SizedBox(
                    width: tabWidth,
                    height: 44,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        unawaited(_changeFeedMode(config.key));
                      },
                      child: Center(
                        child: Text(
                          config.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: activeT > 0.5
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- 顶部导航栏 ----
  Widget _buildHomeTopBar(bool isDark) {
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 左侧三横线
          Positioned(
            left: 12,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    onPressed: _openHomeServicePanel,
                    icon: Icon(
                      Icons.menu_rounded,
                      size: 26,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  if (_showCheckInDot || _unreadAnnouncements.isNotEmpty)
                    Positioned(
                      top: 9,
                      right: 8,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isDark ? Colors.black87 : Colors.white,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 中间标签（独立居中）
          Center(child: _buildFeedTabs(isDark)),
          // 右侧私信图标
          Positioned(
            right: 12,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Consumer<MessageProvider>(
                builder: (context, msgProvider, _) {
                  final hasUnread = msgProvider.conversations.any(
                    (c) => c.unreadCount > 0,
                  );
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        onPressed: _openMessages,
                        icon: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 25,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      if (hasUnread)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Mobile Layout ----
  Widget _buildMobileLayout(bool isDark) {
    return SafeArea(
      top: true,
      bottom: false,
      child: Column(
        children: [
          // 顶部栏固定，不参与滚动，保持透明
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildHomeTopBar(isDark),
          ),
          // 内容区
          Expanded(child: _buildFeedContent(isDark)),
        ],
      ),
    );
  }

  Widget _buildFollowingDashboard(
      bool isDark, List<Post> posts, bool isFeedLoading) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('关注动态',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
              GestureDetector(
                onTap: () {
                  setState(() => _followingExpanded = true);
                },
                child: Row(
                  children: [
                    Text('全部',
                        style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white54 : Colors.black54)),
                    Icon(Icons.chevron_right,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black54),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (posts.isEmpty && !isFeedLoading)
            Container(
              height: 100,
              width: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1F2937) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.grey.withValues(alpha: 0.2)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('还没有关注动态',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white70 : Colors.black87)),
                  const SizedBox(height: 4),
                  Text('关注的人和版块有新动态时，会显示在这里',
                      style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white54 : Colors.black54)),
                ],
              ),
            )
          else if (posts.isNotEmpty)
            ...posts.take(2).toList().asMap().entries.map((entry) {
              final post = entry.value;
              final position = entry.key;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: CommunityPostCard(
                  post: post,
                  onAuthorTap: _openUserInSplit,
                  onPostAction: (action) => _handlePostAction(post, action),
                  allowNotInterested: false,
                  onTap: () {
                    if (ResponsiveUtil.useDesktopShell(context)) {
                      _openPostInSplit(post,
                          feedKind: 'following', position: position);
                    } else {
                      _openFeedDetail(post,
                          sort: 'following', position: position);
                    }
                  },
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildCommunitySectionsGrid(bool isDark) {
    final sections = context.watch<WaterSectionProvider>().sections;
    final displaySections = sections.isNotEmpty
        ? sections
        : kWaterPostCategories
            .map((c) => WaterSection.fromLegacyCategory(c))
            .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('社区版块',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WaterSectionDirectoryScreen(),
                    ),
                  );
                },
                child: Row(
                  children: [
                    Text('全部',
                        style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white54 : Colors.black54)),
                    Icon(Icons.chevron_right,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black54),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 74,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: displaySections.length,
            itemBuilder: (context, index) {
              final section = displaySections[index];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          WaterCategoryFeedRoute.fromSection(section),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1F2937) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.grey.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    children: [
                      SectionAvatar(
                        section: section,
                        size: 36,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              section.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            if (section.subtitle.isNotEmpty)
                              Text(
                                section.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      isDark ? Colors.white54 : Colors.black54,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildExpandedFollowingHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black87),
            onPressed: () => setState(() => _followingExpanded = false),
          ),
          const SizedBox(width: 4),
          Text('关注动态',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87)),
        ],
      ),
    );
  }

  // ---- 关注模式未登录占位 ----
  Widget _buildFollowingPlaceholder(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.login_rounded,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '登录后查看关注动态',
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '关注感兴趣的同学，他们发布的内容会显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.grey[400],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.pushNamed(context, '/login'),
              icon: const Icon(Icons.login, size: 18),
              label: const Text('去登录'),
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

  // ---- 关注模式已登录但无帖子 ----
  Widget _buildFollowingEmptyState(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline_rounded,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '还没有关注动态',
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '关注的人和版块有新动态时，会显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.grey[400],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () {
                _openHomeServicePanel();
              },
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('探索版块'),
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

  // ---- 普通信息流内容（含搜索框折叠） ----
  Widget _buildFeedContent(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _handleFeedSwipeStart,
      onHorizontalDragUpdate: _handleFeedSwipeUpdate,
      onHorizontalDragEnd: _handleFeedSwipe,
      onHorizontalDragCancel: () {
        _feedSwipeDx = 0;
        unawaited(_settleFeedMode(
          targetIndex: _feedTargetIndex,
          commit: false,
        ));
      },
      child: RefreshIndicator(
        onRefresh: () async {
          await _refresh();
          await _loadAnnouncements();
        },
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: _buildFeedModePage(isDark, _feedMode),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedModePage(bool isDark, String mode) {
    _scheduleRestoredScroll();
    final config = kFeedModes.firstWhere((m) => m.key == mode);
    final sort = config.remoteSort ?? 'all';

    return _buildFeedModeList(isDark, mode, config, sort);
  }

  Widget _buildFeedModeList(
    bool isDark,
    String mode,
    FeedModeConfig config,
    String sort,
  ) {
    final feedList = Selector<
        PostProvider,
        ({
          List<Post> posts,
          bool isLoading,
          bool hasMore,
          String? error,
          int revision
        })>(
      selector: (context, postProvider) {
        return (
          posts: postProvider.postsFor(1, sort: sort),
          isLoading: postProvider.isLoadingFor(1, sort: sort),
          hasMore: postProvider.hasMoreFor(1, sort: sort),
          error: postProvider.errorFor(1, sort: sort),
          revision: postProvider.revisionFor(1, sort: sort),
        );
      },
      builder: (context, data, child) {
        final posts = data.posts;
        final isFeedLoading = data.isLoading;
        final feedHasMore = data.hasMore;
        final feedError = data.error;
        final visiblePosts = _resolveVisiblePosts(posts, mode);

        final explicitPinnedPosts =
            context.read<PostProvider>().pinnedPostsFor(1, sort: sort);
        final legacyPinnedPosts =
            visiblePosts.where((post) => post.isActivePinned).toList();
        final pinnedPosts = explicitPinnedPosts.isNotEmpty
            ? explicitPinnedPosts
            : legacyPinnedPosts;
        final pinnedIds = pinnedPosts.map((post) => post.id).toSet();
        final normalPosts = visiblePosts
            .where((post) => !pinnedIds.contains(post.id))
            .where((post) => !post.isActivePinned)
            .toList();

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final canLoadMore =
                mode != 'following' || context.read<AuthProvider>().isLoggedIn;
            if (config.supportsRemoteLoading &&
                notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 500 &&
                feedHasMore &&
                !isFeedLoading &&
                canLoadMore) {
              context.read<PostProvider>().loadPosts(
                    boardId: 1,
                    sort: sort,
                  );
            }
            return false;
          },
          child: CustomScrollView(
            key: PageStorageKey<String>('home-feed-scroll-$mode'),
            controller: _feedScrollControllers[mode],
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                floating: true,
                delegate: _SliverSearchBarDelegate(
                  vsync: this,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                    child: _buildSearchBar(isDark),
                  ),
                ),
              ),
              if (_freshnessBannerVisible)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SliverFreshnessBannerDelegate(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                      child: Center(child: _buildFreshnessBanner()),
                    ),
                  ),
                ),
              if (mode == 'following' && !_followingExpanded) ...[
                if (!context.read<AuthProvider>().isLoggedIn)
                  SliverToBoxAdapter(
                    child: _buildFollowingPlaceholder(isDark),
                  )
                else
                  SliverToBoxAdapter(
                    child: _buildFollowingDashboard(
                        isDark, normalPosts, isFeedLoading),
                  ),
                SliverToBoxAdapter(
                  child: _buildCommunitySectionsGrid(isDark),
                ),
              ] else ...[
                if (mode == 'following' && _followingExpanded)
                  SliverToBoxAdapter(
                    child: _buildExpandedFollowingHeader(isDark),
                  ),
                if (mode == 'following' &&
                    !context.read<AuthProvider>().isLoggedIn)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildFollowingPlaceholder(isDark),
                  )
                else if (isFeedLoading && posts.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (feedError != null && posts.isEmpty)
                  SliverFillRemaining(
                    child: _buildEmptyState(
                      isDark,
                      title: '帖子加载失败',
                      subtitle: feedError,
                      onRetry: _refresh,
                    ),
                  )
                else if (pinnedPosts.isEmpty && normalPosts.isEmpty)
                  SliverFillRemaining(
                    child: mode == 'following'
                        ? _buildFollowingEmptyState(isDark)
                        : _buildEmptyState(
                            isDark,
                            title:
                                _searchQuery.isNotEmpty ? '没有找到匹配帖子' : '暂无帖子',
                            subtitle: _searchQuery.isNotEmpty
                                ? '目前只按帖子标题搜索，换个标题关键词试试'
                                : '发布第一条帖子吧',
                            onRetry: _refresh,
                          ),
                  )
                else ...[
                  if (pinnedPosts.isNotEmpty)
                    SliverToBoxAdapter(
                      child: PinnedPostSummaryBar(
                        posts: pinnedPosts,
                        isDark: isDark,
                        label: '置顶',
                        onOpenPost: (post) {
                          if (ResponsiveUtil.useDesktopShell(context)) {
                            _openPostInSplit(post);
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PostDetailScreen(
                                  postId: post.id,
                                  isMarket: false,
                                  initialPost: post,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final post = normalPosts[index];
                      final isSelected = _selectedPost?.id == post.id &&
                          _selectedUserId == null &&
                          ResponsiveUtil.useDesktopShell(context);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Container(
                          decoration: isSelected
                              ? BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Theme.of(context)
                                          .primaryColor
                                          .withValues(alpha: 0.15),
                                      blurRadius: 20,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                )
                              : null,
                          child: FeedExposureTracker(
                            post: post,
                            feedKind: sort,
                            position: index,
                            algorithmVersion:
                                PostCacheService.expectedAlgorithmVersion(
                              boardId: 1,
                              sort: sort,
                            ),
                            sessionService: _feedSessionService,
                            eventService: _feedEventService,
                            child: CommunityPostCard(
                              post: post,
                              onAuthorTap: _openUserInSplit,
                              onPostAction: (action) =>
                                  _handlePostAction(post, action),
                              allowNotInterested: sort == 'all',
                              onCommentTap: (commentPost) {
                                if (ResponsiveUtil.useDesktopShell(context)) {
                                  _openPostInSplit(commentPost,
                                      focusReply: true);
                                } else {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => PostDetailScreen(
                                        postId: commentPost.id,
                                        isMarket: false,
                                        initialPost: commentPost,
                                        focusReplyComposer: true,
                                      ),
                                    ),
                                  );
                                }
                              },
                              onTap: () {
                                if (_exitSearchInputMode()) {
                                  return;
                                }
                                if (ResponsiveUtil.useDesktopShell(context)) {
                                  _openPostInSplit(post,
                                      feedKind: sort, position: index);
                                } else {
                                  _openFeedDetail(post,
                                      sort: sort, position: index);
                                }
                              },
                            ),
                          ),
                        ),
                      );
                    }, childCount: normalPosts.length),
                  ),
                ],
              ],
              if (isFeedLoading && posts.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(
                child: SizedBox(height: 80),
              ),
            ],
          ),
        );
      },
    );

    // Feed 是高频筛选路径：内容立即替换，不对帖子逐条重播 reveal。
    return feedList;
  }

  Widget _buildSearchBar(bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      borderRadius: 50,
      blur: 8,
      opacity: 1,
      backgroundColor: isDark ? const Color(0xE6171B24) : Colors.white,
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.12)
          : const Color(0xFFEEF0F5),
      child: TextField(
        key: const ValueKey('feed-search-field'),
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onSearchChanged,
        onSubmitted: _runSearch,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          hintText: '搜索帖子标题关键词',
          hintStyle: const TextStyle(fontSize: 14),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    bool isDark, {
    required String title,
    required String subtitle,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
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
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.grey[400],
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新试试'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- 搜索框固定 SliverPersistentHeaderDelegate ----
class _SliverSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final TickerProvider _vsync;
  final Widget child;

  _SliverSearchBarDelegate({required TickerProvider vsync, required this.child})
      : _vsync = vsync;

  @override
  double get maxExtent => 46;

  @override
  double get minExtent => 46;

  @override
  FloatingHeaderSnapConfiguration get snapConfiguration =>
      FloatingHeaderSnapConfiguration(
        curve: Curves.easeOut,
        duration: const Duration(milliseconds: 200),
      );

  @override
  TickerProvider get vsync => _vsync;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final visibleFraction = (1.0 - shrinkOffset / maxExtent).clamp(0.0, 1.0);
    return Opacity(
      opacity: visibleFraction,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: visibleFraction,
        child: child,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SliverSearchBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

class _SliverFreshnessBannerDelegate extends SliverPersistentHeaderDelegate {
  const _SliverFreshnessBannerDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 54;

  @override
  double get maxExtent => 54;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _SliverFreshnessBannerDelegate oldDelegate) =>
      oldDelegate.child != child;
}

class CheckInSuccessDialog extends StatelessWidget {
  final int streakDays;
  final int earnedExp;

  const CheckInSuccessDialog({
    super.key,
    required this.streakDays,
    required this.earnedExp,
  });

  String buildMilestoneText(int days) {
    const milestones = [7, 14, 30, 50, 100, 180, 365];

    final next = milestones.firstWhere(
      (value) => value > days,
      orElse: () => 0,
    );

    if (next == 0) {
      return '已完成全部签到里程碑';
    }

    return '距离连续签到 $next 天还差 ${next - days} 天';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Dialog(
      elevation: 0,
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 304),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1D1F24) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: isDark ? 0.28 : 0.12,
                ),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF3A3020)
                      : const Color(0xFFFFF3DC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.celebration_rounded,
                  size: 24,
                  color: Color(0xFFF59E0B),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '签到成功',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF1F2937),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '已连续签到',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF8B909A),
                ),
              ),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$streakDays',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFF59E0B),
                        height: 1.0,
                      ),
                    ),
                    TextSpan(
                      text: ' 天',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF4B5563),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF31291D)
                      : const Color(0xFFFFF6E6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.bolt_rounded,
                      size: 16,
                      color: Color(0xFFF59E0B),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '+$earnedExp',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFF59E0B),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '经验已到账',
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            isDark ? Colors.white60 : const Color(0xFF7B808A),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                buildMilestoneText(streakDays),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : const Color(0xFF9AA0AA),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    '继续保持',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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

/// FEED-3 桌面分屏打开帖子的归因上下文。
class _SplitOrigin {
  _SplitOrigin({
    required this.postId,
    required this.sessionId,
    required this.feedKind,
    required this.algorithm,
    required this.openedAt,
  });

  final int postId;
  final String sessionId;
  final String feedKind;
  final String algorithm;
  final DateTime openedAt;
}
