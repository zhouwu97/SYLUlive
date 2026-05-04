import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late PageController _pageController;
  bool _checkedAnnouncements = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
  }

  void _checkUnreadAnnouncements() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) { _checkedAnnouncements = false; return; }
    if (_checkedAnnouncements) return;
    _checkedAnnouncements = true;
    try {
      final resp = await auth.dio.get('/announcements/unread');
      final list = resp.data as List? ?? [];
      if (list.isEmpty || !mounted) return;
      _showAnnouncementDialog(list);
    } catch (_) { _checkedAnnouncements = false; }
  }

  void _showAnnouncementDialog(List unread) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    int current = 0;
    final pageCtrl = PageController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final a = unread[current];
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: Text(a['title'] ?? '公告', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                if (unread.length > 1) Text('${current + 1}/${unread.length}', style: TextStyle(color: Colors.grey)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Icon(Icons.close, color: isDark ? Colors.white54 : Colors.grey[600]),
                ),
              ]),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: Text(a['content'] ?? '', style: TextStyle(fontSize: 14, height: 1.6, color: isDark ? Colors.white70 : Colors.grey[800])),
                ),
              ),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                if (unread.length > 1)
                  TextButton(onPressed: current > 0 ? () { setLocal(() => current--); } : null, child: const Text('上一条'))
                else const Spacer(),
                ElevatedButton.icon(
                  onPressed: () async {
                    // 标记已读
                    try {
                      await context.read<AuthProvider>().dio.post('/announcements/${a['id']}/read');
                    } catch (_) {}
                    if (current < unread.length - 1) {
                      setLocal(() => current++);
                    } else {
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('已阅读'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    _pageController.animateToPage(index, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    final screenNames = ['shuitie', 'market', 'schedule', 'teacher', 'profile'];
    backgroundWrapperKey.currentState?.updateScreen(screenNames[index]);
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUnreadAnnouncements());

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
