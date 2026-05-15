import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../services/course_reminder_service.dart';
import '../widgets/glass_container.dart';
import '../main.dart' show navigatorKey;
import 'edu_screen.dart';
import 'login_screen.dart';

/// 每节课槽的默认高度
const double defaultSlotHeight = 85.0;

/// 左侧时间轴宽度（必须与表头左侧留空一致）
const double timeColumnWidth = 35.0;

/// 颜色池（5色，确保各不相同）
const List<Color> courseColors = [
  Color(0xFF448AFF), // 蓝
  Color(0xFF00C853), // 绿
  Color(0xFF9C27B0), // 紫
  Color(0xFFFF5252), // 红
  Color(0xFFFF9800), // 橙
];

/// 根据课程名哈希计算颜色索引（不同课程不同颜色，非随机）
/// 空名称时 fallback 到 courseCode + location 做区分
int getCourseColorIndex(String name, {String? courseCode, String? location}) {
  String input = name;
  if (name.isEmpty) {
    input = '${courseCode ?? ''}_${location ?? ''}';
  }
  if (input.isEmpty) return 0;
  int hash = 0;
  for (int i = 0; i < input.length; i++) {
    hash += input.codeUnitAt(i);
  }
  return hash % courseColors.length;
}

/// 获取课程卡片颜色
Color getCourseColor(String name,
    {bool isActive = true, String? courseCode, String? location}) {
  final idx =
      getCourseColorIndex(name, courseCode: courseCode, location: location);
  final base = courseColors[idx];
  return isActive ? base.withOpacity(0.55) : Colors.grey.withOpacity(0.4);
}

/// 星期标签
const _wd = ['一', '二', '三', '四', '五', '六', '日'];

/// 每节课开始时间（每节课45分钟 + 10分钟课间）
const _starts = [
  '08:00',
  '08:55',
  '10:00',
  '10:55',
  '13:00',
  '13:55',
  '14:50',
  '15:45',
  '16:40',
  '17:35',
  '18:30',
  '19:25'
];

/// 每节课结束时间
const _ends = [
  '08:45',
  '09:40',
  '10:45',
  '11:40',
  '13:45',
  '14:40',
  '15:35',
  '16:30',
  '17:25',
  '18:20',
  '19:15',
  '20:10'
];

/// 格式化月/日
String _md(DateTime d) => '${d.month}/${d.day}';

class CourseScheduleScreen extends StatefulWidget {
  const CourseScheduleScreen({super.key});

  @override
  State<CourseScheduleScreen> createState() => _CourseScheduleScreenState();
}

class _CourseScheduleScreenState extends State<CourseScheduleScreen> {
  late DateTime _weekStart;
  bool _didLoad = false;
  bool _initializing = true;
  bool _hasCache = false;
  String? _preparedUserId;
  double _cardOpacity = 0.4;
  double _slotHeight = defaultSlotHeight;
  bool _courseReminderEnabled = false;
  bool _courseReminderBusy = false;
  int _scheduledReminderCount = 0;
  bool _isFetchingCourses = false;
  CourseBackgroundKeepAliveStatus _backgroundKeepAliveStatus =
      const CourseBackgroundKeepAliveStatus.unsupported();
  bool _backgroundKeepAliveBusy = false;

  // 左右滑动切周
  late PageController _weekPageController;

  static DateTime _mondayOf(DateTime d) {
    return DateTime(d.year, d.month, d.day)
        .subtract(Duration(days: d.weekday - 1));
  }

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
    _weekPageController = PageController(initialPage: 500);
    _loadSettings();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.user == null) return;
      final uid = auth.user!.id.toString();
      context.read<EduProvider>().setUserId(uid);
      context.read<CourseScheduleProvider>().setUserId(uid);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareProviders();
  }

  @override
  void dispose() {
    _weekPageController.dispose();
    super.dispose();
  }

  void _autoLoad(EduProvider edu, CourseScheduleProvider sc) async {
    if (_didLoad) return;
    if (!edu.isStatusLoaded) return;
    if (!edu.isBound) {
      _didLoad = true;
      _initializing = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => setState(() {}));
      return;
    }
    if (sc.isLoading) return;
    _didLoad = true;
    _initializing = false;

    // 优先读手机本地缓存
    _hasCache = sc.courses.isNotEmpty || await sc.hasCachedCourses();

    if (_hasCache) {
      // 有缓存 → 立即展示，同时静默后台拉取最新数据
      WidgetsBinding.instance.addPostFrameCallback((_) {
        sc.loadCourses().then((_) => _syncCourseReminders(sc));
      });
      // 静默同步最新课表到缓存
      _silentSync(sc);
      return;
    }

    // 无缓存 → 显示加载中，自动拉取课表
    setState(() => _initializing = true);
    await sc.loadCourses(forceRefresh: true);
    await _syncCourseReminders(sc);
    if (mounted) {
      setState(() {
        _hasCache = sc.courses.isNotEmpty;
        _initializing = false;
      });
    }
  }

  void _silentSync(CourseScheduleProvider sc) async {
    try {
      await sc.loadCourses(forceRefresh: true);
      await _syncCourseReminders(sc);
      // 新数据自动覆盖旧缓存
    } catch (_) {}
  }

  Future<void> _syncCourseReminders(CourseScheduleProvider sc) async {
    if (!await CourseReminderService.instance.isEnabled()) return;
    final result = await CourseReminderService.instance.reschedule(
      courses: sc.courses,
      semesterStart: sc.semesterStart,
    );
    if (mounted) {
      setState(() {
        _courseReminderEnabled = result.enabled;
        _scheduledReminderCount = result.scheduledCount;
      });
    }
  }

  Future<void> _prepareProviders() async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;
    final uid = user.id.toString();
    if (_preparedUserId == uid) return;

    _preparedUserId = uid;
    final edu = context.read<EduProvider>();
    final sc = context.read<CourseScheduleProvider>();
    edu.setUserId(uid);
    sc.setUserId(uid);
    final hasCache = await sc.loadCachedCoursesIfAvailable();
    if (!mounted) return;
    setState(() {
      _hasCache = hasCache || sc.courses.isNotEmpty;
      if (_hasCache) {
        _initializing = false;
      }
    });
  }

  // PageView 滑动切换周
  void _onWeekPageChanged(int index) {
    // 以当前周为基准，向前向后推算
    final now = DateTime.now();
    final currentMonday = _mondayOf(now);
    final targetMonday = currentMonday.add(Duration(days: (index - 500) * 7));
    setState(() => _weekStart = targetMonday);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _hasCache
          ? FloatingActionButton.extended(
              onPressed: () => _showAddCourseDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('添加课程'),
              backgroundColor: Theme.of(context).primaryColor,
            )
          : null,
      body: SafeArea(
        child: Consumer<AuthProvider>(
          builder: (context, auth, _) {
            if (!auth.isLoggedIn) {
              return _buildLoginPrompt(context, isDark);
            }
            return Consumer2<EduProvider, CourseScheduleProvider>(
              builder: (context, edu, sc, _) {
                _autoLoad(edu, sc);

                if (!edu.isStatusLoaded && sc.courses.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (_initializing)
                  return const Center(child: CircularProgressIndicator());

                if (!edu.isBound)
                  return _buildBindView(context, edu, sc, isDark);

                if (sc.isLoading && sc.courses.isEmpty)
                  return const Center(child: CircularProgressIndicator());

                // 无缓存时显示引导
                if (!_hasCache && sc.courses.isEmpty)
                  return _buildNoCacheView(context, isDark);

                return Column(children: [
                  _buildDateHeader(sc),
                  Expanded(
                      child: sc.courses.isEmpty
                          ? _buildEmptyView(context, isDark)
                          : PageView.builder(
                              controller: _weekPageController,
                              onPageChanged: _onWeekPageChanged,
                              itemBuilder: (_, __) => SingleChildScrollView(
                                  child:
                                      _buildCourseGridForWeek(sc, _weekStart)),
                            )),
                ]);
              },
            );
          },
        ),
      ),
    );
  }

  // ====== 顶部表头 ======
  Widget _buildDateHeader(CourseScheduleProvider sc) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final academicWeek = sc.getAcademicWeek(_weekStart);

    return Container(
      color: Colors.transparent,
      child: Column(
        children: [
          // 标题栏：大字号周次 + 日期 + 右侧图标
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _pickSemesterStart(context),
                        child: Text(
                          academicWeek != null ? '第 $academicWeek 周' : '设置学期',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              height: 1.1),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_weekStart.year}/${_weekStart.month}/${_weekStart.day} 周${_wd[_weekStart.weekday - 1]}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 18),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                        icon: _isFetchingCourses
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.arrow_downward_outlined,
                                size: 22),
                        color: Colors.white,
                        disabledColor: Colors.white54,
                        onPressed: _isFetchingCourses
                            ? null
                            : () => _fetchCourses(context),
                        tooltip: '从教务获取课表'),
                    IconButton(
                        icon: const Icon(Icons.share_outlined, size: 22),
                        color: Colors.white,
                        onPressed: () => _shareSchedule(sc),
                        tooltip: '分享'),
                    IconButton(
                        icon: const Icon(Icons.settings_outlined, size: 22),
                        color: Colors.white,
                        onPressed: () => _showOpacitySheet(context, sc),
                        tooltip: '设置'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 星期表头
          Row(
            children: [
              SizedBox(width: timeColumnWidth),
              ...List.generate(7, (i) {
                final d = _weekStart.add(Duration(days: i));
                final isToday = d == todayDate;
                return Expanded(
                  child: Column(
                    children: [
                      Text(_wd[i],
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(_md(d),
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight:
                                  isToday ? FontWeight.w600 : FontWeight.w400)),
                    ],
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ====== 未登录引导 ======
  Widget _buildLoginPrompt(BuildContext context, bool isDark) {
    return Center(
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassContainer(
                padding: const EdgeInsets.all(32),
                borderRadius: 20,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.account_circle,
                      size: 72,
                      color: Theme.of(context)
                          .primaryColor
                          .withValues(alpha: 0.7)),
                  const SizedBox(height: 20),
                  const Text('请先登录',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text('登录后可绑定教务系统，导入课表',
                      style: TextStyle(
                          fontSize: 15,
                          color: isDark ? Colors.grey[400] : Colors.grey[600]),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.push(
                            context,
                            PageRouteBuilder(
                                opaque: false,
                                pageBuilder: (_, __, ___) => LoginScreen())),
                        icon: const Icon(Icons.login),
                        label:
                            const Text('去登录', style: TextStyle(fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                      )),
                ]))));
  }

  // ====== 绑定视图 ======
  Widget _buildBindView(BuildContext context, EduProvider edu,
      CourseScheduleProvider sc, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.school,
                  size: 72,
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.7)),
              const SizedBox(height: 20),
              const Text('绑定教务账号',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                '绑定后可查看课表、成绩等信息',
                style: TextStyle(
                    fontSize: 15,
                    color: isDark ? Colors.grey[400] : Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _showBindDialog(context, edu, sc),
                  icon: const Icon(Icons.link),
                  label: const Text('立即绑定', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBindDialog(
      BuildContext context, EduProvider edu, CourseScheduleProvider sc) {
    final sidCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('绑定教务账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: sidCtrl,
                decoration: const InputDecoration(
                    labelText: '教务学号', hintText: '请输入10位学号'),
                maxLength: 10,
                enabled: !isLoading,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pwdCtrl,
                decoration: const InputDecoration(labelText: '教务密码'),
                obscureText: true,
                enabled: !isLoading,
              ),
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('正在连接教务系统...', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      setDialogState(() => isLoading = true);
                      final ok = await edu.bind(sidCtrl.text, pwdCtrl.text);
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('绑定成功')));
                        _didLoad = false;
                        sc.loadCourses(forceRefresh: true);
                      } else if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(edu.errorMessage ?? '绑定失败')));
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('绑定'),
            ),
          ],
        ),
      ),
    );
  }

  // ====== 空状态视图 ======
  Widget _buildEmptyView(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_busy,
                  size: 64,
                  color: isDark ? Colors.grey[600] : Colors.grey[400]),
              const SizedBox(height: 16),
              const Text('暂无课表数据',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '请先到教务管理获取课表',
                style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.grey[400] : Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _openEduManage(context),
                icon: const Icon(Icons.download),
                label: const Text('获取课表'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEduManage(BuildContext context) async {
    _didLoad = true;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const EduScreen()));
    if (mounted) {
      final sc = context.read<CourseScheduleProvider>();
      await sc.loadCachedCoursesIfAvailable();
      await sc.loadCourses(forceRefresh: true);
      await _syncCourseReminders(sc);
    }
  }

  /// 无缓存时显示引导（用户刚注册或首次使用）
  Widget _buildNoCacheView(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.school_outlined,
                  size: 64,
                  color: isDark ? Colors.grey[600] : Colors.grey[400]),
              const SizedBox(height: 16),
              const Text('首次使用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '检测到您还没有课表，请前往教务导入课表',
                style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.grey[400] : Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EduScreen()),
                  );
                  // 返回后强制刷新课表
                  if (mounted) {
                    final sc = context.read<CourseScheduleProvider>();
                    await sc.loadCachedCoursesIfAvailable();
                    setState(() {
                      _didLoad = false;
                      _hasCache = false;
                    });
                    await sc.loadCourses(forceRefresh: true);
                    await _syncCourseReminders(sc);
                  }
                },
                icon: const Icon(Icons.school),
                label: const Text('去教务导入课表'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 从教务系统重新获取课表。
  Future<void> _fetchCourses(BuildContext context) async {
    if (_isFetchingCourses) return;
    final edu = context.read<EduProvider>();
    final sc = context.read<CourseScheduleProvider>();
    final messenger = ScaffoldMessenger.of(context);

    if (!edu.isBound) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请先绑定教务账号')),
      );
      return;
    }

    setState(() {
      _isFetchingCourses = true;
      _initializing = sc.courses.isEmpty;
    });

    try {
      final result = await edu.getCourses(sc.selectedYear, sc.selectedSemester);
      if (!mounted) return;

      if (result == null || !result.success) {
        messenger.showSnackBar(
          SnackBar(content: Text(result?.errorMessage ?? '获取课表失败')),
        );
        return;
      }

      final courses = result.data ?? const <Map<String, dynamic>>[];
      if (courses.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('教务系统暂无可导入课程')),
        );
        return;
      }

      final synced =
          await edu.syncCourses(sc.selectedYear, sc.selectedSemester, courses);
      if (synced) {
        await sc.loadCourses(forceRefresh: true);
      }
      if (!synced || sc.courses.isEmpty || sc.errorMessage != null) {
        await sc.applyFetchedCourses(courses);
      }

      await _syncCourseReminders(sc);
      if (!mounted) return;

      setState(() {
        _hasCache = sc.courses.isNotEmpty;
        _didLoad = true;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(synced
              ? '已从教务获取 ${sc.courses.length} 门课'
              : '已获取课表，本地同步失败，已先缓存显示'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingCourses = false;
          _initializing = false;
          _hasCache = sc.courses.isNotEmpty;
        });
      }
    }
  }

  Future<void> _shareSchedule(CourseScheduleProvider sc) async {
    final text = _buildScheduleShareText(sc);
    if (text == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前周暂无可分享的课程')),
      );
      return;
    }
    await Share.share(text, subject: '沈理校园课表');
  }

  String? _buildScheduleShareText(CourseScheduleProvider sc) {
    final academicWeek = sc.getAcademicWeek(_weekStart);
    final activeCourses = sc.courses.where((c) {
      if (c.weekday < 1 || c.weekday > 7) return false;
      return academicWeek == null ||
          c.weeks.isEmpty ||
          c.weeks.contains(academicWeek);
    }).toList()
      ..sort((a, b) {
        final dayCompare = a.weekday.compareTo(b.weekday);
        if (dayCompare != 0) return dayCompare;
        return a.startSection.compareTo(b.startSection);
      });

    if (activeCourses.isEmpty) return null;

    final weekEnd = _weekStart.add(const Duration(days: 6));
    final buffer = StringBuffer()
      ..writeln('沈理校园课表')
      ..writeln(academicWeek == null
          ? '${_ymd(_weekStart)}-${_ymd(weekEnd)}'
          : '第 $academicWeek 周 ${_ymd(_weekStart)}-${_ymd(weekEnd)}');

    var currentWeekday = 0;
    for (final course in activeCourses) {
      if (course.weekday != currentWeekday) {
        currentWeekday = course.weekday;
        buffer
          ..writeln()
          ..writeln('周${_wd[course.weekday - 1]}');
      }

      final startIndex = _sectionIndex(course.startSection);
      final endIndex = _sectionIndex(course.endSection);
      final parts = <String>[
        '${_starts[startIndex]}-${_ends[endIndex]}',
        course.name.isEmpty ? '课程' : course.name,
      ];
      final teacher = course.teacher?.trim();
      final location = course.location?.trim();
      if (teacher != null && teacher.isNotEmpty) parts.add('教师：$teacher');
      if (location != null && location.isNotEmpty) parts.add('教室：$location');
      if (course.weeks.isNotEmpty) {
        parts.add('周次：${_formatWeeks(course.weeks)}');
      }
      buffer.writeln(parts.join('  '));
    }

    return buffer.toString().trimRight();
  }

  int _sectionIndex(int section) {
    if (section <= 1) return 0;
    if (section >= _starts.length) return _starts.length - 1;
    return section - 1;
  }

  String _ymd(DateTime d) => '${d.year}/${d.month}/${d.day}';

  String _formatWeeks(List<int> weeks) {
    if (weeks.isEmpty) return '全周';
    final sorted = [...weeks]..sort();
    final ranges = <String>[];
    var start = sorted.first;
    var previous = sorted.first;

    for (final week in sorted.skip(1)) {
      if (week == previous + 1) {
        previous = week;
        continue;
      }
      ranges.add(_formatWeekRange(start, previous));
      start = week;
      previous = week;
    }
    ranges.add(_formatWeekRange(start, previous));
    return ranges.join(',');
  }

  String _formatWeekRange(int start, int end) =>
      start == end ? '$start' : '$start-$end';

  // ====== 透明度设置 ======
  static const _opacityKey = 'card_opacity';
  static const _slotHeightKey = 'slot_height';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final remindersEnabled = await CourseReminderService.instance.isEnabled();
    final reminderCount =
        await CourseReminderService.instance.pendingCourseReminderCount();
    final backgroundStatus =
        await CourseReminderService.instance.backgroundKeepAliveStatus();
    if (!mounted) return;
    setState(() {
      _cardOpacity = prefs.getDouble(_opacityKey) ?? 0.55;
      _slotHeight = prefs.getDouble(_slotHeightKey) ?? defaultSlotHeight;
      _courseReminderEnabled = remindersEnabled;
      _scheduledReminderCount = reminderCount;
      _backgroundKeepAliveStatus = backgroundStatus;
    });
  }

  Future<void> _saveOpacity(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_opacityKey, v);
  }

  Future<void> _saveSlotHeight(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_slotHeightKey, v);
  }

  String _backgroundKeepAliveSubtitle() {
    final status = _backgroundKeepAliveStatus;
    if (!status.supported) {
      return '当前系统无需额外授权';
    }
    final missing = <String>[];
    if (!status.isIgnoringBatteryOptimizations) {
      missing.add('电池优化白名单');
    }
    if (!status.canScheduleExactAlarms) {
      missing.add('精确闹钟');
    }
    if (missing.isEmpty) {
      return '已授权，清除任务卡后仍由系统闹钟唤起提醒';
    }
    return '建议授权：${missing.join('、')}';
  }

  Future<void> _requestBackgroundKeepAlive(
    BuildContext context,
    StateSetter setSheetState,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('后台保活授权'),
        content: const Text(
          '请在系统页面允许忽略电池优化、精确闹钟、自启动或后台运行。'
          '这样即使从任务卡片清除应用，课程提醒也能由系统闹钟唤起。'
          '如果在系统设置里强行停止应用，Android 会禁止所有提醒。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setSheetState(() => _backgroundKeepAliveBusy = true);
    if (mounted) setState(() => _backgroundKeepAliveBusy = true);

    final status = await CourseReminderService.instance
        .requestBackgroundKeepAlivePermissions();

    if (!mounted) return;
    setSheetState(() {
      _backgroundKeepAliveStatus = status;
      _backgroundKeepAliveBusy = false;
    });
    setState(() {
      _backgroundKeepAliveStatus = status;
      _backgroundKeepAliveBusy = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(status.isReady ? '后台保活关键权限已开启' : '已打开系统授权页，返回后可再次点击继续设置'),
      ),
    );
  }

  Future<bool> _confirmCourseReminderEnable(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开启课程提醒'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '开启后，系统会根据当前课表在每节课开始前 5 分钟发送静音提醒。',
            ),
            const SizedBox(height: 12),
            _permissionHint(
              icon: Icons.notifications_none,
              text: '通知权限用于显示上课提醒，不会改变你的系统铃声设置。',
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _permissionHint(
              icon: Icons.schedule,
              text: '精确闹钟用于尽量按时提醒，尤其适合早八和晚课。',
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _permissionHint(
              icon: Icons.battery_saver_outlined,
              text: '后台保活用于清除任务卡片后仍能由系统唤起提醒。',
              isDark: isDark,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不开启'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续授权'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  static Widget _permissionHint({
    required IconData icon,
    required String text,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon,
            size: 18, color: isDark ? Colors.white70 : Colors.blueGrey[600]),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  void _showOpacitySheet(BuildContext context, CourseScheduleProvider sc) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final panelColor = isDark ? const Color(0xFF111827) : Colors.white;
    final tileColor =
        isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF8FAFC);
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE5E7EB);

    BoxDecoration tileDecoration() => BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          top: false,
          child: Container(
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                24 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white24
                                : const Color(0xFFD1D5DB),
                            borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.tune, color: primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('课表设置',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: isDark ? Colors.white : Colors.black87,
                                )),
                            const SizedBox(height: 2),
                            Text('提醒、后台权限和课表显示',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.grey[600],
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: isDark ? 0.14 : 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color:
                              primary.withValues(alpha: isDark ? 0.24 : 0.16)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 20, color: primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '课程提醒会在上课前 5 分钟以静音系统通知提示课程、教师和教室。'
                            '开启后需要通知权限；Android 设备建议继续授权后台保活，'
                            '这样清除任务卡片后仍能按时提醒。',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: tileDecoration(),
                    child: SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      secondary:
                          const Icon(Icons.notifications_active_outlined),
                      title: const Text('课程提醒'),
                      subtitle: Text(_courseReminderEnabled
                          ? '已安排 $_scheduledReminderCount 个提醒，课表更新后会自动重排'
                          : '上课前 5 分钟静音提醒，通知内容包含课程教师'),
                      value: _courseReminderEnabled,
                      onChanged: _courseReminderBusy
                          ? null
                          : (v) async {
                              if (v && sc.semesterStart == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('请先点击周次设置学期开始日期')),
                                );
                                return;
                              }
                              if (v && sc.courses.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('请先从教务导入课表')),
                                );
                                return;
                              }
                              if (v &&
                                  !await _confirmCourseReminderEnable(
                                      context)) {
                                return;
                              }
                              setSheetState(() => _courseReminderBusy = true);
                              if (mounted) {
                                setState(() => _courseReminderBusy = true);
                              }
                              final result = await CourseReminderService
                                  .instance
                                  .setEnabled(
                                v,
                                courses: sc.courses,
                                semesterStart: sc.semesterStart,
                              );
                              final persistedEnabled =
                                  await CourseReminderService.instance
                                      .isEnabled();
                              setSheetState(() {
                                _courseReminderEnabled =
                                    result.enabled && persistedEnabled;
                                _scheduledReminderCount = result.scheduledCount;
                                _courseReminderBusy = false;
                              });
                              if (mounted) {
                                setState(() {
                                  _courseReminderEnabled =
                                      result.enabled && persistedEnabled;
                                  _scheduledReminderCount =
                                      result.scheduledCount;
                                  _courseReminderBusy = false;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(result.message)),
                                );
                              }
                            },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: tileDecoration(),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      leading: Icon(_backgroundKeepAliveStatus.isReady
                          ? Icons.verified_user_outlined
                          : Icons.battery_alert_outlined),
                      title: const Text('后台保活授权'),
                      subtitle: Text(_backgroundKeepAliveSubtitle()),
                      trailing: _backgroundKeepAliveBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: _backgroundKeepAliveStatus.supported &&
                              !_backgroundKeepAliveBusy
                          ? () => _requestBackgroundKeepAlive(
                              context, setSheetState)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('显示效果',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      )),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    decoration: tileDecoration(),
                    child: Column(
                      children: [
                        Row(children: [
                          const Text('透明',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey)),
                          Expanded(
                            child: Slider(
                              value: _cardOpacity,
                              min: 0.1,
                              max: 1.0,
                              divisions: 18,
                              label: '${(_cardOpacity * 100).round()}%',
                              onChanged: (v) {
                                setSheetState(() {});
                                setState(() => _cardOpacity = v);
                                _saveOpacity(v);
                              },
                            ),
                          ),
                          const Text('实色',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey)),
                        ]),
                        Text('${(_cardOpacity * 100).round()}%',
                            style: TextStyle(
                                fontSize: 14,
                                color: primary,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    decoration: tileDecoration(),
                    child: Column(
                      children: [
                        Row(children: [
                          const Text('紧凑',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey)),
                          Expanded(
                            child: Slider(
                              value: _slotHeight,
                              min: 55.0,
                              max: 120.0,
                              divisions: 13,
                              label: '${_slotHeight.round()}',
                              onChanged: (v) {
                                setSheetState(() {});
                                setState(() => _slotHeight = v);
                                _saveSlotHeight(v);
                              },
                            ),
                          ),
                          const Text('宽松',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey)),
                        ]),
                        Text('方块高度 ${_slotHeight.round()}',
                            style: TextStyle(
                                fontSize: 14,
                                color: primary,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('这些设置只影响本机显示和提醒，不会修改服务器接口地址。',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickSemesterStart(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: context.read<CourseScheduleProvider>().semesterStart ??
          DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '选择本学期第一周的星期一',
    );
    if (picked != null) {
      await context.read<CourseScheduleProvider>().setSemesterStart(picked);
      await _syncCourseReminders(context.read<CourseScheduleProvider>());
      if (mounted) setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('已设置开学日期：${picked.year}-${picked.month}-${picked.day}')),
      );
    }
  }

  // ====== 自定义课程 ======

  void _showAddCourseDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final teacherCtrl = TextEditingController();
    final locationCtrl = TextEditingController();
    int weekday = DateTime.now().weekday;
    int startSection = 1;
    int endSection = 2;
    final sc = context.read<CourseScheduleProvider>();
    final wn = sc.getAcademicWeek(_weekStart) ?? 1;
    int startWeek = wn;
    int endWeek = wn + 15;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加自定义课程'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '课程名称',
                    hintText: '如：高等数学',
                  ),
                ),
                const SizedBox(height: 12),
                // 星期几
                DropdownButtonFormField<int>(
                  value: weekday,
                  decoration: const InputDecoration(labelText: '星期'),
                  items: List.generate(7, (i) => i + 1)
                      .map((d) => DropdownMenuItem(
                            value: d,
                            child: Text('周${_wd[d - 1]}'),
                          ))
                      .toList(),
                  onChanged: (v) => setDialogState(() => weekday = v ?? 1),
                ),
                const SizedBox(height: 12),
                // 节次
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: startSection,
                        decoration: const InputDecoration(labelText: '开始节次'),
                        items: List.generate(12, (i) => i + 1)
                            .map((s) => DropdownMenuItem(
                                  value: s,
                                  child: Text('第$s节'),
                                ))
                            .toList(),
                        onChanged: (v) {
                          setDialogState(() {
                            startSection = v ?? 1;
                            if (endSection < startSection) {
                              endSection = startSection;
                            }
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: endSection,
                        decoration: const InputDecoration(labelText: '结束节次'),
                        items: List.generate(12, (i) => i + 1)
                            .where((s) => s >= startSection)
                            .map((s) => DropdownMenuItem(
                                  value: s,
                                  child: Text('第$s节'),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setDialogState(() => endSection = v ?? startSection),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 周次范围
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: startWeek,
                        decoration: const InputDecoration(labelText: '开始周'),
                        items:
                            List.generate(20, (i) => i + 1).map((w) {
                          return DropdownMenuItem(
                            value: w,
                            child: Text('第$w周'),
                          );
                        }).toList(),
                        onChanged: (v) {
                          setDialogState(() {
                            startWeek = v ?? 1;
                            if (endWeek < startWeek) endWeek = startWeek;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: endWeek,
                        decoration: const InputDecoration(labelText: '结束周'),
                        items: List.generate(20, (i) => i + 1)
                            .where((w) => w >= startWeek)
                            .map((w) => DropdownMenuItem(
                                  value: w,
                                  child: Text('第$w周'),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setDialogState(() => endWeek = v ?? startWeek),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: teacherCtrl,
                  decoration: const InputDecoration(
                    labelText: '教师（可选）',
                    hintText: '如：张老师',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationCtrl,
                  decoration: const InputDecoration(
                    labelText: '教室（可选）',
                    hintText: '如：综A101',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入课程名称')),
                  );
                  return;
                }
                await sc.addCustomCourse(
                  name: nameCtrl.text.trim(),
                  weekday: weekday,
                  startSection: startSection,
                  endSection: endSection,
                  startWeek: startWeek,
                  endWeek: endWeek,
                  teacher: teacherCtrl.text.trim().isEmpty
                      ? null
                      : teacherCtrl.text.trim(),
                  location: locationCtrl.text.trim().isEmpty
                      ? null
                      : locationCtrl.text.trim(),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('课程已添加')),
                  );
                  await _syncCourseReminders(sc);
                  setState(() => _hasCache = true);
                }
                Navigator.pop(dialogCtx);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    ).then((_) {
      nameCtrl.dispose();
      teacherCtrl.dispose();
      locationCtrl.dispose();
    });
  }

  // ====== 课程网格（指定某一周） ======
  Widget _buildCourseGridForWeek(
      CourseScheduleProvider sc, DateTime weekStart) {
    final wn = sc.getAcademicWeek(weekStart);
    final totalH = 12 * _slotHeight;
    final screenW = MediaQuery.of(context).size.width;
    final exactW = (screenW - timeColumnWidth) / 7;

    final allActive = <CourseBlock>[];
    final allInactive = <CourseBlock>[];
    // 用于去重：同一天同一时段只保留一个（优先级：当前周 > 未来周 > 过去周）
    final seen = <String>{};

    for (final c in sc.courses) {
      final key = '${c.weekday}_${c.startSection}';
      if (wn == null || c.weeks.isEmpty || c.weeks.contains(wn)) {
        if (!seen.contains(key)) {
          allActive.add(c);
          seen.add(key);
        }
      } else if (!seen.contains(key)) {
        // 非本周课程分两类：未来的（优先）已结束的（次要）
        allInactive.add(c);
        allInactive.sort((a, b) {
          final aFuture = a.weeks.isNotEmpty && a.weeks.first > wn;
          final bFuture = b.weeks.isNotEmpty && b.weeks.first > wn;
          if (aFuture && !bFuture) return -1;
          if (!aFuture && bFuture) return 1;
          return 0;
        });
        seen.add(key);
      }
    }

    return SingleChildScrollView(
      child: SizedBox(
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 左侧时间轴
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: timeColumnWidth,
              child: Column(
                children: List.generate(
                    12,
                    (i) => Container(
                          height: _slotHeight,
                          alignment: Alignment.center,
                          child: Text('${i + 1}\n${_starts[i]}\n${_ends[i]}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF888888),
                                  height: 1.3)),
                        )),
              ),
            ),
            // 网格线（7 天 × 12 节）
            for (int d = 0; d < 7; d++)
              Positioned(
                left: timeColumnWidth + d * exactW,
                top: 0,
                bottom: 0,
                width: exactW,
                child: Column(
                  children: List.generate(
                      12,
                      (i) => Container(
                            height: _slotHeight,
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                    color: Colors.black.withOpacity(0.08),
                                    width: 0.5),
                                bottom: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    width: 0.5),
                              ),
                            ),
                          )),
                ),
              ),
            // 课程卡片（非本周在前，当前周在上层）
            for (final c in allInactive) _buildCard(c, false, exactW, wn),
            for (final c in allActive) _buildCard(c, true, exactW, wn),
          ],
        ),
      ),
    );
  }

  // ====== 课程卡片 ======
  Widget _buildCard(CourseBlock c, bool isActive, double exactW, int? wn) {
    final top = (c.startSection - 1) * _slotHeight;
    final h = c.span * _slotHeight - 4;
    String? inactiveLabel;
    if (!isActive && wn != null && c.weeks.isNotEmpty) {
      inactiveLabel = c.weeks.first > wn ? '后期' : '前期';
    }
    final base = getCourseColor(c.name,
            isActive: isActive, courseCode: c.courseCode, location: c.location)
        .withValues(alpha: isActive ? _cardOpacity : 0.3);

    // 根据可用高度决定显示内容（优先课名+地点）
    final bool isCompact = h < 70;

    return Positioned(
      left: timeColumnWidth + (c.weekday - 1) * exactW + 1,
      width: exactW - 2,
      top: top,
      height: h,
      child: GestureDetector(
        onTap: () => _showDetail(c),
        child: Container(
          alignment: Alignment.topLeft,
          padding: const EdgeInsets.all(4.0),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(12.0),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.5), width: 0.8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (inactiveLabel != null)
                Text(inactiveLabel,
                    style: const TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        color: Colors.white54)),
              Flexible(
                child: Text(
                  c.name.isNotEmpty ? c.name : '未知课名',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: isCompact ? 11 : 13,
                      fontWeight: FontWeight.bold,
                      height: 1.15),
                  textAlign: TextAlign.left,
                  maxLines: isCompact ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.location != null && c.location!.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  '@${c.location}',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: isCompact ? 9 : 11,
                      fontWeight: FontWeight.w600,
                      height: 1.15),
                  textAlign: TextAlign.left,
                ),
              ],
              if (!isCompact && c.teacher != null && c.teacher!.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  c.teacher!,
                  style: const TextStyle(color: Colors.white60, fontSize: 10),
                  textAlign: TextAlign.left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ====== 课程详情 ======
  void _showDetail(CourseBlock c) {
    final color = courseColors[getCourseColorIndex(c.name)];
    final wdn = _wd[c.weekday - 1];

    showModalBottomSheet(
      context: navigatorKey.currentContext!,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                    width: 4,
                    height: 28,
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(c.name,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold))),
              ],
            ),
            const SizedBox(height: 20),
            _detailRow(Icons.person_outline, '教师', c.teacher ?? '未知'),
            _detailRow(Icons.location_on_outlined, '教室', c.location ?? '未知'),
            _detailRow(Icons.access_time, '时间',
                '周$wdn 第${c.startSection}-${c.endSection}节'),
            _detailRow(
                Icons.date_range,
                '周次',
                c.weeks.isNotEmpty
                    ? '第${c.weeks.first}-${c.weeks.last}周'
                    : '未知'),
            if (c.note != null && c.note!.isNotEmpty)
              _detailRow(Icons.note_outlined, '备注', c.note!),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey[600]),
            const SizedBox(width: 12),
            Text('$l：',
                style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500))),
          ],
        ),
      );
}
