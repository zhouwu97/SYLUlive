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
import '../utils/post_image_cache.dart';
import '../widgets/bottom_nav.dart';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  Timer? _announcementTimer;
  String? _announcementAuthKey;
  bool _isCheckingAnnouncements = false;
  bool _announcementDialogOpen = false;
  final Set<int> _dismissedAnnouncementIds = {};
  final Set<int> _seenAnnouncementIds = {};
  String? _announcementSeenKey;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(context.read<AuthProvider>());
      }
    });
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _currentIndex = widget.initialTab;
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
      const Duration(seconds: 60),
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
    final resp = await auth.dio.get('/announcements');
    final list = (resp.data as List?) ?? const [];
    return list
        .where((item) => !_seenAnnouncementIds.contains(_announcementId(item)))
        .toList();
  }

  Future<List<dynamic>> _loadUnreadAnnouncements(AuthProvider auth) async {
    try {
      final resp = await auth.dio.get('/announcements/unread');
      return (resp.data as List?) ?? const [];
    } on DioException catch (e) {
      final isBadUnreadRoute = e.response?.statusCode == 400 &&
          e.response?.data is Map &&
          (e.response!.data['error']?.toString().contains('无效的公告ID') ?? false);
      if (isBadUnreadRoute) {
        debugPrint('未读公告接口异常，降级到 /announcements');
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
      final list = (await _loadUnreadAnnouncements(auth))
          .where((item) =>
              !_dismissedAnnouncementIds.contains(_announcementId(item)) &&
              !_seenAnnouncementIds.contains(_announcementId(item)))
          .toList();
      if (list.isEmpty || !mounted) return;
      await _showAnnouncementDialog(list);
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

  Widget _buildAnnouncementImage(MarkdownImageConfig config, bool isDark) {
    final raw = config.uri.toString().trim();
    final imageUrl = ApiConstants.fullUrl(raw);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              imageUrls: [imageUrl],
              initialIndex: 0,
            ),
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

  Future<void> _showAnnouncementDialog(List unread) async {
    _announcementDialogOpen = true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    int current = 0;

    bool? readAll;
    try {
      readAll = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
          final a = unread[current];
          final title = (a['title']?.toString().trim().isNotEmpty ?? false)
              ? a['title'].toString().trim()
              : '系统公告';
          final content = a['content']?.toString() ?? '';
          final isPinned = a['is_pinned'] == true;
          final timeText = _announcementTime(a);

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
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
                    color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(28)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
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
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '系统公告',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(context).primaryColor,
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
                                        color: const Color(0xFFFFB84D)
                                            .withValues(alpha: 0.18),
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
                            color: isDark ? Colors.white60 : Colors.grey[700],
                          ),
                        ),
                      ]),
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
                            Icon(
                              Icons.schedule_rounded,
                              size: 14,
                              color: isDark ? Colors.white38 : Colors.grey[600],
                            ),
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
                            color:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                          h2: TextStyle(
                            fontSize: 19,
                            height: 1.45,
                            fontWeight: FontWeight.w700,
                            color:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                          h3: TextStyle(
                            fontSize: 17,
                            height: 1.45,
                            fontWeight: FontWeight.w700,
                            color:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                          listBullet: TextStyle(
                            fontSize: 15,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF334155),
                          ),
                          strong: TextStyle(
                            fontWeight: FontWeight.w800,
                            color:
                                isDark ? Colors.white : const Color(0xFF111827),
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
                            color: isDark ? Colors.white60 : Colors.grey[700],
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
                          icon:
                              const Icon(Icons.chevron_left_rounded, size: 18),
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
                            await context
                                .read<AuthProvider>()
                                .dio
                                .post('/announcements/${a['id']}/read');
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
                            current < unread.length - 1 ? '已读并继续' : '我知道了'),
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
              ]),
            ),
          );
        }),
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _announcementTimer?.cancel();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
    final screenNames = ['shuitie', 'market', 'schedule', 'campus', 'profile'];
    backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
  }

  void _openCreatePost(BuildContext context) {
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
      MaterialPageRoute(
        builder: (_) => const CreatePostScreen(boardId: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth > 800;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(authProvider);
      }
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: isWideScreen
          ? _buildWideLayout(bottomSafe, authProvider)
          : _buildNarrowLayout(bottomSafe, authProvider),
      bottomNavigationBar: isWideScreen
          ? null
          : BottomNavWrapper(
              currentIndex: _currentIndex,
              onTap: _onTabTapped,
              authProvider: authProvider,
            ),
      floatingActionButton: _currentIndex == 0 && !isWideScreen
          ? Padding(
              padding: EdgeInsets.only(bottom: 110 + bottomSafe),
              child: FloatingActionButton(
                onPressed: () => _openCreatePost(context),
                backgroundColor: const Color(0xFF16A34A),
                elevation: 4,
                shape: const CircleBorder(),
                child: const Icon(Icons.add, color: Colors.white, size: 32),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildWideLayout(double bottomSafe, AuthProvider authProvider) {
    return Row(
      children: [
        NavigationRail(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
            final screenNames = ['shuitie', 'market', 'schedule', 'campus', 'profile'];
            backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
          },
          labelType: NavigationRailLabelType.all,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1A1A2E).withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.9),
          destinations: const [
            NavigationRailDestination(
              icon: Icon(Icons.home_rounded),
              label: Text('首页'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.storefront_rounded),
              label: Text('集市'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.calendar_month_rounded),
              label: Text('课表'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.apartment_rounded),
              label: Text('校园'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.person_rounded),
              label: Text('我的'),
            ),
          ],
        ),
        const VerticalDivider(thickness: 1, width: 1),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: IndexedStack(
                index: _currentIndex,
                children: const [
                  ShuitieScreen(),
                  MarketScreen(),
                  CourseScheduleScreen(),
                  CampusScreen(),
                  ProfileScreen(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(double bottomSafe, AuthProvider authProvider) {
    return IndexedStack(
      index: _currentIndex,
      children: const [
        ShuitieScreen(),
        MarketScreen(),
        CourseScheduleScreen(),
        CampusScreen(),
        ProfileScreen(),
      ],
    );
  }
}
