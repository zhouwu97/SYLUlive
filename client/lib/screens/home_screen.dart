import 'dart:async';

import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/api_constants.dart';
import '../main.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_motion.dart';
import '../utils/app_navigator.dart';
import '../utils/post_image_cache.dart';
import '../utils/screen_swipe.dart';
import '../utils/update_checker.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/glass_container.dart';
import '../utils/responsive_util.dart';
import 'shuitie_screen.dart';
import 'market_screen.dart';
import 'course_schedule_screen.dart';
import 'campus_screen.dart';
import 'profile_screen.dart';
import 'create_post_screen.dart';
import 'login_screen.dart';
import 'image_viewer_screen.dart';

class HomeScreen extends StatefulWidget {
  final int initialTab;
  const HomeScreen({super.key, this.initialTab = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'homeContentStack');
  late final Set<int> _visitedTabs;
  final Map<int, Widget> _tabPages = {};
  late final AnimationController _mainTabController;
  Animation<double>? _mainTabAnimation;
  double _mainDragProgress = 0;
  double _mainVisualIndex = 0;
  int? _mainTargetIndex;
  double _mainSwipeDx = 0;
  Timer? _announcementTimer;
  String? _announcementAuthKey;
  bool _isCheckingAnnouncements = false;
  bool _announcementDialogOpen = false;
  final Set<int> _dismissedAnnouncementIds = {};
  final Set<int> _seenAnnouncementIds = {};
  String? _announcementSeenKey;

  // Unread badge state
  int _unreadBadgeCount = 0;
  bool _hasUrgentUnread = false;

  // Snooze: keyed by userId:announcementId in SharedPreferences
  static const _snoozePrefix = 'announcement_snooze_';
  static const _snoozeDuration = Duration(hours: 4);
  // Fallback polling interval (keep until JPush trigger is implemented)
  static const _announcementPollInterval = Duration(minutes: 15);
  static const _mainSwitchDistanceThreshold = 0.24;
  static const _mainSwitchVelocityThreshold = 450.0;
  Offset? _navigationSwipeStart;
  DateTime? _navigationSwipeStartTime;
  int? _navigationSwipePointer;

  @override
  void initState() {
    super.initState();
    _currentIndex = consumeWidgetTabSwitch() ? 2 : widget.initialTab;
    _mainVisualIndex = _currentIndex.toDouble();
    _visitedTabs = {_currentIndex};
    _mainTabController = AnimationController(
      vsync: this,
      duration: AppMotion.page,
    )..addListener(_handleMainTabAnimationTick);
    widgetTabSwitch.addListener(_onWidgetTabSwitch);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(context.read<AuthProvider>());
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            UpdateChecker.check(context);
          }
        });
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
    _mainTabController
      ..removeListener(_handleMainTabAnimationTick)
      ..dispose();
    _announcementTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _currentIndex = widget.initialTab;
      _mainTargetIndex = null;
      _mainDragProgress = 0;
      _mainVisualIndex = _currentIndex.toDouble();
      _visitedTabs.add(_currentIndex);
      _getOrCreateTabPage(_currentIndex);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkUnreadAnnouncements();
    }
  }

  void _syncAnnouncementPolling(AuthProvider auth) {
    final authKey = auth.isLoggedIn ? '${auth.user?.id}:${auth.token}' : null;
    if (_announcementAuthKey == authKey) return;

    _announcementAuthKey = authKey;
    _announcementSeenKey =
        auth.isLoggedIn ? 'seen_announcements_${auth.user?.id}' : null;
    _dismissedAnnouncementIds.clear();
    _seenAnnouncementIds.clear();
    _announcementTimer?.cancel();
    _announcementTimer = null;

    if (authKey == null) return;

    unawaited(_initializeAnnouncementPolling());
  }

  Future<void> _initializeAnnouncementPolling() async {
    await _loadSeenAnnouncements();
    if (!mounted) return;
    await _checkUnreadAnnouncements();
    if (!mounted) return;
    _announcementTimer = Timer.periodic(
      _announcementPollInterval,
      (_) => _checkUnreadAnnouncements(),
    );
  }

  Future<void> _loadSeenAnnouncements() async {
    final key = _announcementSeenKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(key) ?? const [];
    _seenAnnouncementIds
      ..clear()
      ..addAll(stored.map(int.tryParse).whereType<int>());
  }

  Future<void> _saveSeenAnnouncements() async {
    final key = _announcementSeenKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
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

  Future<void> _checkUnreadAnnouncements() async {
    if (!mounted || _isCheckingAnnouncements || _announcementDialogOpen) {
      return;
    }

    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      _syncAnnouncementPolling(auth);
      return;
    }

    _isCheckingAnnouncements = true;
    try {
      // 1. Get lightweight unread count first
      final countResult = await _fetchUnreadCount(auth);
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
          final priority = item['priority']?.toString() ?? '';
          final displayMode = item['display_mode']?.toString() ?? '';
          return (priority == 'urgent' || priority == 'important') &&
              (displayMode == 'modal' || displayMode.isEmpty);
        }).toList();

        // Sort: urgent before important
        candidates.sort((a, b) {
          final pa = a['priority']?.toString() ?? '';
          final pb = b['priority']?.toString() ?? '';
          if (pa == 'urgent' && pb != 'urgent') return -1;
          if (pa != 'urgent' && pb == 'urgent') return 1;
          return 0;
        });

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

  Future<Map<String, dynamic>> _fetchUnreadCount(AuthProvider auth) async {
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
      return resp.data is Map ? Map<String, dynamic>.from(resp.data) : {};
    } catch (e) {
      debugPrint('获取未读公告数量失败: $e');
      return {};
    }
  }

  void _updateBadge(int count, bool hasUrgent) {
    if (_unreadBadgeCount == count && _hasUrgentUnread == hasUrgent) return;
    _unreadBadgeCount = count;
    _hasUrgentUnread = hasUrgent;
  }

  // ─── Snooze helpers (SharedPreferences, keyed by userId:announcementId) ───

  Future<bool> _isSnoozed(int announcementId, int userId) async {
    if (userId <= 0) return false;
    final prefs = await SharedPreferences.getInstance();
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
    final prefs = await SharedPreferences.getInstance();
    final key = '$_snoozePrefix${userId}_$announcementId';
    await prefs.setString(
      key,
      DateTime.now().add(_snoozeDuration).toIso8601String(),
    );
    _dismissedAnnouncementIds.add(announcementId);
    _cleanExpiredSnoozes(prefs);
  }

  void _cleanExpiredSnoozes(SharedPreferences prefs) {
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
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
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
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
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
    final targetIndex = _mainTargetIndex;
    final animation = _mainTabAnimation;
    if (targetIndex == null || animation == null || !mounted) return;

    final progress = animation.value.clamp(0.0, 1.0);
    setState(() {
      _mainDragProgress = progress;
      _mainVisualIndex =
          _currentIndex + (targetIndex - _currentIndex) * progress;
    });
  }

  void _updateBackgroundForTab(int index) {
    final screenNames = ['shuitie', 'market', 'schedule', 'campus', 'profile'];
    backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
  }

  void _switchTab(int index) {
    if (_currentIndex == index) return;
    _mainTabController.stop();
    if (mounted) {
      setState(() {
        _currentIndex = index;
        _mainTargetIndex = null;
        _mainDragProgress = 0;
        _mainVisualIndex = index.toDouble();
        _visitedTabs.add(index);
      });
    }
    _updateBackgroundForTab(index);
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
      await _settleMainTab(commit: false);
      return;
    }

    final begin = _mainTargetIndex == targetIndex ? _mainDragProgress : 0.0;
    await _settleMainTab(
      targetIndex: targetIndex,
      begin: begin,
      end: 1.0,
      duration: const Duration(milliseconds: 180),
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

  void _startNavigationSwipe(PointerDownEvent event, double screenHeight) {
    if (_navigationSwipePointer != null ||
        !isBottomNavigationSwipeStart(event.position.dy, screenHeight)) {
      return;
    }
    _mainTabController.stop();
    _navigationSwipePointer = event.pointer;
    _navigationSwipeStart = event.position;
    _navigationSwipeStartTime = DateTime.now();
    _mainSwipeDx = 0;
    setState(() {
      _mainTargetIndex = null;
      _mainDragProgress = 0;
      _mainVisualIndex = _currentIndex.toDouble();
    });
  }

  void _updateNavigationSwipe(PointerMoveEvent event) {
    if (event.pointer != _navigationSwipePointer ||
        _navigationSwipeStart == null) {
      return;
    }

    _mainSwipeDx = event.position.dx - _navigationSwipeStart!.dx;
    final targetIndex = _targetMainIndexForDx(_mainSwipeDx);
    if (targetIndex == null) {
      setState(() {
        _mainTargetIndex = null;
        _mainDragProgress = 0;
        _mainVisualIndex = _currentIndex.toDouble();
      });
      return;
    }

    final width = MediaQuery.sizeOf(context).width;
    final progress = (_mainSwipeDx.abs() / width).clamp(0.0, 1.0);
    setState(() {
      _visitedTabs.add(targetIndex);
      _getOrCreateTabPage(targetIndex);
      _mainTargetIndex = targetIndex;
      _mainDragProgress = progress;
      _mainVisualIndex =
          _currentIndex + (targetIndex - _currentIndex) * progress;
    });
  }

  void _finishNavigationSwipe(PointerUpEvent event) {
    if (event.pointer != _navigationSwipePointer ||
        _navigationSwipeStart == null ||
        _navigationSwipeStartTime == null) {
      return;
    }

    _mainSwipeDx = event.position.dx - _navigationSwipeStart!.dx;
    final elapsed = DateTime.now().difference(_navigationSwipeStartTime!);
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final velocity = seconds <= 0 ? 0.0 : _mainSwipeDx / seconds;
    final targetIndex = _targetMainIndexForDx(
      velocity.abs() >= _mainSwitchVelocityThreshold ? velocity : _mainSwipeDx,
    );
    final width = MediaQuery.sizeOf(context).width;
    final progress = (_mainSwipeDx.abs() / width).clamp(0.0, 1.0);
    final shouldSwitch = targetIndex != null &&
        (progress >= _mainSwitchDistanceThreshold ||
            velocity.abs() >= _mainSwitchVelocityThreshold);
    _resetNavigationSwipe();

    if (shouldSwitch) {
      unawaited(_settleMainTab(
        targetIndex: targetIndex,
        begin: _mainDragProgress,
        end: 1.0,
        duration: const Duration(milliseconds: 180),
        commit: true,
      ));
    } else {
      unawaited(_settleMainTab(
        targetIndex: _mainTargetIndex,
        begin: _mainDragProgress,
        end: 0.0,
        duration: AppMotion.normal,
        commit: false,
      ));
    }
  }

  void _cancelNavigationSwipe(PointerCancelEvent event) {
    if (event.pointer == _navigationSwipePointer) {
      _resetNavigationSwipe();
      unawaited(_settleMainTab(
        targetIndex: _mainTargetIndex,
        begin: _mainDragProgress,
        end: 0.0,
        duration: AppMotion.normal,
        commit: false,
      ));
    }
  }

  void _resetNavigationSwipe() {
    _navigationSwipePointer = null;
    _navigationSwipeStart = null;
    _navigationSwipeStartTime = null;
    _mainSwipeDx = 0;
  }

  int? _targetMainIndexForDx(double dx) {
    if (dx == 0) return null;
    final direction = dx < 0 ? 1 : -1;
    final targetIndex = _currentIndex + direction;
    if (targetIndex < 0 || targetIndex > 4) return null;
    return targetIndex;
  }

  Future<void> _settleMainTab({
    int? targetIndex,
    double begin = 0,
    double end = 0,
    Duration duration = AppMotion.normal,
    required bool commit,
  }) async {
    if (targetIndex == null || targetIndex == _currentIndex) {
      if (mounted) {
        setState(() {
          _mainTargetIndex = null;
          _mainDragProgress = 0;
          _mainVisualIndex = _currentIndex.toDouble();
        });
      }
      return;
    }

    _mainTabController.stop();
    _mainTabController.duration = duration;
    _mainTabAnimation = Tween<double>(
      begin: begin.clamp(0.0, 1.0).toDouble(),
      end: end.clamp(0.0, 1.0).toDouble(),
    ).animate(CurvedAnimation(
      parent: _mainTabController,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.outgoing,
    ));

    setState(() {
      _visitedTabs.add(targetIndex);
      _getOrCreateTabPage(targetIndex);
      _mainTargetIndex = targetIndex;
      _mainDragProgress = begin.clamp(0.0, 1.0).toDouble();
      _mainVisualIndex =
          _currentIndex + (targetIndex - _currentIndex) * _mainDragProgress;
    });

    await _mainTabController.forward(from: 0);
    if (!mounted) return;

    setState(() {
      if (commit) {
        _currentIndex = targetIndex;
      }
      _mainTargetIndex = null;
      _mainDragProgress = 0;
      _mainVisualIndex = _currentIndex.toDouble();
    });

    if (commit) {
      _updateBackgroundForTab(targetIndex);
    }
  }

  void _openCreatePost(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final postProvider = context.read<PostProvider>();
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
      MaterialPageRoute(builder: (_) => const CreatePostScreen(boardId: 1)),
    ).then((_) {
      if (mounted) {
        unawaited(
          Future.wait([
            postProvider.refresh(boardId: 1, sort: 'time'),
            postProvider.refresh(boardId: 1, sort: 'all'),
            postProvider.refresh(boardId: 1, sort: 'featured'),
          ]),
        );
      }
    });
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

    final screenHeight = MediaQuery.sizeOf(context).height;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: useBottomNav
          ? (event) => _startNavigationSwipe(event, screenHeight)
          : null,
      onPointerMove: useBottomNav ? _updateNavigationSwipe : null,
      onPointerUp: useBottomNav ? _finishNavigationSwipe : null,
      onPointerCancel: useBottomNav ? _cancelNavigationSwipe : null,
      child: Scaffold(
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
                visualIndex: _mainVisualIndex,
                onTap: _onTabTapped,
                authProvider: authProvider,
              ),
        floatingActionButton: _currentIndex == 0 && useBottomNav
            ? Padding(
                padding: EdgeInsets.only(
                  bottom: (showFloatingNavBar ? 110 : 80) + bottomSafe,
                ),
                child: FloatingActionButton(
                  heroTag: 'home_fab',
                  onPressed: () => _openCreatePost(context),
                  backgroundColor: const Color(0xFF16A34A),
                  elevation: 4,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add, color: Colors.white, size: 32),
                ),
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
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
          child: ClipRRect(
            child: IndexedStack(
              key: _contentKey,
              index: _currentIndex,
              children: _buildLazyTabChildren(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(double bottomSafe, AuthProvider authProvider) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: AppMotion.incoming,
      switchOutCurve: AppMotion.outgoing,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.995,
              end: 1.0,
            ).animate(animation),
            child: child,
          ),
        );
      },
      key: _contentKey,
      child: KeyedSubtree(
        key: ValueKey<int>(_currentIndex),
        child: _getOrCreateTabPage(_currentIndex),
      ),
    );
  }
}
