import 'dart:async';

import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../platform/contracts/external_navigator.dart';
import '../config/api_constants.dart';
import '../app_bootstrap.dart';
import '../models/post.dart';
import '../models/startup_destination.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../services/app_update_coordinator.dart';
import '../services/root_page_state_service.dart';
import '../theme/app_motion.dart';
import '../utils/app_navigator.dart';
import '../utils/app_feedback.dart';
import '../utils/post_image_cache.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/glass_container.dart';
import '../widgets/home_tab_reveal.dart';
import '../utils/responsive_util.dart';
import '../utils/tab_transition_ledger.dart';
import 'shuitie_screen.dart';
import 'market_screen.dart';
import 'course_schedule_screen.dart';
import 'campus_screen.dart';
import 'profile_screen.dart';
import 'chat_detail_screen.dart';
import 'post_detail_screen.dart';
import 'notifications_screen.dart';
import 'create_post_screen.dart';
import 'poll/poll_composer_screen.dart';
import 'publish/publish_type_sheet.dart';
import 'image_viewer_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 首页首屏请求结束后再检查更新，避免更新状态覆盖开屏与帖子加载过程。
Future<void> loadInitialFeedBeforeUpdateCheck({
  required Future<void> Function() loadInitialFeed,
  required Future<void> Function() initializeUpdateCheck,
}) async {
  try {
    await loadInitialFeed();
  } catch (error) {
    debugPrint('首页帖子首次加载失败，继续执行更新检查: $error');
  }
  await initializeUpdateCheck();
}

/// 公告中断语义：只有 urgent 可以弹窗主动打断用户。
///
/// urgent → modal；important → banner / badge；normal → badge / 公告中心。
/// important + modal 属于无效组合（服务端 has_urgent 也只统计 urgent），
/// 客户端弹窗候选严格收敛为 urgent。
@visibleForTesting
bool isModalAnnouncementCandidate(Map<String, dynamic> item) {
  final priority = item['priority']?.toString() ?? '';
  final displayMode = item['display_mode']?.toString() ?? '';
  return priority == 'urgent' &&
      (displayMode == 'modal' || displayMode.isEmpty);
}

class HomeScreen extends StatefulWidget {
  final int initialTab;

  /// `lastPage` 模式下首屏要直接进入的深层页面（私信/帖子/通知）。
  ///
  /// 非空时 HomeScreen 以正确 [initialTab] 打底，在首帧后推入该页面，
  /// 返回后落在对应的 root tab。
  final RestorablePageState? initialDeepPage;
  const HomeScreen({super.key, this.initialTab = 0, this.initialDeepPage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class HomeTabKeepAliveStage extends StatelessWidget {
  const HomeTabKeepAliveStage({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: IndexedStack(
        index: index,
        children: children,
      ),
    );
  }
}

/// 启动恢复遮罩：在首屏深层页面（私信/帖子/通知）未完全覆盖前呈现，
/// 彻底避免底层 root tab 闪烁 1 帧。
class StartupNavigationGate extends StatelessWidget {
  const StartupNavigationGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final TabTransitionLedger _mainTabLedger;
  PageRoute<dynamic>? _subscribedRoute;
  bool _publishOpening = false;
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'homeContentStack');
  final Map<int, Widget> _tabPages = {};
  late final AnimationController _mainTabController;
  late final AnimationController _contentTabController;
  late final ValueNotifier<double> _mainVisualIndexListenable;
  Animation<double>? _mainTabAnimation;
  double _mainAnimationStartVisualIndex = 0;
  double _mainAnimationEndVisualIndex = 0;
  Timer? _announcementTimer;
  Timer? _announcementRetryTimer;
  Timer? _initialUpdateFallbackTimer;
  String? _announcementAuthKey;
  bool _isCheckingAnnouncements = false;
  bool _announcementDialogOpen = false;
  final Set<int> _dismissedAnnouncementIds = {};
  final Set<int> _seenAnnouncementIds = {};
  String? _announcementSeenKey;
  late final bool _hasWidgetTabOverride;
  bool _restoringInitialDeepPage = false;

  // Unread badge state
  int _unreadBadgeCount = 0;
  bool _hasUrgentUnread = false;
  bool _hasAdminTasks = false;

  int get _currentIndex => _mainTabLedger.currentIndex;
  set _currentIndex(int value) => _mainTabLedger.currentIndex = value;
  Set<int> get _visitedTabs => _mainTabLedger.visitedTabs;
  Set<int> get _revealedTabs => _mainTabLedger.revealedTabs;
  int? get _mainTargetIndex => _mainTabLedger.targetIndex;
  set _mainTargetIndex(int? value) => _mainTabLedger.targetIndex = value;
  int get _tabTransitionSerial => _mainTabLedger.serial;
  set _tabTransitionSerial(int value) => _mainTabLedger.serial = value;
  double get _mainVisualIndex => _mainTabLedger.visualIndex;
  set _mainVisualIndex(double value) => _mainTabLedger.visualIndex = value;

  Future<void> _checkAdminTasks(AuthProvider auth) async {
    try {
      final futures = await Future.wait([
        auth.dio.get('/teachers/pending').catchError((_) =>
            Response(requestOptions: RequestOptions(path: ''), data: [])),
        auth.dio.get('/majors/pending').catchError((_) =>
            Response(requestOptions: RequestOptions(path: ''), data: [])),
        auth.dio.get('/admin/invitations/pending').catchError((_) =>
            Response(requestOptions: RequestOptions(path: ''), data: [])),
        auth.dio.get('/admin/removals/pending').catchError((_) =>
            Response(requestOptions: RequestOptions(path: ''), data: [])),
      ]);
      int count = 0;
      if (futures[0].data is List) count += (futures[0].data as List).length;
      if (futures[1].data is List) count += (futures[1].data as List).length;
      if (futures[2].data is List)
        count +=
            (futures[2].data as List).where((i) => i['my_vote'] != true).length;
      if (futures[3].data is List)
        count += (futures[3].data as List)
            .where((r) => r['can_vote'] == true)
            .length;

      if (auth.user?.isSuperAdmin == true) {
        final superRes = await auth.dio
            .get('/super/invitations/pending')
            .catchError((_) =>
                Response(requestOptions: RequestOptions(path: ''), data: []));
        if (superRes.data is List)
          count +=
              (superRes.data as List).where((i) => i['my_vote'] != true).length;
      }

      if (mounted && _hasAdminTasks != (count > 0)) {
        setState(() => _hasAdminTasks = count > 0);
      }
    } catch (_) {}
  }

  // Snooze: keyed by userId:announcementId in AppPreferencesStore
  static const _snoozePrefix = 'announcement_snooze_';
  static const _snoozeDuration = Duration(hours: 4);
  // Fallback polling interval (keep until JPush trigger is implemented)
  static const _announcementPollInterval = Duration(minutes: 15);
  static const _announcementRetryDelay = Duration(seconds: 15);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _subscribedRoute)) {
      if (_subscribedRoute != null) {
        appRouteObserver.unsubscribe(this);
      }
      _subscribedRoute = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void initState() {
    super.initState();
    _hasWidgetTabOverride = consumeWidgetTabSwitch();
    _mainTabLedger = TabTransitionLedger(
      itemCount: 5,
      initialIndex:
          (_hasWidgetTabOverride ? 2 : widget.initialTab).clamp(0, 4).toInt(),
    );
    _mainVisualIndex = _currentIndex.toDouble();
    currentHomeTabIndex.value = _currentIndex;
    _mainVisualIndexListenable = ValueNotifier(_mainVisualIndex);
    _mainTabController = AnimationController(
      vsync: this,
      duration: AppMotion.tab,
    )..addListener(_handleMainTabAnimationTick);
    _contentTabController = AnimationController(
      vsync: this,
      duration: AppMotion.normal,
      value: 1,
    );
    widgetTabSwitch.addListener(_onWidgetTabSwitch);
    WidgetsBinding.instance.addObserver(this);
    // 冷启动打底 tab 由启动计划（_AuthWrapperState）决定；
    // 明确导航意图（桌面小组件/通知/深链）由 widgetTabSwitch 与后续深链回调处理。
    final deepPage = widget.initialDeepPage;
    _restoringInitialDeepPage = deepPage != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bootstrapHome();
      if (deepPage != null) {
        _pushRestoredDeepPage(deepPage);
      }
    });
  }

  void _releaseStartupNavigationGateAfterPush() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_restoringInitialDeepPage) return;
      setState(() {
        _restoringInitialDeepPage = false;
      });
    });
  }

  /// 首屏直接进入上次退出时的深层页面（私信/帖子/通知）。
  /// 使用 0ms 路由过渡与全屏门禁遮罩，确保冷启动恢复直达页面，不闪烁底层 Tab。
  void _pushRestoredDeepPage(RestorablePageState state) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      if (mounted) setState(() => _restoringInitialDeepPage = false);
      return;
    }
    switch (state.type) {
      case RestorablePageType.rootTab:
        if (mounted) setState(() => _restoringInitialDeepPage = false);
        return;
      case RestorablePageType.chat:
        final conversationId = state.arguments['conversationId'] as int?;
        final targetUserId = state.arguments['targetUserId'] as int?;
        if (conversationId == null ||
            conversationId <= 0 ||
            targetUserId == null ||
            targetUserId <= 0) {
          if (mounted) setState(() => _restoringInitialDeepPage = false);
          break;
        }
        navigator.push<void>(
          PageRouteBuilder<void>(
            opaque: true,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            settings: RouteSettings(
              name: '/messages/conversations/$conversationId',
            ),
            pageBuilder: (_, __, ___) => ChatDetailScreen(
              conversationId: conversationId,
              targetUser: User(
                id: targetUserId,
                studentId: '',
                nickname: (state.arguments['targetNickname'] ?? '').toString(),
                avatar: (state.arguments['targetAvatar'] ?? '').toString(),
                createdAt: DateTime.now(),
              ),
            ),
          ),
        );
        _releaseStartupNavigationGateAfterPush();
      case RestorablePageType.post:
        final postId = state.arguments['postId'] as int?;
        if (postId == null || postId <= 0) {
          if (mounted) setState(() => _restoringInitialDeepPage = false);
          break;
        }
        navigator.push<void>(
          PageRouteBuilder<void>(
            opaque: true,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            settings: const RouteSettings(name: '/post/detail'),
            pageBuilder: (_, __, ___) => PostDetailScreen(postId: postId),
          ),
        );
        _releaseStartupNavigationGateAfterPush();
      case RestorablePageType.notification:
        navigator.push<void>(
          PageRouteBuilder<void>(
            opaque: true,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            settings: const RouteSettings(name: '/notifications'),
            pageBuilder: (_, __, ___) => const NotificationsScreen(),
          ),
        );
        _releaseStartupNavigationGateAfterPush();
    }
  }

  void _bootstrapHome() {
    final auth = context.read<AuthProvider>();

    final postProvider = context.read<PostProvider>();
    final updateCoordinator = context.read<AppUpdateCoordinator>();
    _initialUpdateFallbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        unawaited(updateCoordinator.startDeferredInitialCheck());
      }
    });
    unawaited(loadInitialFeedBeforeUpdateCheck(
      loadInitialFeed: () => postProvider.loadPosts(boardId: 1, sort: 'all'),
      initializeUpdateCheck: () {
        _initialUpdateFallbackTimer?.cancel();
        return updateCoordinator.startDeferredInitialCheck();
      },
    ));

    // 1. 当前页仍按原逻辑加载；相同的帖子请求由 PostProvider 自动合并。

    // 2. Delay lightweight badges (notices unread-count, messages unread-count)
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _syncAnnouncementPolling(auth, skipAdminTasks: true);
      // Ensure messages are loaded for unread badge
      if (auth.isLoggedIn) {
        context.read<MessageProvider>().loadConversations(silent: true);
      }
    });

    // 3. Delay heavier admin pending checks and other background tasks
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      if (auth.isLoggedIn && auth.user?.isAdmin == true) {
        _checkAdminTasks(auth);
      }
    });
  }

  void _onWidgetTabSwitch() {
    consumeWidgetTabSwitch();
    if (mounted && _currentIndex != 2) {
      _switchTab(2);
    }
  }

  @override
  void dispose() {
    widgetTabSwitch.removeListener(_onWidgetTabSwitch);
    final subscribedRoute = _subscribedRoute;
    if (subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _mainTabController
      ..removeListener(_handleMainTabAnimationTick)
      ..dispose();
    _contentTabController.dispose();
    _mainVisualIndexListenable.dispose();
    _announcementTimer?.cancel();
    _announcementRetryTimer?.cancel();
    _initialUpdateFallbackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _tabTransitionSerial++;
      _contentTabController.stop();
      _mainTabController.stop();
      _currentIndex = widget.initialTab;
      _mainTargetIndex = null;
      _mainVisualIndex = _currentIndex.toDouble();
      _mainVisualIndexListenable.value = _mainVisualIndex;
      _mainAnimationStartVisualIndex = _mainVisualIndex;
      _mainAnimationEndVisualIndex = _mainVisualIndex;
      _visitedTabs.add(_currentIndex);
      _revealedTabs.add(_currentIndex);
      _getOrCreateTabPage(_currentIndex);
      currentHomeTabIndex.value = _currentIndex;
    }
  }

  @override
  void didPopNext() {
    // 从深层页面（私信/帖子/通知）返回：底层 root tab 重新可见，
    // 由它自己保存「上次退出页面」，替代私信里硬编码的课表 index。
    _saveCurrentTabAsLastPage();
  }

  /// 仅在 `lastPage` 启动模式下，把当前 root tab 保存为 lastPage。
  /// 最佳努力：读取失败（如测试用 Fake Provider）时静默跳过，不影响页面。
  Future<void> _saveCurrentTabAsLastPage() async {
    try {
      if (context.read<ThemeProvider>().startupDestination !=
          StartupDestinationMode.lastPage) {
        return;
      }
      final accountId = context.read<AuthProvider>().user?.id;
      if (accountId == null || accountId <= 0) return;
      await RootPageStateStore.instance.saveLastPage(
        RestorablePageState(
          type: RestorablePageType.rootTab,
          arguments: <String, dynamic>{'index': _currentIndex},
          accountId: accountId,
        ),
      );
    } catch (_) {
      // 忽略：不影响 Tab 切换。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkUnreadAnnouncements();
    }
  }

  void _syncAnnouncementPolling(AuthProvider auth,
      {bool skipAdminTasks = false}) {
    final authKey = auth.isLoggedIn ? '${auth.user?.id}:${auth.token}' : null;
    if (_announcementAuthKey == authKey) return;

    _announcementAuthKey = authKey;
    _announcementSeenKey =
        auth.isLoggedIn ? 'seen_announcements_${auth.user?.id}' : null;
    _dismissedAnnouncementIds.clear();
    _seenAnnouncementIds.clear();
    _announcementTimer?.cancel();
    _announcementTimer = null;
    _announcementRetryTimer?.cancel();
    _announcementRetryTimer = null;
    _updateBadge(0, false);

    if (authKey == null) return;

    unawaited(_initializeAnnouncementPolling(skipAdminTasks: skipAdminTasks));
  }

  Future<void> _initializeAnnouncementPolling(
      {bool skipAdminTasks = false}) async {
    await _loadSeenAnnouncements();
    if (!mounted) return;
    await _checkUnreadAnnouncements(skipAdminTasks: skipAdminTasks);
    if (!mounted) return;
    _announcementTimer = Timer.periodic(
      _announcementPollInterval,
      (_) => _checkUnreadAnnouncements(),
    );
  }

  Future<void> _loadSeenAnnouncements() async {
    final key = _announcementSeenKey;
    if (key == null) return;
    final prefs = await AppPreferencesStore.getInstance();
    final stored = prefs.getStringList(key) ?? const [];
    _seenAnnouncementIds
      ..clear()
      ..addAll(stored.map(int.tryParse).whereType<int>());
  }

  Future<void> _saveSeenAnnouncements() async {
    final key = _announcementSeenKey;
    if (key == null) return;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setStringList(
      key,
      _seenAnnouncementIds.map((id) => id.toString()).toList(),
    );
  }

  Future<void> _markAnnouncementsSeen(Iterable<dynamic> announcements) async {
    var changed = false;
    for (final item in announcements) {
      final id = _announcementId(item);
      if (id > 0 && _seenAnnouncementIds.add(id)) {
        changed = true;
      }
    }
    if (changed) {
      await _saveSeenAnnouncements();
    }
  }

  Future<List<dynamic>> _fetchAnnouncementsFallback(AuthProvider auth) async {
    var resp;
    try {
      resp = await auth.dio.get(ApiConstants.noticesPath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        resp = await auth.dio.get('/announcements');
      } else {
        rethrow;
      }
    }
    final list = (resp.data as List?) ?? const [];
    return list
        .where((item) => !_seenAnnouncementIds.contains(_announcementId(item)))
        .toList();
  }

  Future<List<dynamic>> _loadUnreadAnnouncements(AuthProvider auth) async {
    try {
      var resp;
      try {
        resp = await auth.dio.get('${ApiConstants.noticesPath}/unread');
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          resp = await auth.dio.get('/announcements/unread');
        } else {
          rethrow;
        }
      }
      return (resp.data as List?) ?? const [];
    } on DioException catch (e) {
      final isBadUnreadRoute = e.response?.statusCode == 400 &&
          e.response?.data is Map &&
          (e.response!.data['error']?.toString().contains('无效的公告ID') ?? false);
      if (isBadUnreadRoute) {
        debugPrint('未读公告接口异常，降级到 ${ApiConstants.noticesPath}');
        return _fetchAnnouncementsFallback(auth);
      }
      rethrow;
    }
  }

  Future<void> _checkUnreadAnnouncements({bool skipAdminTasks = false}) async {
    if (!mounted || _isCheckingAnnouncements || _announcementDialogOpen) {
      return;
    }

    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      _syncAnnouncementPolling(auth);
      if (_hasAdminTasks) setState(() => _hasAdminTasks = false);
      return;
    }

    _isCheckingAnnouncements = true;
    try {
      if (!skipAdminTasks) {
        if (auth.user?.isAdmin == true) {
          _checkAdminTasks(auth);
        } else if (_hasAdminTasks) {
          setState(() => _hasAdminTasks = false);
        }
      }
      // 1. Get lightweight unread count first
      final countResult = await _fetchUnreadCount(auth);
      if (countResult == null) {
        _scheduleAnnouncementRetry();
        return;
      }
      _announcementRetryTimer?.cancel();
      _announcementRetryTimer = null;
      final count = (countResult['count'] as num?)?.toInt() ?? 0;
      final hasUrgent = countResult['has_urgent'] == true;
      _updateBadge(count, hasUrgent);

      if (count == 0 || !mounted) return;

      // 2. Only auto-popup for the single highest-priority modal/urgent announcement
      if (hasUrgent) {
        final unread = await _loadUnreadAnnouncements(auth);
        if (unread.isEmpty || !mounted) return;

        // Filter for modal/urgent announcements that are not dismissed/seen/snoozed
        final candidates = unread.where((item) {
          final id = _announcementId(item);
          if (_dismissedAnnouncementIds.contains(id)) return false;
          if (_seenAnnouncementIds.contains(id)) return false;
          return isModalAnnouncementCandidate(item);
        }).toList();

        if (candidates.isNotEmpty) {
          final top = candidates.first;
          final topId = _announcementId(top);
          if (!(await _isSnoozed(topId, auth.user?.id ?? 0))) {
            await _showSingleUrgentModal(top);
            // Do NOT chain another modal — next check will catch remaining
          }
        }
      }
    } catch (e) {
      debugPrint('检查未读公告失败: $e');
    } finally {
      _isCheckingAnnouncements = false;
    }
  }

  int _announcementId(dynamic announcement) {
    final id = announcement is Map ? announcement['id'] : null;
    if (id is int) return id;
    if (id is num) return id.toInt();
    return int.tryParse(id?.toString() ?? '') ?? -1;
  }

  String _announcementTime(dynamic announcement) {
    if (announcement is! Map) return '';
    final raw = announcement['created_at']?.toString() ?? '';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return '';
    final mm = parsed.month.toString().padLeft(2, '0');
    final dd = parsed.day.toString().padLeft(2, '0');
    final hh = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  Widget _priorityBadge({required String priority, required bool isDark}) {
    final isUrgent = priority == 'urgent';
    final isImportant = priority == 'important';
    final color = isUrgent
        ? const Color(0xFFE53935)
        : isImportant
            ? const Color(0xFFFF9800)
            : Theme.of(context).primaryColor;
    final label = isUrgent
        ? '紧急'
        : isImportant
            ? '重要'
            : '公告';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildAnnouncementImage(MarkdownImageConfig config, bool isDark) {
    final raw = config.uri.toString().trim();
    final imageUrl = ApiConstants.fullUrl(raw);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ImageViewerScreen(imageUrls: [imageUrl], initialIndex: 0),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CachedNetworkImage(
            cacheManager: PostImageCache.manager,
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            width: config.width,
            height: config.height ?? 180,
            placeholder: (_, __) => Container(
              height: config.height ?? 180,
              color: isDark ? Colors.white10 : Colors.grey[200],
              alignment: Alignment.center,
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            errorWidget: (_, __, ___) => Container(
              height: config.height ?? 180,
              color: isDark ? Colors.white10 : Colors.grey[200],
              alignment: Alignment.center,
              child: Icon(
                Icons.broken_image_outlined,
                color: isDark ? Colors.white38 : Colors.grey[500],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _fetchUnreadCount(AuthProvider auth) async {
    try {
      var resp;
      try {
        resp = await auth.dio.get('${ApiConstants.noticesPath}/unread-count');
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          resp = await auth.dio.get('/announcements/unread-count');
        } else {
          rethrow;
        }
      }
      if (resp.data is! Map) {
        debugPrint('获取未读公告数量失败: 响应格式无效');
        return null;
      }

      final result = Map<String, dynamic>.from(resp.data as Map);
      if (result['count'] is! num || result['has_urgent'] is! bool) {
        debugPrint('获取未读公告数量失败: 响应字段无效');
        return null;
      }
      return result;
    } catch (e) {
      debugPrint('获取未读公告数量失败: $e');
      return null;
    }
  }

  void _scheduleAnnouncementRetry() {
    if (!mounted || _announcementRetryTimer != null) return;
    _announcementRetryTimer = Timer(_announcementRetryDelay, () {
      _announcementRetryTimer = null;
      if (mounted) {
        unawaited(_checkUnreadAnnouncements());
      }
    });
  }

  void _updateBadge(int count, bool hasUrgent) {
    if (_unreadBadgeCount == count && _hasUrgentUnread == hasUrgent) return;
    if (!mounted) return;
    setState(() {
      _unreadBadgeCount = count;
      _hasUrgentUnread = hasUrgent;
    });
  }

  // ─── Snooze helpers (AppPreferencesStore, keyed by userId:announcementId) ───

  Future<bool> _isSnoozed(int announcementId, int userId) async {
    if (userId <= 0) return false;
    final prefs = await AppPreferencesStore.getInstance();
    final key = '$_snoozePrefix${userId}_$announcementId';
    final until = prefs.getString(key);
    if (until == null) return false;
    final untilTime = DateTime.tryParse(until);
    if (untilTime == null || untilTime.isBefore(DateTime.now())) {
      await prefs.remove(key); // clean expired
      return false;
    }
    return true;
  }

  Future<void> _snoozeAnnouncement(int announcementId, int userId) async {
    if (userId <= 0) return;
    final prefs = await AppPreferencesStore.getInstance();
    final key = '$_snoozePrefix${userId}_$announcementId';
    await prefs.setString(
      key,
      DateTime.now().add(_snoozeDuration).toIso8601String(),
    );
    _dismissedAnnouncementIds.add(announcementId);
    _cleanExpiredSnoozes(prefs);
  }

  void _cleanExpiredSnoozes(AppPreferencesStore prefs) {
    final keys = prefs.getKeys().where((k) => k.startsWith(_snoozePrefix));
    final now = DateTime.now();
    for (final key in keys) {
      final until = prefs.getString(key);
      if (until != null && DateTime.tryParse(until)?.isBefore(now) == true) {
        prefs.remove(key);
      }
    }
  }

  // ─── Single urgent modal (replaces forced sequential multi-page dialog) ───

  Future<void> _showSingleUrgentModal(Map<String, dynamic> a) async {
    _announcementDialogOpen = true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = (a['title']?.toString().trim().isNotEmpty ?? false)
        ? a['title'].toString().trim()
        : '系统公告';
    final content = a['content']?.toString() ?? '';
    final priority = a['priority']?.toString() ?? 'normal';
    final timeText = _announcementTime(a);

    String? result;
    try {
      result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 22,
            vertical: 24,
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161B24) : Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : const Color(0xFFE7EBF3),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isDark ? 0.28 : 0.10,
                  ),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: priority == 'urgent'
                          ? (isDark
                              ? const [Color(0xFF4A1A1A), Color(0xFF2D1010)]
                              : const [Color(0xFFFFF5F5), Color(0xFFFFE8E8)])
                          : (isDark
                              ? const [Color(0xFF24334E), Color(0xFF192231)]
                              : const [Color(0xFFF4F7FF), Color(0xFFEAF0FF)]),
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: priority == 'urgent'
                                  ? const Color(0xFFE53935)
                                      .withValues(alpha: 0.15)
                                  : Theme.of(context)
                                      .primaryColor
                                      .withValues(alpha: isDark ? 0.22 : 0.14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              priority == 'urgent'
                                  ? Icons.warning_rounded
                                  : Icons.campaign_rounded,
                              color: priority == 'urgent'
                                  ? const Color(0xFFE53935)
                                  : Theme.of(context).primaryColor,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _priorityBadge(
                                      priority: priority,
                                      isDark: isDark,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '请及时查看',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.grey[700],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx, 'snooze'),
                            icon: Icon(
                              Icons.close,
                              color: isDark ? Colors.white60 : Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color:
                              isDark ? Colors.white : const Color(0xFF111827),
                        ),
                      ),
                      if (timeText.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.schedule_rounded,
                                size: 14,
                                color:
                                    isDark ? Colors.white38 : Colors.grey[600]),
                            const SizedBox(width: 6),
                            Text(
                              timeText,
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    isDark ? Colors.white38 : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Content
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 320),
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF11161F)
                          : const Color(0xFFF7F9FC),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : const Color(0xFFE9EDF5),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: MarkdownBody(
                        data: content,
                        selectable: true,
                        onTapLink: (text, href, title) async {
                          final link = href?.trim();
                          if (link == null || link.isEmpty) return;
                          final uri = Uri.tryParse(link);
                          if (uri == null) return;
                          final opened =
                              await ExternalNavigator.current().open(uri);
                          if (!opened && mounted) {}
                        },
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            fontSize: 15,
                            height: 1.7,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF334155),
                          ),
                          h1: TextStyle(
                              fontSize: 22,
                              height: 1.4,
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A)),
                          h2: TextStyle(
                              fontSize: 19,
                              height: 1.45,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A)),
                          h3: TextStyle(
                              fontSize: 17,
                              height: 1.45,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A)),
                        ),
                        sizedImageBuilder: (config) =>
                            _buildAnnouncementImage(config, isDark),
                      ),
                    ),
                  ),
                ),
                // Actions
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, 'snooze'),
                        child: const Text('稍后再看'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, 'dismiss'),
                        child: const Text('我知道了'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'detail'),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('查看详情'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      _announcementDialogOpen = false;
    }

    final announcementId = _announcementId(a);
    final userId = context.read<AuthProvider>().user?.id ?? 0;

    switch (result) {
      case 'snooze':
        // 稍后再看：4 hours snooze, keeps unread
        await _snoozeAnnouncement(announcementId, userId);
        break;
      case 'dismiss':
        // 我知道了：mark as read
        await _markAnnouncementRead(a);
        break;
      case 'detail':
        // 查看详情：mark as read, then navigate to detail
        await _markAnnouncementRead(a);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _buildAnnouncementDetailPage(a),
            ),
          );
        }
        break;
    }
  }

  Future<void> _markAnnouncementRead(dynamic a) async {
    try {
      await context.read<AuthProvider>().dio.post(
            '${ApiConstants.noticesPath}/${a['id']}/read',
          );
    } catch (_) {}
    await _markAnnouncementsSeen([a]);
    // Refresh badge
    _updateBadge(
      (_unreadBadgeCount - 1).clamp(0, 999),
      _hasUrgentUnread,
    );
  }

  Widget _buildAnnouncementDetailPage(Map<String, dynamic> a) {
    // Simple detail view; fallback to announcement screen import if available
    return Scaffold(
      appBar: AppBar(title: const Text('公告详情')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              a['title']?.toString() ?? '',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Text(
              _announcementTime(a),
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 20),
            Text(
              a['content']?.toString() ?? '',
              style: const TextStyle(fontSize: 15, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  /// Replacement for the old multi-page forced-sequential dialog.
  /// Kept as fallback but no longer used in the new flow.
  Future<void> _showAnnouncementDialog(List unread) async {
    _announcementDialogOpen = true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    int current = 0;

    bool? readAll;
    try {
      readAll = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) {
            final a = unread[current];
            final title = (a['title']?.toString().trim().isNotEmpty ?? false)
                ? a['title'].toString().trim()
                : '系统公告';
            final content = a['content']?.toString() ?? '';
            final isPinned = a['is_pinned'] == true;
            final timeText = _announcementTime(a);

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 24,
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 520),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF161B24) : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFE7EBF3),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.28 : 0.10,
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
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isDark
                              ? const [Color(0xFF24334E), Color(0xFF192231)]
                              : const [Color(0xFFF4F7FF), Color(0xFFEAF0FF)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .primaryColor
                                      .withValues(alpha: isDark ? 0.22 : 0.14),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  Icons.campaign_rounded,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .primaryColor
                                                .withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            '系统公告',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Theme.of(
                                                context,
                                              ).primaryColor,
                                            ),
                                          ),
                                        ),
                                        if (isPinned) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFFFFB84D,
                                              ).withValues(alpha: 0.18),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: const Text(
                                              '置顶',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFFFF9800),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      unread.length > 1
                                          ? '第 ${current + 1} 条，共 ${unread.length} 条'
                                          : '请及时查看最新校园通知',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.grey[700],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                icon: Icon(
                                  Icons.close,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.grey[700],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF111827),
                            ),
                          ),
                          if (timeText.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 14,
                                  color: isDark
                                      ? Colors.white38
                                      : Colors.grey[600],
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  timeText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                      child: Container(
                        constraints: const BoxConstraints(maxHeight: 320),
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF11161F)
                              : const Color(0xFFF7F9FC),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.05)
                                : const Color(0xFFE9EDF5),
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: MarkdownBody(
                            data: content,
                            selectable: true,
                            onTapLink: (text, href, title) async {
                              final link = href?.trim();
                              if (link == null || link.isEmpty) return;
                              final uri = Uri.tryParse(link);
                              if (uri == null) return;
                              final opened =
                                  await ExternalNavigator.current().open(uri);
                              if (!opened && mounted) {}
                            },
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(
                                fontSize: 15,
                                height: 1.7,
                                color: isDark
                                    ? Colors.white70
                                    : const Color(0xFF334155),
                              ),
                              h1: TextStyle(
                                fontSize: 22,
                                height: 1.4,
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                              h2: TextStyle(
                                fontSize: 19,
                                height: 1.45,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                              h3: TextStyle(
                                fontSize: 17,
                                height: 1.45,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                              listBullet: TextStyle(
                                fontSize: 15,
                                color: isDark
                                    ? Colors.white70
                                    : const Color(0xFF334155),
                              ),
                              strong: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF111827),
                              ),
                              em: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: isDark
                                    ? Colors.white70
                                    : const Color(0xFF334155),
                              ),
                              code: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13.5,
                                color: isDark
                                    ? const Color(0xFFF8FAFC)
                                    : const Color(0xFF1E293B),
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF0B1220)
                                    : const Color(0xFFEFF3F8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              blockquote: TextStyle(
                                fontSize: 14,
                                height: 1.6,
                                color:
                                    isDark ? Colors.white60 : Colors.grey[700],
                              ),
                              blockquoteDecoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.03)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border(
                                  left: BorderSide(
                                    color: Theme.of(context).primaryColor,
                                    width: 3,
                                  ),
                                ),
                              ),
                              a: TextStyle(
                                color: Theme.of(context).primaryColor,
                                decoration: TextDecoration.underline,
                                decorationColor: Theme.of(context).primaryColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            sizedImageBuilder: (config) =>
                                _buildAnnouncementImage(config, isDark),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: [
                          if (unread.length > 1)
                            OutlinedButton.icon(
                              onPressed: current > 0
                                  ? () => setLocal(() => current--)
                                  : null,
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                                size: 18,
                              ),
                              label: const Text('上一条'),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            )
                          else
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('稍后再看'),
                            ),
                          const Spacer(),
                          if (unread.length > 1 && current < unread.length - 1)
                            TextButton(
                              onPressed: () => setLocal(() => current++),
                              child: const Text('下一条'),
                            ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () async {
                              try {
                                await context.read<AuthProvider>().dio.post(
                                      '${ApiConstants.noticesPath}/${a['id']}/read',
                                    );
                              } catch (_) {}
                              await _markAnnouncementsSeen([a]);
                              if (current < unread.length - 1) {
                                setLocal(() => current++);
                              } else {
                                if (ctx.mounted) Navigator.pop(ctx, true);
                              }
                            },
                            icon: const Icon(Icons.done_all_rounded, size: 18),
                            label: Text(
                              current < unread.length - 1 ? '已读并继续' : '我知道了',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).primaryColor,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
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
      );
    } finally {
      _announcementDialogOpen = false;
    }

    if (readAll != true) {
      _dismissedAnnouncementIds.addAll(unread.map(_announcementId));
    } else {
      await _markAnnouncementsSeen(unread);
    }
  }

  void _handleMainTabAnimationTick() {
    final animation = _mainTabAnimation;
    if (_mainTargetIndex == null || animation == null || !mounted) return;

    final progress = animation.value.clamp(0.0, 1.0);
    _mainVisualIndex = _mainAnimationStartVisualIndex +
        (_mainAnimationEndVisualIndex - _mainAnimationStartVisualIndex) *
            progress;
    _mainVisualIndexListenable.value = _mainVisualIndex;
  }

  void _updateBackgroundForTab(int index) {
    final screenNames = ['shuitie', 'market', 'schedule', 'campus', 'profile'];
    backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
  }

  void _switchTab(int index) {
    if (_currentIndex == index) return;
    unawaited(_settleMainTab(
      targetIndex: index,
      duration: AppMotion.tab,
      commit: true,
    ));
  }

  void _onTabTapped(int index) {
    final useSideRail = ResponsiveUtil.useDesktopShell(context) &&
        !context.read<ThemeProvider>().floatingNavBar;
    if (useSideRail) {
      _switchTab(index);
      return;
    }
    unawaited(_animateMainTabTo(index));
  }

  Future<void> _animateMainTabTo(int index) async {
    final targetIndex = index.clamp(0, 4);
    if (targetIndex == _currentIndex) {
      if (_mainTargetIndex != null) {
        await _settleMainTab(
          targetIndex: targetIndex,
          duration: AppMotion.tab,
          commit: false,
        );
      }
      return;
    }

    await _settleMainTab(
      targetIndex: targetIndex,
      duration: AppMotion.tab,
      commit: true,
    );
  }

  Widget _getOrCreateTabPage(int index) {
    return _tabPages.putIfAbsent(index, () {
      switch (index) {
        case 0:
          return const ShuitieScreen();
        case 1:
          return const MarketScreen();
        case 2:
          return const CourseScheduleScreen();
        case 3:
          return const CampusScreen();
        case 4:
          return const ProfileScreen();
        default:
          return const SizedBox.shrink();
      }
    });
  }

  List<Widget> _buildLazyTabChildren() {
    return List.generate(5, (index) {
      if (!_visitedTabs.contains(index)) {
        return const SizedBox.shrink();
      }
      return _getOrCreateTabPage(index);
    });
  }

  Future<void> _settleMainTab({
    int? targetIndex,
    Duration duration = AppMotion.tab,
    required bool commit,
  }) async {
    if (targetIndex == null || targetIndex == _currentIndex) {
      _mainTabLedger.cancel();
      _mainTabController.stop();
      _contentTabController.stop();
      if (mounted) {
        setState(() {
          _mainTargetIndex = null;
          _mainVisualIndex = _currentIndex.toDouble();
          _mainVisualIndexListenable.value = _mainVisualIndex;
          _contentTabController.value = 1;
        });
      }
      return;
    }

    _mainTabController.stop();
    _mainTabController.duration = duration;
    _contentTabController.stop();
    final fromIndex = _currentIndex;
    final visualStart = _mainVisualIndex;
    final target = targetIndex;
    final plan = _mainTabLedger.begin(
      target,
      commit: commit,
      visualStart: visualStart,
    );
    final visualEnd = commit ? target.toDouble() : fromIndex.toDouble();
    _mainTabAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _mainTabController,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.outgoing,
    ));

    setState(() {
      _getOrCreateTabPage(target);
      _mainAnimationStartVisualIndex = visualStart;
      _mainAnimationEndVisualIndex = visualEnd;
      _mainVisualIndex = visualStart;
      _mainVisualIndexListenable.value = _mainVisualIndex;
    });

    if (commit) {
      _updateBackgroundForTab(target);
    }

    Future<void> contentFuture = Future<void>.value();
    if (plan.shouldReveal) {
      _contentTabController.duration = AppMotion.normal;
      _contentTabController.value = 0;
      contentFuture = _contentTabController.forward(from: 0).orCancel;
    } else {
      // 已访问页面直接显示，避免重复位移、scale 和 stagger。
      _contentTabController.value = 1;
    }

    Future<void> navigationFuture = Future<void>.value();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      // Reduced Motion 仍保留内容 opacity 反馈，但 indicator 直接落位，
      // 不让用户等待一段位置动画才能确认 Tab 状态。
      _mainVisualIndex = visualEnd;
      _mainVisualIndexListenable.value = _mainVisualIndex;
    } else if (visualStart != visualEnd) {
      navigationFuture = _mainTabController.forward(from: 0).orCancel;
    }

    try {
      // 导航 indicator 与首次内容 reveal 同时开始，不能串行等待内容。
      await Future.wait<void>([contentFuture, navigationFuture]);
    } on TickerCanceled {
      return;
    }

    if (!mounted || !_mainTabLedger.complete(plan)) return;

    // 真正的 Tab 切换已提交：发布当前 index，并（lastPage 模式下）保存。
    currentHomeTabIndex.value = _currentIndex;
    unawaited(_saveCurrentTabAsLastPage());

    setState(() {
      _mainTargetIndex = null;
      _mainVisualIndex = _currentIndex.toDouble();
      _mainVisualIndexListenable.value = _mainVisualIndex;
      _mainAnimationStartVisualIndex = _mainVisualIndex;
      _mainAnimationEndVisualIndex = _mainVisualIndex;
    });
  }

  Future<void> _showPublishTypeSheet(BuildContext context) async {
    if (_publishOpening) return;
    final auth = context.read<AuthProvider>();
    final postProvider = context.read<PostProvider>();
    if (!auth.isLoggedIn) {
      Navigator.pushNamed(context, '/login');
      return;
    }
    _publishOpening = true;
    try {
      final type = await PublishTypeSheet.show(context);
      if (!mounted || type == null) return;
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => type == PublishType.poll
              ? const PollComposerScreen()
              : const CreatePostScreen(boardId: 1),
        ),
      );
      if (!mounted) return;
      if (result is Post && result.isPoll) {
        ExpAward? globalAward;
        for (final award in result.expAwards) {
          if (award.scope == 'global') {
            globalAward = award;
            break;
          }
        }
        AppFeedback.success(
          globalAward == null ? '投票发布成功' : '投票发布成功 · 全站经验 +${globalAward.exp}',
          context: context,
        );
      }
      if (result != null) {
        unawaited(Future.wait([
          postProvider.refresh(boardId: 1, sort: 'time'),
          postProvider.refresh(boardId: 1, sort: 'all'),
          postProvider.refresh(boardId: 1, sort: 'featured'),
        ]));
      }
    } finally {
      _publishOpening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final useDesktopShell = ResponsiveUtil.useDesktopShell(context);
    final themeProvider = context.watch<ThemeProvider>();
    final authProvider = context.watch<AuthProvider>();

    // 宽屏默认按 Pad 版处理；开启悬浮底栏时，宽屏也切到浮动导航。
    final useSideRail = useDesktopShell && !themeProvider.floatingNavBar;
    final useBottomNav = !useSideRail;
    final showFloatingNavBar = themeProvider.floatingNavBar;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(authProvider);
      }
    });

    final normalHome = Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 实际内容区
          useSideRail
              ? _buildWideLayout(bottomSafe, authProvider, false)
              : _buildNarrowLayout(bottomSafe, authProvider),
        ],
      ),
      bottomNavigationBar: useSideRail
          ? null
          : BottomNavWrapper(
              currentIndex: _currentIndex,
              visualIndexListenable: _mainVisualIndexListenable,
              onTap: _onTabTapped,
              authProvider: authProvider,
              badges: {
                4: _hasAdminTasks,
              },
            ),
      floatingActionButton: _currentIndex == 0 && useBottomNav
          ? Padding(
              padding: EdgeInsets.only(
                bottom: (showFloatingNavBar ? 110 : 80) + bottomSafe,
              ),
              child: FloatingActionButton(
                heroTag: 'home_fab',
                onPressed: () => _showPublishTypeSheet(context),
                backgroundColor: const Color(0xFF16A34A),
                elevation: 4,
                shape: const CircleBorder(),
                child: const Icon(Icons.add, color: Colors.white, size: 32),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );

    return Stack(
      children: [
        normalHome,
        if (_restoringInitialDeepPage)
          const Positioned.fill(
            child: StartupNavigationGate(
              key: ValueKey('startup-navigation-gate'),
            ),
          ),
      ],
    );
  }

  Widget _buildWideLayout(
    double bottomSafe,
    AuthProvider authProvider,
    bool isExtended,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        // 美化 NavigationRail，增加 GlassContainer 包裹
        SafeArea(
          right: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: GlassContainer(
              borderRadius: 24,
              blur: 24,
              backgroundColor: isDark
                  ? const Color(0xFF111827).withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.5),
              borderColor: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.5),
              child: NavigationRail(
                extended: false,
                selectedIndex: _currentIndex,
                onDestinationSelected: _onTabTapped,
                labelType: NavigationRailLabelType.all,
                backgroundColor: Colors.transparent,
                indicatorColor: Theme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.15),
                selectedIconTheme: IconThemeData(
                  color: Theme.of(context).primaryColor,
                  size: 28,
                ),
                unselectedIconTheme: IconThemeData(
                  color: isDark ? Colors.white60 : Colors.black54,
                  size: 24,
                ),
                selectedLabelTextStyle: TextStyle(
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                unselectedLabelTextStyle: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontSize: 12,
                ),
                groupAlignment: 0.0,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: Text('水贴'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.storefront_outlined),
                    selectedIcon: Icon(Icons.storefront_rounded),
                    label: Text('集市'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month_rounded),
                    label: Text('课表'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.apartment_outlined),
                    selectedIcon: Icon(Icons.apartment_rounded),
                    label: Text('校园'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: Text('我的'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: HomeTabRevealScope(
            key: _contentKey,
            animation: _contentTabController,
            serial: _tabTransitionSerial,
            revealEnabled: !_revealedTabs.contains(_currentIndex),
            child: ClipRRect(
              child: IndexedStack(
                index: _currentIndex,
                children: _buildLazyTabChildren(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(double bottomSafe, AuthProvider authProvider) {
    return HomeTabRevealScope(
      key: _contentKey,
      animation: _contentTabController,
      serial: _tabTransitionSerial,
      revealEnabled: !_revealedTabs.contains(_currentIndex),
      child: HomeTabKeepAliveStage(
        index: _currentIndex,
        children: _buildLazyTabChildren(),
      ),
    );
  }
}
