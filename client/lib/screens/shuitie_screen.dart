import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_constants.dart';
import '../utils/app_motion.dart';
import '../utils/app_feedback.dart';
import '../utils/responsive_util.dart';
import '../utils/screen_swipe.dart';

import '../models/announcement.dart' as model;
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/home_service_drawer.dart';
import '../widgets/home_tab_reveal.dart';
import '../widgets/post_card.dart';
import 'announcement_screen.dart';
import 'chat_list_screen.dart';
import 'competition_center_screen.dart';
import 'edu_grade_screen.dart';
import 'exam_schedule_screen.dart';
import 'feedback_screen.dart';
import 'login_screen.dart';
import 'market_screen.dart';
import 'post_detail_screen.dart';
import 'search_results_screen.dart';
import 'toolbox_screen.dart';
import 'user_home_screen.dart';

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
  const ShuitieScreen({super.key});

  @override
  State<ShuitieScreen> createState() => _ShuitieScreenState();
}

class _ShuitieScreenState extends State<ShuitieScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Map<String, ScrollController> _feedScrollControllers;

  late AnimationController _feedSwitchController;
  Animation<double>? _feedSettleAnimation;
  double _feedDragProgress = 0;
  int? _feedTargetIndex;
  double _feedSwipeDx = 0;
  bool _feedSwipeAccepted = false;
  int _feedRevealSerial = 0;
  bool _feedRevealActive = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _autoRefreshTimer;
  List<model.Announcement> _announcements = [];
  bool _wasLoggedIn = false;
  bool _checkinStatusLoaded = false;
  String _feedMode = kFeedModes[kDefaultFeedModeIndex].key; // 'all'
  String _searchQuery = '';
  List<Post> _searchResults = [];
  bool _checkedIn = false;
  int _streakDays = 0;
  bool _checkInLoading = false;
  Post? _selectedPost;
  int? _selectedUserId;
  bool _messagesLoadRequested = false;

  static const _autoRefreshInterval = Duration(seconds: 60);
  static const _feedSwitchDuration = Duration(milliseconds: 380);
  static const _feedSettleDuration = Duration(milliseconds: 220);
  static const _feedTriggerDistance = 72.0;
  static const _feedTriggerVelocity = 520.0;

  // ---- 配置辅助 ----
  FeedModeConfig get _currentConfig =>
      kFeedModes.firstWhere((m) => m.key == _feedMode);

  int get _currentModeIndex => kFeedModes.indexWhere((m) => m.key == _feedMode);

  double get _feedVisualIndex {
    final currentIndex =
        _currentModeIndex < 0 ? kDefaultFeedModeIndex : _currentModeIndex;
    final targetIndex = _feedTargetIndex;
    if (targetIndex == null) return currentIndex.toDouble();
    return currentIndex +
        (targetIndex - currentIndex) * _feedDragProgress.clamp(0.0, 1.0);
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

    _feedScrollControllers = {
      for (final mode in kFeedModes)
        mode.key: ScrollController(keepScrollOffset: true),
    };

    WidgetsBinding.instance.addObserver(this);
    _feedSwitchController = AnimationController(
      vsync: this,
      duration: _feedSettleDuration,
    )..addListener(_handleFeedSettleTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final postProvider = context.read<PostProvider>();
      postProvider.loadPosts(boardId: 1, sort: 'all');
      _startAutoRefresh();
      _ensureCheckinStatusLoaded();

      // 延迟加载其他非核心数据
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _loadAnnouncements();
          _ensureMessagesLoaded();
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_currentConfig.supportsRemoteLoading && _canLoadFeedMode(_feedMode)) {
        _refresh();
      }
      _loadAnnouncements();
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused) {
      _stopAutoRefresh();
    }
  }

  void _startAutoRefresh() {
    _stopAutoRefresh();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted) return;
      if (_currentConfig.supportsRemoteLoading && _canLoadFeedMode(_feedMode)) {
        _refresh();
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

    for (final controller in _feedScrollControllers.values) {
      controller.dispose();
    }

    _searchController.dispose();
    _feedSwitchController
      ..removeListener(_handleFeedSettleTick)
      ..dispose();
    super.dispose();
  }

  /// 确保 MessageProvider 的会话列表已被加载（用于首页红点）
  void _ensureMessagesLoaded() {
    if (_messagesLoadRequested) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    _messagesLoadRequested = true;
    context.read<MessageProvider>().loadConversations(silent: true);
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    try {
      Response<dynamic> response;
      try {
        response = await authProvider.dio.get(ApiConstants.noticesPath);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          response = await authProvider.dio.get('/announcements');
        } else {
          rethrow;
        }
      }

      if (response.statusCode == 200) {
        final all = (response.data as List)
            .map((e) => model.Announcement.fromJson(e))
            .toList()
          ..sort((a, b) {
            if (a.isPinned != b.isPinned) {
              return a.isPinned ? -1 : 1;
            }
            return b.createdAt.compareTo(a.createdAt);
          });
        final dismissed = await _loadDismissedIds();
        if (!mounted) return;
        setState(() {
          _announcements = all.where((a) => !dismissed.contains(a.id)).toList();
        });
      }
    } catch (e) {
      debugPrint('加载公告失败: $e');
    }
  }

  Future<Set<int>> _loadDismissedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('dismissed_announcements') ?? [];
    return list.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toSet();
  }

  Future<void> _runSearch(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;

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

  void _onSearchChanged(String value) {
    setState(() {});
  }

  void _handleFeedSettleTick() {
    final targetIndex = _feedTargetIndex;
    final animation = _feedSettleAnimation;
    if (targetIndex == null || animation == null || !mounted) return;
    setState(() {
      _feedDragProgress = animation.value.clamp(0.0, 1.0);
    });
  }

  Future<void> _changeFeedMode(String mode) async {
    if (_feedMode == mode) return;
    final newIndex = kFeedModes.indexWhere((m) => m.key == mode);
    if (newIndex < 0) return;
    final oldIndex = _currentModeIndex < 0 ? kDefaultFeedModeIndex : _currentModeIndex;

    _refreshFeedMode(mode);
    _feedSwitchController.stop();
    _feedSwitchController.duration = _feedSwitchDuration;
    
    _feedSettleAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _feedSwitchController,
        curve: const Interval(0.0, 0.58, curve: Curves.easeOutQuad),
      ),
    );

    setState(() {
      _feedMode = mode;
      _feedTargetIndex = oldIndex;
      _feedDragProgress = 1.0;
      _feedRevealSerial++;
      _feedRevealActive = true;
    });
    
    await _feedSwitchController.forward(from: 0);
    
    if (!mounted) return;
    setState(() {
      _feedRevealActive = false;
      _feedTargetIndex = null;
      _feedDragProgress = 0;
    });
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

    List<Post> sortedPosts = List.from(posts);

    // 排序逻辑已下沉至服务端，客户端只需原样返回
    // 但对于新帖过滤可以保留部分逻辑（如果服务端未实现new模式的话）
    if (mode == 'new') {
      final now = DateTime.now();
      final recent = sortedPosts
          .where((post) => now.difference(post.createdAt).inDays < 3)
          .toList();
      if (recent.isNotEmpty) {
        recent.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return recent;
      }
      sortedPosts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return sortedPosts.take(12).toList();
    }

    return sortedPosts;
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

  Future<void> _ensureCheckinStatusLoaded() async {
    if (_checkinStatusLoaded || _checkInLoading) return;
    final succeeded = await _loadCheckinStatus();
    if (mounted && succeeded) {
      _checkinStatusLoaded = true;
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

  Future<void> _doCheckIn() async {
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
    if (_checkInLoading || _checkedIn) return;
    if (mounted) setState(() => _checkInLoading = true);
    try {
      final resp = await auth.dio.post('/user/checkin');
      if (resp.statusCode == 200 && mounted) {
        final data = resp.data;
        final already = data['already'] ?? false;
        final streak = data['streak_days'] ?? 1;
        final exp = data['exp_earned'] ?? 1;
        if (mounted) {
          setState(() {
            _checkedIn = true;
            _streakDays = streak;
            _checkInLoading = false;
          });
        }
        auth.refreshUser();
        if (!already) {
          _showCheckInSuccessDialog(streak, exp);
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('今天已经签过到了')));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkInLoading = false);
        String msg = '签到失败，请稍后再试';
        if (e is DioException) {
          msg = AppFeedback.dioErrorMessage(e, fallback: msg);
        }
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }

  void _showCheckInSuccessDialog(int streak, int exp) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.celebration, color: Colors.orange[400]),
            const SizedBox(width: 8),
            const Text('签到成功！'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '🔥 连续签到 $streak 天',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.amber.withValues(alpha: 0.15)
                    : Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '+$exp 经验',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.amber[700],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _nextRewardHint(streak),
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  String _nextRewardHint(int streak) {
    if (streak < 3) return '连续签到3天可获得每日3经验';
    if (streak < 10) return '连续签到10天可获得每日10经验';
    if (streak < 30) return '连续签到30天可获得每日15经验';
    return '已达最高等级，每日15经验！继续保持！';
  }

  void _handleFeedSwipeStart(DragStartDetails details) {
    _feedSwitchController.stop();
    _feedSwipeDx = 0;
    _feedSwipeAccepted = isUpperContentSwipeStart(
      details.globalPosition.dy,
      MediaQuery.sizeOf(context).height,
    );
    if (_feedSwipeAccepted) {
      setState(() {
        _feedTargetIndex = null;
        _feedDragProgress = 0;
      });
    }
  }

  void _handleFeedSwipeUpdate(DragUpdateDetails details) {
    if (!_feedSwipeAccepted) return;
    _feedSwipeDx += details.primaryDelta ?? 0;
    final targetIndex = _targetFeedIndexForDx(_feedSwipeDx);
    if (targetIndex == null) {
      setState(() {
        _feedTargetIndex = null;
        _feedDragProgress = 0;
      });
      return;
    }

    _refreshFeedMode(kFeedModes[targetIndex].key);
    setState(() {
      _feedTargetIndex = targetIndex;
      _feedDragProgress = 0;
    });
  }

  Future<void> _handleFeedSwipe(DragEndDetails details) async {
    final accepted = _feedSwipeAccepted;
    _feedSwipeAccepted = false;
    if (!accepted) {
      return;
    }

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
      await _settleFeedMode(
        targetIndex: _feedTargetIndex,
        begin: _feedDragProgress,
        end: 0.0,
        duration: _feedSettleDuration,
        commit: false,
      );
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
    double begin = 0,
    double end = 0,
    Duration duration = _feedSettleDuration,
    required bool commit,
  }) async {
    if (targetIndex == null || targetIndex == _currentModeIndex) {
      if (mounted) {
        setState(() {
          _feedTargetIndex = null;
          _feedDragProgress = 0;
        });
      }
      return;
    }

    if (commit) {
      _refreshFeedMode(kFeedModes[targetIndex].key);
    }

    _feedSwitchController.stop();
    _feedSwitchController.duration = duration;
    _feedSettleAnimation = Tween<double>(
      begin: begin.clamp(0.0, 1.0).toDouble(),
      end: end.clamp(0.0, 1.0).toDouble(),
    ).animate(CurvedAnimation(
      parent: _feedSwitchController,
      curve: Curves.easeOutQuad,
    ));

    setState(() {
      _feedTargetIndex = targetIndex;
      _feedDragProgress = begin.clamp(0.0, 1.0).toDouble();
    });

    await _feedSwitchController.forward(from: 0);
    if (!mounted) return;

    setState(() {
      if (commit) {
        _feedMode = kFeedModes[targetIndex].key;
        _feedRevealSerial++;
      }
      _feedTargetIndex = null;
      _feedDragProgress = 0;
    });
  }

  void _openMessages() {
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
  }

  Future<void> _openHomeServicePanel() async {
    await _ensureCheckinStatusLoaded();
    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: '关闭校园服务',
      barrierColor: Colors.black.withValues(alpha: 0.35),
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
                checkInLoading: _checkInLoading,
                showCheckInDot: _showCheckInDot,
                announcements: _announcements,
                onCheckIn: () {
                  _closePanelThenOpen(dialogContext, _doCheckIn);
                },
                onOpenLostFound: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const MarketScreen(
                          onlyPostTypes: ['lost', 'found'],
                          titleOverride: '失物招领',
                        ),
                      ),
                    );
                  });
                },
                onOpenToolbox: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ToolboxScreen()),
                    );
                  });
                },
                onOpenAnnouncements: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AnnouncementScreen()),
                    );
                  });
                },
                onOpenCompetitions: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CompetitionCenterScreen()),
                    );
                  });
                },
                onOpenGrades: () {
                  _closePanelThenOpen(dialogContext, () {
                    final auth = context.read<AuthProvider>();
                    if (!auth.isLoggedIn || auth.user == null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
                      );
                      return;
                    }
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        transitionDuration: const Duration(milliseconds: 260),
                        reverseTransitionDuration:
                            const Duration(milliseconds: 200),
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
                  });
                },
                onOpenExamSchedule: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ExamScheduleScreen()),
                    );
                  });
                },
                onOpenFeedback: () {
                  _closePanelThenOpen(dialogContext, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const FeedbackScreen()),
                    );
                  });
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
      _messagesLoadRequested = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 登录/退出时清除关注信息流，避免跨账号数据残留
        context.read<PostProvider>().invalidateFollowingFeed();
        if (_currentConfig.supportsRemoteLoading &&
            _canLoadFeedMode(_feedMode)) {
          _refresh();
        }
        _ensureMessagesLoaded();
        _ensureCheckinStatusLoaded();
      });
    }

    final useDesktopShell = ResponsiveUtil.useDesktopShell(context);

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101219) : const Color(0xFFF7F8FC),
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
      child: PostDetailScreen(
        key: ValueKey(_selectedPost!.id),
        postId: _selectedPost!.id,
        isMarket: false,
        initialPost: _selectedPost,
        isDesktopSplitMode: true,
        hideBackButton: true,
        onAuthorTap: _openUserInSplit,
      ),
    );

    return ColoredBox(
      color: isDark ? const Color(0xFF131720) : Colors.white,
      child: content,
    );
  }

  void _openPostInSplit(Post post) {
    if (!mounted) return;
    setState(() {
      _selectedPost = post;
      _selectedUserId = null;
    });
  }

  void _openUserInSplit(int userId) {
    if (!mounted) return;
    setState(() {
      _selectedPost = null;
      _selectedUserId = userId;
    });
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
    final visualIndex = _feedVisualIndex;
    final activeColor = isDark ? Colors.white : Colors.black87;
    final inactiveColor = isDark ? Colors.white54 : Colors.black45;

    return SizedBox(
      width: tabWidth * kFeedModes.length,
      height: 44,
      child: Stack(
        children: [
          // 指示条跟随手势连续移动，而不是等状态切完再跳转。
          Positioned(
            left: visualIndex * tabWidth + (tabWidth - 22) / 2,
            bottom: 3,
            width: 22,
            height: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
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
              final color = Color.lerp(inactiveColor, activeColor, activeT)!;
              final scale = 1.0 + 0.03 * activeT;

              return SizedBox(
                width: tabWidth,
                height: 44,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _changeFeedMode(config.key),
                  child: Center(
                    child: Transform.scale(
                      scale: scale,
                      child: Text(
                        config.label,
                        style: TextStyle(
                          fontSize: 15 + 0.5 * activeT,
                          fontWeight:
                              activeT > 0.5 ? FontWeight.w800 : FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
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
                  if (_showCheckInDot)
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
              onPressed: () => Navigator.push(
                context,
                PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const LoginScreen(),
                ),
              ),
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
              '关注的同学发布帖子后，会显示在这里',
              textAlign: TextAlign.center,
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

  // ---- 普通信息流内容（含搜索框折叠） ----
  Widget _buildFeedContent(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _handleFeedSwipeStart,
      onHorizontalDragUpdate: _handleFeedSwipeUpdate,
      onHorizontalDragEnd: _handleFeedSwipe,
      onHorizontalDragCancel: () {
        _feedSwipeDx = 0;
        _feedSwipeAccepted = false;
        unawaited(_settleFeedMode(
          targetIndex: _feedTargetIndex,
          begin: _feedDragProgress,
          end: 0.0,
          duration: _feedSettleDuration,
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
    final feedList = Selector<PostProvider,
        ({List<Post> posts, bool isLoading, bool hasMore, int revision})>(
      selector: (context, postProvider) {
        return (
          posts: postProvider.postsFor(1, sort: sort),
          isLoading: postProvider.isLoadingFor(1, sort: sort),
          hasMore: postProvider.hasMoreFor(1, sort: sort),
          revision: postProvider.revisionFor(1, sort: sort),
        );
      },
      builder: (context, data, child) {
        final posts = data.posts;
        final isFeedLoading = data.isLoading;
        final feedHasMore = data.hasMore;
        final visiblePosts = _resolveVisiblePosts(posts, mode);

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
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverPersistentHeader(
                pinned: false,
                floating: true,
                delegate: _SliverSearchBarDelegate(
                  vsync: this,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                    child: _buildSearchBar(isDark),
                  ),
                ),
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
              else if (visiblePosts.isEmpty)
                SliverFillRemaining(
                  child: mode == 'following'
                      ? _buildFollowingEmptyState(isDark)
                      : _buildEmptyState(
                          isDark,
                          title: _searchQuery.isNotEmpty ? '没有找到匹配帖子' : '暂无帖子',
                          subtitle: _searchQuery.isNotEmpty
                              ? '目前只按标题搜索，换个标题关键词试试'
                              : '发布第一条帖子吧',
                          onRetry: _refresh,
                        ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final post = visiblePosts[index];
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
                        child: HomeTabRevealItem(
                          index: index,
                          child: PostCard(
                            post: post,
                            onAuthorTap: _openUserInSplit,
                            onTap: () {
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
                      ),
                    );
                  }, childCount: visiblePosts.length),
                ),
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

    if (!_feedRevealActive) return feedList;

    return HomeTabRevealScope(
      animation: _feedSwitchController,
      serial: _feedRevealSerial,
      child: feedList,
    );
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
        controller: _searchController,
        onChanged: _onSearchChanged,
        onSubmitted: _runSearch,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          hintText: '搜索账号、用户或帖子关键词',
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

// ---- 搜索框折叠 SliverPersistentHeaderDelegate ----
class _SliverSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final TickerProvider _vsync;
  final Widget child;

  _SliverSearchBarDelegate({required TickerProvider vsync, required this.child})
      : _vsync = vsync;

  @override
  double get maxExtent => 46;

  @override
  double get minExtent => 0;

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
