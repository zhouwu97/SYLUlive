import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../providers/auth_provider.dart';
import '../widgets/bottom_nav.dart';
import 'shuitie_screen.dart';
import 'market_screen.dart';
import 'course_schedule_screen.dart';
import 'teacher_rate_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late PageController _pageController;
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
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(context.read<AuthProvider>());
      }
    });
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
          return Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(
                      child: Text(a['title'] ?? '公告',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold))),
                  if (unread.length > 1)
                    Text('${current + 1}/${unread.length}',
                        style: const TextStyle(color: Colors.grey)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx, false),
                    child: Icon(Icons.close,
                        color: isDark ? Colors.white54 : Colors.grey[600]),
                  ),
                ]),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: SingleChildScrollView(
                    child: Text(a['content'] ?? '',
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: isDark ? Colors.white70 : Colors.grey[800])),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (unread.length > 1)
                        TextButton(
                            onPressed: current > 0
                                ? () {
                                    setLocal(() => current--);
                                  }
                                : null,
                            child: const Text('上一条'))
                      else
                        const Spacer(),
                      ElevatedButton.icon(
                        onPressed: () async {
                          // 标记已读
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
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('已阅读'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ]),
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
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    _pageController.animateToPage(index,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic);
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    final screenNames = ['shuitie', 'market', 'schedule', 'teacher', 'profile'];
    backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncAnnouncementPolling(authProvider);
      }
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: PageView(
        controller: _pageController,
        onPageChanged: _onPageChanged,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          ShuitieScreen(),
          MarketScreen(),
          CourseScheduleScreen(),
          TeacherRateScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavWrapper(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        authProvider: authProvider,
      ),
    );
  }
}
