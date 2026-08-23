import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../services/course_reminder_service.dart';
import '../services/app_resume_coordinator.dart';
import '../theme/app_colors.dart';
import '../utils/app_feedback.dart';
import '../utils/app_navigator.dart' show appNavigatorKey, currentHomeTabIndex;
import '../utils/responsive_util.dart';
import 'course_schedule_settings_screen.dart';
import 'home_widget_settings_screen.dart';
import 'edu_screen.dart';
import '../services/home_widget_service.dart';
import '../models/course_term.dart';
import '../widgets/course/course_empty_state_card.dart';
import '../widgets/course/course_action_menu.dart';
import '../widgets/course/course_import_sheet.dart';
import '../widgets/course/course_term_switch_sheet.dart';
import '../widgets/course/course_preview_sheet.dart';
import '../widgets/course/course_semester_start_picker.dart';
import '../widgets/campus/campus_theme.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 每节课槽的默认高度
const double defaultSlotHeight = 75.0;

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
Color getCourseColor(
  String name, {
  bool isActive = true,
  String? courseCode,
  String? location,
}) {
  final idx = getCourseColorIndex(
    name,
    courseCode: courseCode,
    location: location,
  );
  final base = courseColors[idx];
  return isActive ? base.withOpacity(0.45) : Colors.grey.withOpacity(0.4);
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
  '19:25',
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
  '20:10',
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
  late PageController _weekPageController;
  bool _didLoad = false;
  bool _initializing = true;
  bool _hasCache = false;
  bool _settingsLoaded = false;
  String? _preparedUserId;
  double _scheduleCardOpacity = 0.4;
  double _scheduleSlotHeight = defaultSlotHeight;
  bool _courseReminderEnabled = false;
  int _reminderAdvanceMinutes = 5;
  bool _courseReminderBusy = false;
  int _scheduledReminderCount = 0;
  int _backgroundStatusRequestId = 0;
  bool _isFetchingCourses = false;
  bool _isImportingCourses = false;
  CourseBackgroundKeepAliveStatus _backgroundKeepAliveStatus =
      const CourseBackgroundKeepAliveStatus.unsupported();
  bool _backgroundKeepAliveBusy = false;
  VoidCallback? _unregisterResumeRefresh;
  static const Duration _courseFetchTimeout = Duration(seconds: 25);

  // 有限分页：page 0 = 第1周，page n = 第 n+1 周。边界由 itemCount 提供，
  // 不再用「第 10000 页当中心」的无限分页方案。
  int _weekSettleToken = 0;

  static DateTime _mondayOf(DateTime d) {
    return DateTime(
      d.year,
      d.month,
      d.day,
    ).subtract(Duration(days: d.weekday - 1));
  }

  String _lastTermId = '';
  DateTime? _lastSemesterStart;
  DateTime? _lastSyncedAt;

  DateTime _pageAnchorDate(CourseScheduleProvider sc) {
    final start = sc.currentTerm.startDate;
    if (start != null) {
      final now = DateTime.now();
      final end = start.add(Duration(days: sc.currentTerm.maxWeek * 7));
      if (now.isBefore(start)) return start;
      if (now.isAfter(end))
        return start.add(Duration(days: (sc.currentTerm.maxWeek - 1) * 7));
      return _mondayOf(now);
    }
    return _mondayOf(DateTime.now());
  }

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
    // 开学日在缓存加载后才可知，先无 initialPage，等 semesterStart 到位后由 _resetWeekPager 跳到正确教学周。
    _weekPageController = PageController();
    _loadSettings();
    _unregisterResumeRefresh =
        AppResumeCoordinator.instance.registerVisibleRefresh(
      _refreshAfterResume,
      isVisible: () => currentHomeTabIndex.value == 2,
    );

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
    _unregisterResumeRefresh?.call();
    _weekPageController.dispose();
    super.dispose();
  }

  void _autoLoad(EduProvider edu, CourseScheduleProvider sc) async {
    if (_isFetchingCourses || _isImportingCourses) return;
    if (_didLoad) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    if (!edu.isStatusLoaded) return;
    if (!edu.isBound) {
      _didLoad = true;
      if (mounted) setState(() => _initializing = false);
      return;
    }
    if (sc.isLoading) return;
    _didLoad = true;

    // 首次进课表页只读本机缓存。没有缓存时直接给导入提示，避免教务网络异常时长时间卡在加载中。
    final hasCache = sc.courses.isNotEmpty ||
        await sc.loadCachedCoursesIfAvailable().timeout(
              const Duration(seconds: 2),
              onTimeout: () => false,
            );

    await _syncCourseReminders(sc);
    if (mounted) {
      setState(() {
        _hasCache = hasCache || sc.courses.isNotEmpty;
        _initializing = false;
      });
    }

    if (hasCache) {
      _silentSync(sc);
    }
  }

  void _silentSync(CourseScheduleProvider sc) async {
    try {
      // 未登录不请求
      if (!context.read<AuthProvider>().isLoggedIn) return;
      await _syncCourseReminders(sc);
    } catch (_) {}
  }

  Future<void> _refreshAfterResume() async {
    final auth = context.read<AuthProvider>();
    final edu = context.read<EduProvider>();
    final schedule = context.read<CourseScheduleProvider>();
    final user = auth.user;
    if (!auth.isLoggedIn ||
        user == null ||
        !edu.isBound ||
        _isFetchingCourses ||
        _isImportingCourses) {
      return;
    }

    // 恢复前台只做本地状态同步，不自动访问教务系统。教务课表是低频数据，
    // 用户需要新数据时仍通过“从教务刷新”主动拉取，避免短暂切后台造成重复请求。
    schedule.setUserId(user.id.toString());

    if (mounted) {
      final anchor = _pageAnchorDate(schedule);
      if (!_weekStart.isAtSameMomentAs(anchor)) {
        setState(() => _resetWeekPager(schedule, anchor));
      }
    }

    await _syncCourseReminders(schedule);
    if (mounted) {
      setState(() {
        _hasCache = _hasCache || schedule.courses.isNotEmpty;
      });
    }
  }

  /// 供恢复策略回归测试触发与 AppResumeCoordinator 相同的本地同步路径。
  @visibleForTesting
  Future<void> refreshAfterResumeForTesting() => _refreshAfterResume();

  Future<void> _syncCourseReminders(CourseScheduleProvider sc) async {
    final requestId = ++_backgroundStatusRequestId;
    final remindersEnabled = await CourseReminderService.instance.isEnabled();
    if (!remindersEnabled) {
      if (mounted && requestId == _backgroundStatusRequestId) {
        setState(() {
          _courseReminderEnabled = false;
          _scheduledReminderCount = 0;
        });
      }
      return;
    }

    final result = await CourseReminderService.instance.reschedule(
      courses: sc.courses,
      semesterStart: sc.semesterStart,
    );
    final persistedEnabled = await CourseReminderService.instance.isEnabled();
    if (mounted && requestId == _backgroundStatusRequestId) {
      final actualEnabled = result.enabled && persistedEnabled;
      setState(() {
        _courseReminderEnabled = actualEnabled;
        _scheduledReminderCount = actualEnabled ? result.scheduledCount : 0;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final edu = context.read<EduProvider>();
      final sc = context.read<CourseScheduleProvider>();
      edu.setUserId(uid);
      sc.setUserId(uid);
    });
  }

  int _pageForWeekStart(CourseScheduleProvider sc, DateTime weekStart) {
    final semesterStart = sc.semesterStart;
    if (semesterStart == null) return 0;
    final normalizedStart = _mondayOf(semesterStart);
    final normalizedWeek = _mondayOf(weekStart);
    final diffDays = normalizedWeek.difference(normalizedStart).inDays;
    final page = diffDays ~/ 7;
    return page.clamp(0, sc.currentTerm.maxWeek - 1);
  }

  DateTime _weekStartForPage(CourseScheduleProvider sc, int page) {
    final semesterStart = sc.semesterStart;
    if (semesterStart == null) return _mondayOf(DateTime.now());
    return _mondayOf(semesterStart).add(Duration(days: page * 7));
  }

  bool _canDragWeek(CourseScheduleProvider sc) {
    return sc.semesterStart != null &&
        !_isFetchingCourses &&
        !_isImportingCourses &&
        !_initializing;
  }

  void _resetWeekPager(CourseScheduleProvider sc, DateTime anchor) {
    if (sc.semesterStart == null) {
      _weekStart = _mondayOf(anchor);
      return;
    }
    final page = _pageForWeekStart(sc, anchor);
    final weekStart = _weekStartForPage(sc, page);
    _weekStart = weekStart;
    _weekSettleToken++;
    if (_weekPageController.hasClients) {
      _weekPageController.jumpToPage(page);
    } else {
      // 分页器尚未挂载（如首次设置开学周），重建 controller 使首帧直接落在合法周，
      // 避免先渲染出第 0 页、再跳一次造成标题与页面错位。
      final old = _weekPageController;
      _weekPageController = PageController(initialPage: page);
      old.dispose();
    }
  }

  void _syncWeekStartAfterPageScroll(CourseScheduleProvider sc) {
    if (!mounted || !_weekPageController.hasClients) return;
    final page = _weekPageController.page;
    if (page == null) return;
    final settledPage = page.round().clamp(0, sc.currentTerm.maxWeek - 1);
    final nextWeekStart = _weekStartForPage(sc, settledPage);
    if (_weekStart.isAtSameMomentAs(nextWeekStart)) return;
    setState(() => _weekStart = nextWeekStart);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final cleanLightMode = themeProvider.isCleanBackgroundMode && !isDark;
    final overlayStyle = (cleanLightMode
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light)
        .copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    );

    if (!_settingsLoaded) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: const Scaffold(backgroundColor: Colors.transparent),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        // 课表路由由 GlobalBackgroundWrapper 提供页面背景，保持透明以展示自定义壁纸。
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Consumer<AuthProvider>(
            builder: (context, auth, _) {
              if (!auth.isLoggedIn) {
                return _buildLoginPrompt(context, isDark);
              }
              return Consumer2<EduProvider, CourseScheduleProvider>(
                builder: (context, edu, sc, _) {
                  _autoLoad(edu, sc);

                  // 学期或开学周发生变化时，都要同步周分页器的日期基准。
                  // 仅比较学期 ID 会遗漏同一学期内重新设置开学周的场景。
                  if (sc.currentTerm.id != _lastTermId ||
                      sc.semesterStart != _lastSemesterStart) {
                    _lastTermId = sc.currentTerm.id;
                    _lastSemesterStart = sc.semesterStart;
                    if (_weekPageController.hasClients) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() {
                            _resetWeekPager(sc, _pageAnchorDate(sc));
                          });
                        }
                      });
                    } else {
                      // 首次挂载前直接在 build 中重建 controller，让首帧落在正确周。
                      _resetWeekPager(sc, _pageAnchorDate(sc));
                    }
                  }

                  // 正在初始化 + 没有数据 → 显示课表框架 + 加载动画
                  if ((_initializing || !edu.isStatusLoaded || sc.isLoading) &&
                      sc.courses.isEmpty) {
                    return _buildLoadingOverlay(sc);
                  }

                  if (!edu.isBound) {
                    return _buildBindView(context, edu, sc, isDark);
                  }

                  final hasAnyCourses = sc.courses.isNotEmpty;
                  final hasSemesterStart = sc.semesterStart != null;

                  if (!hasAnyCourses) {
                    return Column(
                      children: [
                        _buildDateHeader(sc),
                        _buildWeekdayHeader(_weekStart, withTimeGutter: true),
                        Expanded(
                          child: _buildNoScheduleState(context, isDark),
                        ),
                      ],
                    );
                  }

                  if (!hasSemesterStart) {
                    return Column(
                      children: [
                        _buildDateHeader(sc),
                        _buildWeekdayHeader(_weekStart, withTimeGutter: true),
                        Expanded(
                          child: _buildSemesterStartRequiredState(
                            context,
                            sc,
                            isDark,
                          ),
                        ),
                      ],
                    );
                  }

                  final mainContent = Column(
                    children: [
                      _buildDateHeader(sc),
                      Expanded(
                        child: _buildCourseGrid(sc),
                      ),
                    ],
                  );

                  if (ResponsiveUtil.isDesktop(context)) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTodayOverview(sc, isDark),
                        Expanded(child: mainContent),
                      ],
                    );
                  }

                  return mainContent;
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTodayOverview(CourseScheduleProvider sc, bool isDark) {
    final today = DateTime.now();
    final academicWeek = sc.getAcademicWeek(_weekStart) ?? 1;
    final targetDate = _weekStart.add(Duration(days: today.weekday - 1));
    final isRealToday = targetDate.year == today.year &&
        targetDate.month == today.month &&
        targetDate.day == today.day;

    final todayCourses = sc.courses.where((c) {
      if (c.weekday != today.weekday) return false;
      if (c.weeks.isNotEmpty && !c.weeks.contains(academicWeek)) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.startSection.compareTo(b.startSection));

    return Container(
      width: 320,
      margin: const EdgeInsets.only(right: 16, top: 16, bottom: 16, left: 16),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0x33FFFFFF)
            : Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.white,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isRealToday ? '今日概览' : '周${_wd[today.weekday - 1]}概览',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${targetDate.month}月${targetDate.day}日 周${_wd[today.weekday - 1]}',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: todayCourses.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.coffee,
                          size: 48,
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '今日无课，好好休息',
                          style: TextStyle(
                            color: isDark ? Colors.white54 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: todayCourses.length,
                    itemBuilder: (context, index) {
                      final c = todayCourses[index];
                      final startIndex = _sectionIndex(c.startSection);
                      final endIndex = _sectionIndex(c.endSection);
                      final color = getCourseColor(
                        c.name,
                        courseCode: c.courseCode,
                        location: c.location,
                      ).withOpacity(1.0);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: color.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: color.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${_starts[startIndex]} - ${_ends[endIndex]}',
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '第${c.startSection}-${c.endSection}节',
                                  style: TextStyle(
                                    color: color.withOpacity(0.8),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              c.name,
                              style: TextStyle(
                                color: isDark ? Colors.white : Colors.black87,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (c.location != null &&
                                c.location!.isNotEmpty) ...[
                              Row(
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    size: 14,
                                    color: color.withOpacity(0.8),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      c.location!,
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white70
                                            : Colors.black87,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (c.teacher != null && c.teacher!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person,
                                    size: 14,
                                    color: color.withOpacity(0.8),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      c.teacher!,
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white70
                                            : Colors.black87,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ====== 加载覆盖层 ======
  Widget _buildLoadingOverlay(CourseScheduleProvider sc) {
    return Column(
      children: [
        _buildDateHeader(sc),
        _buildWeekdayHeader(_weekStart, withTimeGutter: true),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(height: 16),
                Text(
                  '正在加载课表…',
                  style: TextStyle(fontSize: 13, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ====== 上次同步 / 回到本周（UX-6） ======

  Future<void> _loadLastSyncStatus() async {
    final CourseScheduleProvider sc;
    try {
      sc = context.read<CourseScheduleProvider>();
    } catch (_) {
      return;
    }
    final fetchedAt = await sc.loadLastFetchedAt();
    if (!mounted || fetchedAt == null) return;
    setState(() => _lastSyncedAt = fetchedAt);
  }

  String _syncStatusLabel(DateTime fetchedAt, DateTime now) {
    // 保险箱快照的 fetchedAt 是 UTC，展示前先转本地时区，避免跨日判断偏移。
    final local = fetchedAt.toLocal();
    final dayDiff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    if (dayDiff <= 0) {
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      return '本地课表 · 今天 $hh:$mm 已同步';
    }
    return '使用本地课表 · $dayDiff 天前同步';
  }

  /// 当前展示周是否就是自然周（周一起点）。
  bool get _isShowingCurrentWeek =>
      _weekStart.isAtSameMomentAs(_mondayOf(DateTime.now()));

  void _goBackToCurrentWeek() {
    if (!_weekPageController.hasClients) return;
    final sc = context.read<CourseScheduleProvider>();
    if (sc.semesterStart == null) return;
    final targetPage = _pageForWeekStart(sc, _mondayOf(DateTime.now()));
    final settleToken = ++_weekSettleToken;
    if (MediaQuery.disableAnimationsOf(context)) {
      _weekPageController.jumpToPage(targetPage);
      if (mounted) {
        setState(() => _weekStart = _weekStartForPage(sc, targetPage));
      }
      return;
    }
    _weekPageController
        .animateToPage(
      targetPage,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      if (!mounted || settleToken != _weekSettleToken) return;
      setState(() => _weekStart = _weekStartForPage(sc, targetPage));
    });
  }

  Widget _buildBackToCurrentWeekButton() {
    final primary = CampusTheme.primary;
    return Tooltip(
      message: '回到本周',
      child: IconButton(
        key: const ValueKey('schedule-back-to-current-week'),
        tooltip: '回到本周',
        onPressed: _goBackToCurrentWeek,
        color: primary,
        icon: const Icon(Icons.today_rounded),
      ),
    );
  }

  // ====== 顶部表头 ======
  Widget _buildDateHeader(CourseScheduleProvider sc) {
    final academicWeek = sc.getAcademicWeek(_weekStart);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : CampusTheme.text;
    final secondaryColor = CampusTheme.subText;

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏无背景卡片，紧凑布局
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => _pickSemesterStart(context),
                            child: Text(
                              academicWeek != null ? '第 $academicWeek 周' : '课表',
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (!_isShowingCurrentWeek) ...[
                            const Spacer(),
                            _buildBackToCurrentWeekButton(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () => _openTermSwitchSheet(context),
                        child: SizedBox(
                          width: double.infinity,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${sc.currentTerm.title}  ${_weekStart.month}/${_weekStart.day} - ${_weekStart.add(const Duration(days: 6)).month}/${_weekStart.add(const Duration(days: 6)).day}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: secondaryColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_drop_down,
                                  size: 16, color: secondaryColor),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                CourseActionMenu(
                  isDark: isDark,
                  onSelected: (action) {
                    switch (action) {
                      case CourseMenuAction.syncFromEdu:
                        _openCoursePullSheet(context);
                        break;
                      case CourseMenuAction.switchTerm:
                        _openTermSwitchSheet(context);
                        break;

                      case CourseMenuAction.archives:
                        _showArchiveSheet(context, sc);
                        break;
                      case CourseMenuAction.share:
                        _shareSchedule(sc);
                        break;
                      case CourseMenuAction.settings:
                        _openCourseSettings(context, sc);
                        break;
                      case CourseMenuAction.setSemesterStart:
                        unawaited(_pickSemesterStart(context));
                        break;
                    }
                  },
                ),
              ],
            ),
          ),
          if (_lastSyncedAt != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _syncStatusLabel(_lastSyncedAt!, DateTime.now()),
                  style: TextStyle(fontSize: 12, color: secondaryColor),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ====== 星期表头（随分页页一起横向移动；时间轴上方留出同高空位） ======
  /// 表头高度随系统字号缩放，保证大字体下不溢出。日期用 FittedBox 防换行，
  /// 内容高度因此有上界；时间轴顶部留出同高空位即可与网格行对齐。
  double _weekHeaderHeightOf(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return (16 * scale) * 1.5 + 4 + (12 * scale) * 1.5 + 8;
  }

  Widget _buildWeekdayHeader(
    DateTime weekStart, {
    bool withTimeGutter = false,
  }) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = CampusTheme.primary;
    final titleColor = isDark ? Colors.white : CampusTheme.text;
    final secondaryColor = CampusTheme.subText;

    return SizedBox(
      height: _weekHeaderHeightOf(context),
      child: Column(
        children: [
          Row(
            children: [
              if (withTimeGutter) const SizedBox(width: timeColumnWidth),
              ...List.generate(7, (i) {
                final d = weekStart.add(Duration(days: i));
                final isToday = d == todayDate;
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        _wd[i],
                        style: TextStyle(
                          color: isToday ? primaryColor : titleColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${d.month}/${d.day}',
                          style: TextStyle(
                            color: isToday ? primaryColor : secondaryColor,
                            fontSize: 12,
                            fontWeight:
                                isToday ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ====== 未登录引导 ======
  Widget _buildLoginPrompt(BuildContext context, bool isDark) {
    return CourseEmptyStateCard(
      type: CourseEmptyStateType.unlogged,
      isDark: isDark,
      onMainAction: () => Navigator.pushNamed(context, '/login'),
    );
  }

  Widget _buildBindView(
    BuildContext context,
    EduProvider edu,
    CourseScheduleProvider sc,
    bool isDark,
  ) {
    return CourseEmptyStateCard(
      type: CourseEmptyStateType.unbound,
      isDark: isDark,
      onMainAction: () => _showBindDialog(context, edu, sc),
      onSecondaryAction: () => _openEduManage(context),
    );
  }

  void _showBindDialog(
    BuildContext context,
    EduProvider edu,
    CourseScheduleProvider sc,
  ) {
    final sidCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    bool isLoading = false;
    bool eduDataConsentAccepted = false;

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
                  labelText: '教务学号',
                  hintText: '请输入10位学号',
                ),
                maxLength: 10,
                enabled: !isLoading,
              ),
              CheckboxListTile(
                value: eduDataConsentAccepted,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同意教务数据专项授权'),
                subtitle: const Text('用于验证学生身份并保存教务授权状态，可在账号与安全中撤销。'),
                onChanged: isLoading
                    ? null
                    : (value) => setDialogState(
                          () => eduDataConsentAccepted = value ?? false,
                        ),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
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
                      if (!eduDataConsentAccepted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先同意教务数据专项授权')),
                        );
                        return;
                      }
                      setDialogState(() => isLoading = true);
                      final ok = await edu.bind(
                        sidCtrl.text,
                        pwdCtrl.text,
                        eduDataConsentAccepted: true,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (ok && context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('绑定成功')));
                        _didLoad = false;
                        if (mounted) {
                          setState(() {
                            _initializing = false;
                            _hasCache = sc.courses.isNotEmpty;
                          });
                        }
                      } else if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(edu.errorMessage ?? '绑定失败')),
                        );
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('绑定'),
            ),
          ],
        ),
      ),
    );
  }

  // ====== 空状态视图 ======
  Widget _buildNoScheduleState(BuildContext context, bool isDark) {
    final sc = context.watch<CourseScheduleProvider>();
    final isCurrentTerm = sc.currentTerm.isCurrent;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        22,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        children: [
          CourseEmptyStateCard(
            type: isCurrentTerm
                ? CourseEmptyStateType.noCache
                : CourseEmptyStateType.currentTermNoCache,
            isDark: isDark,
            recommendedTerm:
                isCurrentTerm ? sc.currentTerm : CourseTerm.inferCurrentTerm(),
            onMainAction: () => _openCoursePullSheet(context),
            onSecondaryAction: () => _openTermSwitchSheet(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSemesterStartRequiredState(
    BuildContext context,
    CourseScheduleProvider sc,
    bool isDark,
  ) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        28,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            key: const ValueKey('schedule-semester-start-required'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.white12 : CampusTheme.border,
              ),
              boxShadow: isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.025),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
            ),
            child: Column(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  size: 42,
                  color: CampusTheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  '先设置开学第一周',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white : CampusTheme.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '已导入 ${sc.courses.length} 门课程。设置后才会按教学周显示课表，设置前不能切换周次。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : CampusTheme.subText,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _pickSemesterStart(context),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('设置开学第一周'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openEduManage(BuildContext context) async {
    _didLoad = true;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const EduScreen()));
    if (mounted) {
      final sc = context.read<CourseScheduleProvider>();
      if (mounted)
        setState(() {
          _initializing = sc.courses.isEmpty;
        });
      await sc.loadCachedCoursesIfAvailable();
      await _syncCourseReminders(sc);
      if (mounted)
        setState(() {
          _hasCache = sc.courses.isNotEmpty;
          _initializing = false;
        });
    }
  }

  /// 从教务系统重新获取课表。
  Future<void> _fetchCourses(BuildContext context) async {
    if (_isFetchingCourses) return;
    final edu = context.read<EduProvider>();
    final sc = context.read<CourseScheduleProvider>();
    final messenger = ScaffoldMessenger.of(context);

    if (!edu.isBound) {
      messenger.showSnackBar(const SnackBar(content: Text('请先绑定教务账号')));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从教务刷新'),
        content: const Text('将从教务系统重新拉取当前学期课表，并覆盖当前教务课表数据。自定义课程会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                const Text('取消', style: TextStyle(color: CampusTheme.subText)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: CampusTheme.primary,
                foregroundColor: Colors.white),
            child: const Text('刷新'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    if (mounted)
      setState(() {
        _isFetchingCourses = true;
        _initializing = sc.courses.isEmpty;
      });

    // 弹出精美加载动画，防止用户乱点
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 48),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.15),
                  Colors.white.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 渐变圆形进度指示器
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPrimary.withValues(alpha: 0.12),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                      color: AppColors.brandPrimary,
                      strokeWidth: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '正在从教务系统提取课表',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请耐心等待，数据量较大时可能需要几秒…',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final result = await edu
          .getCourses(sc.selectedYear, sc.selectedSemester)
          .timeout(_courseFetchTimeout);
      if (!mounted) return;

      if (result == null || !result.success) {
        Navigator.pop(context); // 关闭加载弹窗
        final errorMsg = result?.errorMessage ?? '未知错误';
        AppFeedback.showErrorDialog(
          context,
          title: '获取课表失败',
          message:
              '这次没有拿到课表，页面会继续保留当前数据。\n\n可能原因：\n1. 教务系统临时不可用或网络波动。\n2. 教务登录状态过期，需要重新绑定。\n3. 当前学期暂时没有课表数据。\n\n详细原因：$errorMsg',
        );
        return;
      }

      final courses = result.data ?? const <Map<String, dynamic>>[];
      if (courses.isEmpty) {
        Navigator.pop(context); // 关闭加载弹窗
        AppFeedback.showErrorDialog(
          context,
          title: '没有可导入的课程',
          message: '教务系统返回了空课表。请确认选择的是当前学期；如果学期正确，可能是学校暂未开放该学期课表。',
        );
        return;
      }

      await sc.applyFetchedCourses(courses);

      await _syncCourseReminders(sc);
      if (!mounted) return;

      if (mounted)
        setState(() {
          _hasCache = sc.courses.isNotEmpty;
          _didLoad = true;
        });

      // 给底层 Widget 预留微小的重绘时间，防止部分机型路由弹窗关闭时阻断下层 setState 渲染
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        Navigator.pop(context); // 确保课表加载进状态后再关闭加载弹窗
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('课表已拉取。首次导入请点击顶部“设置周数”，选择开学第一天。'),
          duration: Duration(seconds: 4),
        ),
      );

      // 成功动画反馈
      showDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black26,
        builder: (ctx) => Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.elasticOut,
            builder: (context, value, child) {
              return Transform.scale(
                scale: value,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 48,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '导入成功！',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '已为您更新 ${sc.courses.length} 门课程',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          decoration: TextDecoration.none,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );

      // 1.5秒后自动关闭成功弹窗
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) Navigator.pop(context);
      });
    } on TimeoutException {
      if (mounted) {
        Navigator.pop(context);
        AppFeedback.showErrorDialog(
          context,
          title: '获取课表超时',
          message:
              '已经等待 ${_courseFetchTimeout.inSeconds} 秒，教务系统仍未返回结果。\n\n你可以稍后重试，或先检查教务账号是否仍然有效；当前页面不会继续卡在加载中。',
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        AppFeedback.showErrorDialog(
          context,
          title: '导入过程异常',
          message: '课表导入被中断，当前页面数据未被覆盖。\n\n详细原因：$e',
        );
      }
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

  Future<void> _openCoursePullSheet(BuildContext context) async {
    if (_isFetchingCourses || _isImportingCourses) return;

    final edu = context.read<EduProvider>();
    final sc = context.read<CourseScheduleProvider>();

    if (!edu.isBound) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先绑定教务账号')),
      );
      return;
    }

    final result = await CourseImportSheet.show(
      context,
      eduProvider: edu,
      initialYear: sc.currentTerm.year,
      initialSemester: sc.currentTerm.semester,
    );

    if (result == null || !mounted) return;

    final confirm = await CoursePreviewSheet.show(
      context,
      courses: result.courses,
      year: result.year,
      semester: result.semester,
      eduProvider: edu,
    );

    if (confirm != true || !mounted) return;

    final oldTerm = sc.currentTerm;
    final sameTerm =
        oldTerm.year == result.year && oldTerm.semester == result.semester;

    final targetTerm =
        sameTerm ? oldTerm : sc.buildTerm(result.year, result.semester);

    setState(() {
      _isFetchingCourses = true;
      _isImportingCourses = true;
      _didLoad = true;
      _initializing = false;
    });

    try {
      final importedCount = await sc.applyFetchedCoursesForTerm(
        term: targetTerm,
        rawCourses: result.courses,
        resetHidden: true,
      );

      if (!mounted) return;

      if (importedCount == 0) {
        final rawCount = result.courses.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              rawCount == 0 ? '该学期没有可导入的课程，请确认学期是否正确' : '课表已获取但解析失败，请检查课程字段格式',
            ),
          ),
        );
        return;
      }

      await _syncCourseReminders(sc);

      if (!mounted) return;

      setState(() {
        _resetWeekPager(sc, _pageAnchorDate(sc));
        _initializing = false;
        _didLoad = true;
        _hasCache = sc.courses.isNotEmpty;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sameTerm ? '当前学期课表已刷新' : '已拉取并切换到 ${sc.currentTerm.title}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('课表拉取失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingCourses = false;
          _isImportingCourses = false;
          _initializing = false;
          _hasCache = sc.courses.isNotEmpty;
        });
      }
    }
  }

  Future<void> _openTermSwitchSheet(BuildContext context) async {
    if (_isFetchingCourses || _isImportingCourses) return;

    final edu = context.read<EduProvider>();
    final sc = context.read<CourseScheduleProvider>();

    final term = await CourseTermSwitchSheet.show(
      context,
      currentTerm: sc.currentTerm,
      enrollmentYear: edu.enrollmentYear,
    );

    if (term == null || !mounted) return;

    setState(() {
      _didLoad = true;
      _initializing = false;
    });

    await sc.switchTerm(term, loadCache: true);

    if (!mounted) return;

    setState(() {
      _resetWeekPager(sc, _pageAnchorDate(sc));
      _hasCache = sc.courses.isNotEmpty;
      _initializing = false;
      _didLoad = true;
    });
  }

  Future<void> _openCourseImportSheet(BuildContext context) {
    return _openCoursePullSheet(context);
  }

  Future<void> _shareSchedule(CourseScheduleProvider sc) async {
    final text = _buildScheduleShareText(sc);
    if (text == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前周暂无可分享的课程')));
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
      ..writeln(
        academicWeek == null
            ? '${_ymd(_weekStart)}-${_ymd(weekEnd)}'
            : '第 $academicWeek 周 ${_ymd(_weekStart)}-${_ymd(weekEnd)}',
      );

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

  // ====== App 内课表显示设置 ======
  static const _scheduleOpacityKey = 'card_opacity';
  static const _scheduleSlotHeightKey = 'slot_height';

  Future<void> _loadSettings() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();

      // 关键路径：不涉及原生通道的高耗时操作，仅读取本地配置
      if (!mounted) return;
      setState(() {
        _scheduleCardOpacity = prefs.getDouble(_scheduleOpacityKey) ?? 0.55;
        _scheduleSlotHeight =
            prefs.getDouble(_scheduleSlotHeightKey) ?? defaultSlotHeight;
        _reminderAdvanceMinutes =
            prefs.getInt('course_reminder_advance_minutes') ?? 5;
        _settingsLoaded = true; // 立即放行 UI 渲染
      });

      // 非关键路径：异步加载后台服务状态和提醒状态，不阻塞 UI
      _loadBackgroundStatusAsync();
      unawaited(_loadLastSyncStatus());
    } catch (e) {
      debugPrint('加载课表设置失败: ${e.runtimeType}');
      if (mounted) {
        setState(() {
          _settingsLoaded = true;
        });
      }
    }
  }

  Future<void> _loadBackgroundStatusAsync() async {
    final requestId = ++_backgroundStatusRequestId;
    try {
      final remindersEnabled = await CourseReminderService.instance.isEnabled();
      final reminderCount =
          await CourseReminderService.instance.pendingCourseReminderCount();
      final backgroundStatus = await CourseReminderService.instance
          .backgroundKeepAliveStatus()
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () =>
                const CourseBackgroundKeepAliveStatus.unsupported(),
          );
      if (mounted && requestId == _backgroundStatusRequestId) {
        setState(() {
          _courseReminderEnabled = remindersEnabled;
          _scheduledReminderCount = reminderCount;
          _backgroundKeepAliveStatus = backgroundStatus;
        });
      }
    } catch (e) {
      debugPrint('后台保活状态检查失败: ${e.runtimeType}');
    }
  }

  Future<void> _saveOpacity(double v) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setDouble(_scheduleOpacityKey, v);
  }

  Future<void> _saveSlotHeight(double v) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setDouble(_scheduleSlotHeightKey, v);
  }

  Future<void> _openCourseSettings(
    BuildContext context,
    CourseScheduleProvider sc,
  ) async {
    final initialSnapshot = await _reloadCourseSettingsSnapshot(sc);
    if (!mounted || !context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CourseScheduleSettingsScreen(
          initialSnapshot: initialSnapshot,
          callbacks: CourseScheduleSettingsCallbacks(
            reloadSnapshot: () => _reloadCourseSettingsSnapshot(sc),
            refreshCourses: () => _openCoursePullSheet(context),
            openArchive: () async {
              _showArchiveSheet(context, sc);
            },
            pickSemesterStart: () => _pickSemesterStart(context),
            shareSchedule: () => _shareSchedule(sc),
            addCustomCourse: () => _showAddCourseDialog(context),
            toggleReminder: (enabled) =>
                _toggleCourseReminderFromSettings(context, sc, enabled),
            changeReminderAdvanceMinutes: (minutes) =>
                _changeReminderAdvanceMinutesFromSettings(sc, minutes),
            requestBackgroundKeepAlive: () =>
                _requestBackgroundKeepAliveFromSettings(context),
            openHomeWidgets: () => _openHomeWidgetSettings(context, sc),
            updateScheduleOpacity: _updateScheduleOpacityFromSettings,
            updateScheduleSlotHeight: _updateScheduleSlotHeightFromSettings,
            resetScheduleDisplay: _resetScheduleDisplayFromSettings,
          ),
        ),
      ),
    );

    if (mounted) setState(() {});
  }

  Future<CourseScheduleSettingsSnapshot> _reloadCourseSettingsSnapshot(
    CourseScheduleProvider sc,
  ) async {
    await _loadBackgroundStatusAsync();
    return _courseSettingsSnapshot(sc);
  }

  CourseScheduleSettingsSnapshot _courseSettingsSnapshot(
    CourseScheduleProvider sc,
  ) {
    return CourseScheduleSettingsSnapshot(
      courseCount: sc.courses.length,
      semesterStartText: sc.semesterStart == null
          ? '未设置，用于计算当前教学周'
          : '当前：${_ymd(sc.semesterStart!)}（周一）',
      reminderEnabled: _courseReminderEnabled,
      reminderAdvanceMinutes: _reminderAdvanceMinutes,
      reminderBusy: _courseReminderBusy,
      scheduledReminderCount: _scheduledReminderCount,
      reminderSummary: _courseReminderEnabled
          ? '提前 $_reminderAdvanceMinutes 分钟 · 已安排 $_scheduledReminderCount 个提醒'
          : '已关闭课程提醒',
      backgroundKeepAliveSubtitle: _backgroundKeepAliveSubtitle(),
      backgroundKeepAliveReady: _backgroundKeepAliveStatus.isReady,
      backgroundKeepAliveSupported: _backgroundKeepAliveStatus.supported,
      backgroundKeepAliveBusy: _backgroundKeepAliveBusy,
      scheduleCardOpacity: _scheduleCardOpacity,
      scheduleSlotHeight: _scheduleSlotHeight,
      defaultSlotHeight: defaultSlotHeight,
    );
  }

  Future<void> _toggleCourseReminderFromSettings(
    BuildContext context,
    CourseScheduleProvider sc,
    bool enabled,
  ) async {
    if (_courseReminderBusy) return;
    if (enabled && sc.semesterStart == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择开学第一天')));
      return;
    }
    if (enabled && sc.courses.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先从教务导入课表')));
      return;
    }
    if (enabled && !await _confirmCourseReminderEnable(context)) {
      return;
    }

    // 使正在返回的旧状态读取失效，避免“关闭后又被旧请求改回开启”。
    ++_backgroundStatusRequestId;
    if (mounted) setState(() => _courseReminderBusy = true);
    try {
      final result = await CourseReminderService.instance.setEnabled(
        enabled,
        courses: sc.courses,
        semesterStart: sc.semesterStart,
      );
      final persistedEnabled = await CourseReminderService.instance.isEnabled();
      if (!mounted) return;

      final actualEnabled = result.enabled && persistedEnabled;
      setState(() {
        _courseReminderEnabled = actualEnabled;
        _scheduledReminderCount = actualEnabled ? result.scheduledCount : 0;
        _courseReminderBusy = false;
      });
      if (context.mounted) {
        AppFeedback.showSnackBar(context, result.message);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _courseReminderBusy = false);
      if (context.mounted) {
        AppFeedback.error('课程提醒设置失败，请稍后重试', context: context);
      }
      debugPrint('更新课程提醒状态失败: $error');
    }
  }

  Future<void> _changeReminderAdvanceMinutesFromSettings(
    CourseScheduleProvider sc,
    int minutes,
  ) async {
    if (_courseReminderBusy) return;
    if (mounted) setState(() => _courseReminderBusy = true);
    await CourseReminderService.instance.setAdvanceMinutes(
      minutes,
      courses: sc.courses,
      semesterStart: sc.semesterStart,
    );
    final count =
        await CourseReminderService.instance.pendingCourseReminderCount();
    if (!mounted) return;
    setState(() {
      _reminderAdvanceMinutes = minutes;
      _scheduledReminderCount = count;
      _courseReminderBusy = false;
    });
  }

  Future<void> _requestBackgroundKeepAliveFromSettings(
    BuildContext context,
  ) async {
    final dialogTheme = CampusTheme.withBrandAccent(Theme.of(context));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: dialogTheme,
        child: AlertDialog(
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
      ),
    );
    if (confirmed != true) return;

    if (mounted) setState(() => _backgroundKeepAliveBusy = true);
    final status = await CourseReminderService.instance
        .requestBackgroundKeepAlivePermissions();
    if (!mounted || !context.mounted) return;
    setState(() {
      _backgroundKeepAliveStatus = status;
      _backgroundKeepAliveBusy = false;
    });
    AppFeedback.showSnackBar(
      context,
      status.isReady ? '后台保活关键权限已开启' : '已打开系统授权页，返回后可再次点击继续设置',
    );
  }

  Future<void> _openHomeWidgetSettings(
    BuildContext context,
    CourseScheduleProvider sc,
  ) async {
    await HomeWidgetService.syncCourseData(sc);
    if (!mounted || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const HomeWidgetSettingsScreen(),
      ),
    );
  }

  Future<void> _updateScheduleOpacityFromSettings(
    double value,
  ) async {
    if (mounted) setState(() => _scheduleCardOpacity = value);
    await _saveOpacity(value);
  }

  Future<void> _updateScheduleSlotHeightFromSettings(
    double value,
  ) async {
    if (mounted) setState(() => _scheduleSlotHeight = value);
    await _saveSlotHeight(value);
  }

  Future<void> _resetScheduleDisplayFromSettings() async {
    if (mounted) {
      setState(() {
        _scheduleCardOpacity = 0.55;
        _scheduleSlotHeight = defaultSlotHeight;
      });
    }
    await _saveOpacity(0.55);
    await _saveSlotHeight(defaultSlotHeight);
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
            const Text('开启后，系统会根据当前课表在每节课开始前提前发送静音提醒。'),
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
        Icon(
          icon,
          size: 18,
          color: isDark ? Colors.white70 : Colors.blueGrey[600],
        ),
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

  // ====== 课表存档面板 ======
  void _showArchiveSheet(BuildContext context, CourseScheduleProvider sc) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final panelColor = isDark ? const Color(0xFF111827) : Colors.white;
    final tileColor =
        isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF8FAFC);
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE5E7EB);
    bool isRefreshing = false;
    bool isLoadingArchive = false;
    String? loadingArchiveId;

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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          top: false,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部拖拽条
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color:
                            isDark ? Colors.white24 : const Color(0xFFD1D5DB),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                // 标题栏
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.collections_bookmark, color: primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '课表存档',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '管理存档、刷新课表',
                              style: TextStyle(
                                fontSize: 13,
                                color:
                                    isDark ? Colors.white60 : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 可滚动内容
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      0,
                      20,
                      24 + MediaQuery.of(ctx).viewInsets.bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 🔄 从教务系统刷新
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(
                                  0xFF6366F1,
                                ).withValues(alpha: isDark ? 0.25 : 0.12),
                                const Color(
                                  0xFF8B5CF6,
                                ).withValues(alpha: isDark ? 0.18 : 0.08),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(
                                0xFF6366F1,
                              ).withValues(alpha: 0.2),
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: isRefreshing
                                  ? null
                                  : () async {
                                      setSheetState(() => isRefreshing = true);
                                      Navigator.pop(ctx);
                                      await _fetchCourses(context);
                                      if (mounted) {
                                        setState(() {});
                                      }
                                    },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    if (isRefreshing)
                                      const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Color(0xFF818CF8),
                                        ),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF6366F1,
                                          ).withValues(alpha: 0.2),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.cloud_download_outlined,
                                          color: Color(0xFF818CF8),
                                          size: 20,
                                        ),
                                      ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            isRefreshing
                                                ? '正在从教务系统拉取…'
                                                : '从教务系统刷新课表',
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? Colors.white
                                                  : Colors.black87,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '拉取最新数据并覆盖当前课表',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? Colors.white54
                                                  : Colors.grey[600],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!isRefreshing)
                                      Icon(
                                        Icons.chevron_right,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.grey[400],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // 💾 保存当前为新存档
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: isDark
                                ? primary.withValues(alpha: 0.08)
                                : primary.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: primary.withValues(
                                alpha: isDark ? 0.16 : 0.10,
                              ),
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: sc.courses.isEmpty
                                  ? null
                                  : () => _showSaveArchiveDialog(
                                        ctx,
                                        sc,
                                        setSheetState,
                                      ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF10B981,
                                        ).withValues(alpha: 0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.save_outlined,
                                        color: Color(0xFF10B981),
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '保存当前课表为新存档',
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? Colors.white
                                                  : Colors.black87,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            sc.courses.isEmpty
                                                ? '当前无课程可保存'
                                                : '当前 ${sc.courses.length} 门课',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? Colors.white70
                                                  : const Color(0xFF49454F),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right,
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.grey[400],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // 存档列表标题
                        Row(
                          children: [
                            Text(
                              '我的存档',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? primary.withValues(alpha: 0.22)
                                    : primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${sc.archives.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.9)
                                      : primary,
                                ),
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () =>
                                  _importFromFile(ctx, sc, setSheetState),
                              icon: const Icon(
                                Icons.file_upload_outlined,
                                size: 16,
                              ),
                              label: const Text('从文件导入'),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // 存档列表
                        if (sc.archives.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 36),
                            decoration: tileDecoration(),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.folder_open_rounded,
                                  size: 64,
                                  color: isDark
                                      ? primary.withValues(alpha: 0.18)
                                      : primary.withValues(alpha: 0.15),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '暂无存档',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.grey[500],
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '点击上方按钮保存当前课表',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.white24
                                        : Colors.grey[400],
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ...sc.archives.asMap().entries.map((entry) {
                            final archive = entry.value;
                            final isLoading = isLoadingArchive &&
                                loadingArchiveId == archive.id;
                            final dateStr =
                                '${archive.createdAt.month}/${archive.createdAt.day} ${archive.createdAt.hour.toString().padLeft(2, '0')}:${archive.createdAt.minute.toString().padLeft(2, '0')}';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Dismissible(
                                key: Key(archive.id),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                ),
                                confirmDismiss: (_) async {
                                  return await showDialog<bool>(
                                    context: ctx,
                                    builder: (dialogCtx) => AlertDialog(
                                      title: const Text('删除存档'),
                                      content: Text('确定删除"${archive.name}"吗？'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dialogCtx, false),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Colors.red,
                                          ),
                                          onPressed: () =>
                                              Navigator.pop(dialogCtx, true),
                                          child: const Text(
                                            '删除',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                onDismissed: (_) async {
                                  await sc.deleteArchive(archive.id);
                                  setSheetState(() {});
                                },
                                child: Container(
                                  decoration: tileDecoration(),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: isLoadingArchive
                                          ? null
                                          : () async {
                                              setSheetState(() {
                                                isLoadingArchive = true;
                                                loadingArchiveId = archive.id;
                                              });
                                              try {
                                                await sc.loadArchive(
                                                  archive.id,
                                                );
                                                await _syncCourseReminders(sc);
                                                if (mounted) {
                                                  setState(() {
                                                    _hasCache = true;
                                                    _didLoad = true;
                                                  });
                                                }
                                                if (ctx.mounted) {
                                                  Navigator.pop(ctx);
                                                }
                                                if (mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        '已载入「${archive.name}」',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              } catch (e) {
                                                if (mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text('载入失败: $e'),
                                                    ),
                                                  );
                                                }
                                              } finally {
                                                if (ctx.mounted) {
                                                  setSheetState(() {
                                                    isLoadingArchive = false;
                                                    loadingArchiveId = null;
                                                  });
                                                }
                                              }
                                            },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: primary.withValues(
                                                  alpha: 0.1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: isLoading
                                                  ? Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                        10,
                                                      ),
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: primary,
                                                      ),
                                                    )
                                                  : Icon(
                                                      Icons.bookmark,
                                                      color: primary,
                                                      size: 20,
                                                    ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    archive.name,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: isDark
                                                          ? Colors.white
                                                          : Colors.black87,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '${archive.courseCount} 门课 · $dateStr',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: isDark
                                                          ? Colors.white54
                                                          : Colors.grey[600],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.ios_share,
                                                size: 18,
                                              ),
                                              color: primary,
                                              tooltip: '导出此存档',
                                              onPressed: () async {
                                                await _exportArchive(
                                                  ctx,
                                                  archive.id,
                                                  archive.name,
                                                );
                                              },
                                            ),
                                            Text(
                                              '← 滑动删除',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: isDark
                                                    ? Colors.white24
                                                    : Colors.grey[400],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        const SizedBox(height: 10),
                        Text(
                          '存档保存在本地，切换账号不会互相影响。',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white30 : Colors.grey[400],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 从文件导入课表存档
  Future<void> _importFromFile(
    BuildContext sheetCtx,
    CourseScheduleProvider sc,
    StateSetter setSheetState,
  ) async {
    final shouldProceed = await showDialog<bool>(
      context: sheetCtx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('从文件导入'),
        content: const Text(
          '请在接下来的文件选择器中选择你之前导出的课表 .json 文件。\n如果是通过微信/QQ等软件收发的，请前往对应软件的下载目录寻找。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('去选择文件'),
          ),
        ],
      ),
    );

    if (shouldProceed != true) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonStr = await file.readAsString();
        final fileName = result.files.single.name.replaceAll('.json', '');

        await sc.importArchiveFromJson(fileName, jsonStr);
        setSheetState(() {});
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已导入存档「$fileName」')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败，文件可能已损坏: $e')));
      }
    }
  }

  /// 导出特定存档到文件 (使用分享/发送功能绕过安卓存储限制)
  Future<void> _exportArchive(
    BuildContext context,
    String archiveId,
    String name,
  ) async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      // 在 provider 中定义的常量：_archiveDataKeyPrefix = 'course_archive_data_v1_'
      final jsonStr = prefs.getString('course_archive_data_v1_$archiveId');
      if (jsonStr == null) throw Exception('存档数据不存在');

      final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final tempDir = Directory.systemTemp;
      final file = File('${tempDir.path}/沈理校园课表_$safeName.json');
      await file.writeAsString(jsonStr);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正在唤起系统菜单，请选择“发送给朋友”或“保存到手机”以导出文件。')),
        );
      }

      await Share.shareXFiles([
        XFile(file.path),
      ], text: '这是我的沈理校园课表存档，可以在App的"从文件导入"功能中恢复。');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  /// 弹出保存存档的命名对话框
  void _showSaveArchiveDialog(
    BuildContext sheetCtx,
    CourseScheduleProvider sc,
    StateSetter setSheetState,
  ) {
    showDialog(
      context: sheetCtx,
      builder: (dialogCtx) =>
          _SaveArchiveDialog(sc: sc, setSheetState: setSheetState),
    );
  }

  Future<void> _pickSemesterStart(BuildContext context) async {
    final sc = context.read<CourseScheduleProvider>();
    final picked = await CourseSemesterStartPicker.show(
      context,
      term: sc.currentTerm,
      initialMonday: sc.semesterStart,
    );
    if (picked != null && mounted && context.mounted) {
      await sc.setSemesterStart(picked);
      if (!mounted || !context.mounted) return;

      // 保存后立即刷新当前周和 PageController 的共同基准，避免页面仍停留在旧周。
      setState(() {
        _lastTermId = sc.currentTerm.id;
        _lastSemesterStart = sc.semesterStart;
        _resetWeekPager(sc, _pageAnchorDate(sc));
      });

      await _syncCourseReminders(sc);
      if (!mounted || !context.mounted) return;
      final savedStart = sc.semesterStart!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '开学第一周已更新：${_ymd(savedStart)}（周一）',
          ),
        ),
      );
    }
  }

  // ====== 自定义课程 ======

  Future<void> _showAddCourseDialog(
    BuildContext context, {
    CourseBlock? editCourse,
  }) {
    // 原有的手动添加状态
    final nameCtrl = TextEditingController(text: editCourse?.name ?? '');
    final teacherCtrl = TextEditingController(text: editCourse?.teacher ?? '');
    final locationCtrl = TextEditingController(
      text: editCourse?.location ?? '',
    );
    int weekday = editCourse?.weekday ?? DateTime.now().weekday;
    int startSection = editCourse?.startSection ?? 1;
    int endSection = editCourse?.endSection ?? 2;
    final sc = context.read<CourseScheduleProvider>();
    final wn = sc.getAcademicWeek(_weekStart) ?? 1;
    int startWeek =
        editCourse?.weeks.isNotEmpty == true ? editCourse!.weeks.first : wn;
    int endWeek = editCourse?.weeks.isNotEmpty == true
        ? editCourse!.weeks.last
        : (wn + 15).clamp(wn, 20);

    // AI 导入模式状态
    bool isAiMode = false;
    final TextEditingController jsonController = TextEditingController();

    // 获取并计算班级号 (学号去掉后两位)
    final edu = context.read<EduProvider>();
    String studentId = edu.studentId;
    String classIdStr = '';
    if (studentId.length > 2) {
      classIdStr = studentId.substring(0, studentId.length - 2);
    }
    bool includeClassId = false;
    String classFilterRule =
        '7. 班级过滤 (Class Filtering)：如果我提供了我的班级号，并且图片中包含班级信息，请严格对比后只提取属于我的课程行。';

    String aiPromptTemplate =
        """你现在是一个专业的“教务数据提取引擎”。请读取我提供的教学日历/课表图片或文字说明，提取其中的课程安排，并严格按照以下 JSON 格式输出数据。

【数据提取规则】
1. 操作类型 (action)：默认为 "add"。如果我额外说明了是删除，请改为 "delete"。
2. 周次处理 (weeks) [极度重要]：请将所有上课的周次展开，提取为一个包含纯数字的数组。例如：“1-4周, 6周”应转换为 [1, 2, 3, 4, 6]；“1-9单周”应转换为 [1, 3, 5, 7, 9]。
3. 数据类型：所有的星期、节次必须转化为纯数字 (int)。例如：“周三”转换为 3，“第5-6节”转换为 startNode: 5, endNode: 6。
4. 处理缺失值：如果图片或文字中缺少关键信息（如未写明教师或教室），请先向我提问确认。如果我回复确实没有，对应的 teacher 或 location 字段再填入空字符串 ""，绝对不要生造数据。
5. 拆分原则：如果一门课跨越了不同的星期或节次，请将其拆分为多个独立的 JSON 对象放入数组中。
6. 输出格式：请务必将 JSON 放在标准的 Markdown 代码块中（```json ... ```）。在输出 JSON 之后，请用中文简短地为我总结一下提取出的结果（“何时、何地、上什么课”），方便我进行核对。
$classFilterRule

【JSON 结构模板】
```json
{
  "action": "add",
  "courses": [
    {
      "name": "大学物理",
      "weeks": [1, 3, 5, 7, 9],
      "dayOfWeek": 3,
      "startNode": 5,
      "endNode": 6,
      "teacher": "张三",
      "location": "A-101"
    }
  ]
}

```""";

    return showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(editCourse == null ? '添加自定义课程' : '编辑自定义课程'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (editCourse == null) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('手动添加')),
                      ButtonSegment(value: true, label: Text('AI 导入')),
                    ],
                    selected: {isAiMode},
                    onSelectionChanged: (Set<bool> newSelection) {
                      setDialogState(() {
                        isAiMode = newSelection.first;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                ],
                if (!isAiMode) ...[
                  // 手动添加视图
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
                        .map(
                          (d) => DropdownMenuItem(
                            value: d,
                            child: Text('周${_wd[d - 1]}'),
                          ),
                        )
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
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text('第$s节'),
                                ),
                              )
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
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text('第$s节'),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setDialogState(
                            () => endSection = v ?? startSection,
                          ),
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
                          value: startWeek.clamp(1, 20),
                          decoration: const InputDecoration(labelText: '开始周'),
                          items: List.generate(20, (i) => i + 1).map((w) {
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
                          value: endWeek.clamp(startWeek, 20),
                          decoration: const InputDecoration(labelText: '结束周'),
                          items: List.generate(20, (i) => i + 1)
                              .where((w) => w >= startWeek)
                              .map(
                                (w) => DropdownMenuItem(
                                  value: w,
                                  child: Text('第$w周'),
                                ),
                              )
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
                ] else ...[
                  // AI 导入视图
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.lightbulb_outline,
                              size: 16,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '使用步骤',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '1. 点击下方按钮复制提示词；',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '2. 发送提示词与课表(图/文)给 AI，建议关闭 AI 的“快速/极速模式”；',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '3. 粘贴 AI 的全部回复。请务必利用 AI 的中文总结核对时间地点。',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: includeClassId,
                          title: const Text('在提示词中加入我的班级号'),
                          subtitle: Text(classIdStr.isEmpty
                              ? '当前未读取到班级号'
                              : '用于过滤 $classIdStr 班课程'),
                          onChanged: classIdStr.isEmpty
                              ? null
                              : (value) {
                                  setState(
                                      () => includeClassId = value == true);
                                },
                        ),
                        Text(
                          'AI 识别结果可能存在遗漏或错误。导入前请逐项核对课程名称、周次、时间、地点和班级范围，并以学校官方课表为准。未经用户确认的结果不会自动写入正式课表。',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('一键复制 AI 提示词'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onPrimaryContainer,
                    ),
                    onPressed: () {
                      final prompt = includeClassId && classIdStr.isNotEmpty
                          ? aiPromptTemplate.replaceFirst(
                              classFilterRule,
                              '7. 班级过滤 (Class Filtering)：当前用户的班级号是“$classIdStr班”。请仅提取属于该班级的课程行。',
                            )
                          : aiPromptTemplate;
                      Clipboard.setData(ClipboardData(text: prompt));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '提示词已复制。请前往你选择的外部 AI 服务提交，处理规则由对应服务商决定。',
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: jsonController,
                    maxLines: 8,
                    minLines: 5,
                    decoration: InputDecoration(
                      hintText: '在此粘贴 AI 生成的 JSON 代码...',
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请确保粘贴的内容包含完整的 { } 结构',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            if (!isAiMode)
              FilledButton(
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('请输入课程名称')));
                    return;
                  }
                  if (editCourse == null) {
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
                  } else {
                    await sc.editCustomCourse(
                      id: editCourse.id,
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
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(editCourse == null ? '课程已添加' : '课程已更新'),
                      ),
                    );
                    await _syncCourseReminders(sc);
                    if (mounted) setState(() => _hasCache = true);
                  }
                  Navigator.pop(dialogCtx);
                },
                child: Text(editCourse == null ? '添加' : '保存'),
              ),
            if (isAiMode)
              FilledButton(
                onPressed: () {
                  _handleAiImport(dialogCtx, jsonController.text);
                },
                child: const Text('解析并导入'),
              ),
          ],
        ),
      ),
    ).then((_) {
      nameCtrl.dispose();
      teacherCtrl.dispose();
      locationCtrl.dispose();
      jsonController.dispose();
    });
  }

  // ====== AI 导入与冲突检测 ======

  void _handleAiImport(BuildContext dialogCtx, String jsonStr) {
    if (jsonStr.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先粘贴 JSON 内容')));
      return;
    }

    try {
      // 1. 智能提取 JSON (支持 AI 输出带有中文总结的内容)
      String cleanJson = jsonStr;

      // 优先寻找 markdown 代码块中的内容
      final RegExp jsonRegex = RegExp(
        r'```(?:json)?\s*(\{.*?\})\s*```',
        dotAll: true,
      );
      final match = jsonRegex.firstMatch(jsonStr);

      if (match != null) {
        cleanJson = match.group(1)!;
      } else {
        // 兜底方案：寻找第一个 { 和最后一个 }
        int start = jsonStr.indexOf('{');
        int end = jsonStr.lastIndexOf('}');
        if (start != -1 && end != -1 && end > start) {
          cleanJson = jsonStr.substring(start, end + 1);
        }
      }

      // 2. 解析 JSON
      Map<String, dynamic> data = jsonDecode(cleanJson);
      String action = data['action'] ?? 'add';
      List<dynamic> rawCourses = data['courses'] ?? [];

      List<Map<String, dynamic>> validCourses = [];

      // 3. 数据类型安全转换
      for (var course in rawCourses) {
        int dayOfWeek = int.tryParse(course['dayOfWeek'].toString()) ?? 1;
        int startNode = int.tryParse(course['startNode'].toString()) ?? 1;
        int endNode = int.tryParse(course['endNode'].toString()) ?? 1;

        List<int> weeks = [];
        if (course['weeks'] != null) {
          weeks = List<int>.from(
            course['weeks'].map((e) => int.tryParse(e.toString()) ?? 0),
          );
        }

        validCourses.add({
          'name': course['name']?.toString() ?? '未知课程',
          'weeks': weeks,
          'dayOfWeek': dayOfWeek,
          'startNode': startNode,
          'endNode': endNode,
          'teacher': course['teacher']?.toString() ?? '',
          'location': course['location']?.toString() ?? '',
        });
      }

      // 4. 获取本地已有课程并进行冲突检测
      final sc = context.read<CourseScheduleProvider>();
      List<CourseBlock> existingCourses = sc.courses;

      List<CourseBlock> conflictingCourses = _checkCourseConflict(
        validCourses,
        existingCourses,
      );

      if (conflictingCourses.isNotEmpty) {
        // 提取冲突的老课名称，防止名称太长截断
        String conflictNames = conflictingCourses
            .map(
              (c) =>
                  "《${c.name} (周${c.weekday} 第${c.startSection}-${c.endSection}节)》",
            )
            .join('、');

        // 发现冲突，弹出三选一对话框
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text("时间重叠提醒"),
            content: Text("检测到新导入的课程与已有课程\n\n$conflictNames\n\n存在时间重叠。请选择操作："),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text("取消"),
              ),
              FilledButton.tonal(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _executeImport(dialogCtx, action, validCourses);
                },
                child: const Text("同时保留(置底)"),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  // 遍历删除冲突的老课
                  for (var oldCourse in conflictingCourses) {
                    await sc.removeCustomCourse(oldCourse.id);
                  }
                  if (mounted) {
                    _executeImport(dialogCtx, action, validCourses);
                  }
                },
                child: const Text(
                  "覆盖原有",
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        );
      } else {
        // 无冲突，直接执行
        _executeImport(dialogCtx, action, validCourses);
      }
    } catch (e) {
      debugPrint('AI 导入解析失败: ${e.runtimeType}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '解析失败，请检查数据格式。',
          ),
        ),
      );
    }
  }

  List<CourseBlock> _checkCourseConflict(
    List<Map<String, dynamic>> newCourses,
    List<CourseBlock> existingCourses,
  ) {
    List<CourseBlock> conflicts = [];
    for (var newCourse in newCourses) {
      for (var existing in existingCourses) {
        if (newCourse['dayOfWeek'] != existing.weekday) continue;

        Set<int> newWeeks = Set<int>.from(newCourse['weeks']);
        Set<int> existingWeeks = Set<int>.from(existing.weeks);

        if (newWeeks.intersection(existingWeeks).isEmpty) continue;

        int start1 = newCourse['startNode'];
        int end1 = newCourse['endNode'];
        int start2 = existing.startSection;
        int end2 = existing.endSection;

        if (start1 <= end2 && end1 >= start2) {
          debugPrint('课表冲突已拦截');
          if (!conflicts.contains(existing)) {
            conflicts.add(existing);
          }
        }
      }
    }
    return conflicts;
  }

  void _executeImport(
    BuildContext dialogCtx,
    String action,
    List<Map<String, dynamic>> courses,
  ) async {
    final sc = context.read<CourseScheduleProvider>();

    int addedCount = 0;
    for (var course in courses) {
      if (action == 'add') {
        int startWeek = 1;
        int endWeek = 16;
        List<int> weeks = course['weeks'];
        if (weeks.isNotEmpty) {
          startWeek = weeks.first;
          endWeek = weeks.last;
        }

        await sc.addCustomCourse(
          name: course['name'],
          weekday: course['dayOfWeek'],
          startSection: course['startNode'],
          endSection: course['endNode'],
          startWeek: startWeek,
          endWeek: endWeek,
          teacher:
              course['teacher'].toString().isEmpty ? null : course['teacher'],
          location:
              course['location'].toString().isEmpty ? null : course['location'],
        );
        addedCount++;
      } else if (action == 'delete') {
        // AI 目前仅按 action:add 处理，delete 未来可扩展根据名字删除等
      }
    }

    if (dialogCtx.mounted) {
      Navigator.pop(dialogCtx); // 关闭底层的大弹窗
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('成功导入 $addedCount 门课程！')));
      await _syncCourseReminders(sc);
      if (mounted) setState(() => _hasCache = true);
    }
  }

  Widget _buildWeekEmptyPlaceholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      child: Column(
        children: [
          Icon(
            Icons.free_breakfast_rounded,
            size: 42,
            color: isDark ? Colors.white24 : const Color(0xFFCBD5D1),
          ),
          const SizedBox(height: 12),
          Text(
            '本周暂无课程',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white70 : CampusTheme.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '可以切换周次，或检查开学周设置是否正确',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.white38 : CampusTheme.subText,
            ),
          ),
        ],
      ),
    );
  }

  // ====== 课程网格 ======
  Widget _buildCourseGrid(CourseScheduleProvider sc) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalH = 12 * _scheduleSlotHeight;
        // 在平板模式下，主课表区域不是全屏宽度，必须使用 LayoutBuilder 获取实际可用宽度
        final screenW = constraints.maxWidth;
        final exactW = (screenW - timeColumnWidth) / 7;
        final headerH = _weekHeaderHeightOf(context);

        return SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 100,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧固定时间轴（顶部留出与星期表头同高的空位，使时间标签与网格行对齐）
              Column(
                children: [
                  SizedBox(height: headerH),
                  SizedBox(height: totalH, child: _buildTimeColumn()),
                ],
              ),
              // 有限周次分页器：星期表头 + 网格（网格线 + 课程卡片）整页随动，
              // 只有时间轴固定在左侧，避免拖动时卡片与星期列错位。
              Expanded(
                child: SizedBox(
                  height: headerH + totalH,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollEndNotification &&
                          notification.metrics.axis == Axis.horizontal) {
                        _syncWeekStartAfterPageScroll(sc);
                      }
                      return false;
                    },
                    child: PageView.builder(
                      controller: _weekPageController,
                      physics: _canDragWeek(sc)
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      itemCount: sc.currentTerm.maxWeek,
                      itemBuilder: (context, page) {
                        final weekStart = _weekStartForPage(sc, page);
                        return Column(
                          children: [
                            _buildWeekdayHeader(weekStart),
                            SizedBox(
                              height: totalH,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  _buildGridLines(exactW),
                                  Positioned.fill(
                                    child: _buildCourseCardsOnly(
                                      sc,
                                      weekStart,
                                      exactW,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimeColumn() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cleanLightMode =
        context.watch<ThemeProvider>().isCleanBackgroundMode && !isDark;
    final timeTextColor =
        cleanLightMode ? const Color(0xFF6B7280) : const Color(0xFF888888);

    return Column(
      children: List.generate(
        12,
        (i) => Container(
          height: _scheduleSlotHeight,
          alignment: Alignment.center,
          child: Text(
            '${i + 1}\n${_starts[i]}\n${_ends[i]}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: timeTextColor,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGridLines(double exactW) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cleanLightMode =
        context.watch<ThemeProvider>().isCleanBackgroundMode && !isDark;
    final verticalLineColor = cleanLightMode
        ? Colors.black.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.16);
    final horizontalLineColor = cleanLightMode
        ? Colors.black.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.2);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 网格线（7 天 × 12 节），随分页页一起移动
        for (int d = 0; d < 7; d++)
          Positioned(
            left: d * exactW,
            top: 0,
            bottom: 0,
            width: exactW,
            child: Column(
              children: List.generate(
                12,
                (i) => Container(
                  height: _scheduleSlotHeight,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: verticalLineColor,
                        width: 0.5,
                      ),
                      bottom: BorderSide(
                        color: horizontalLineColor,
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCourseCardsOnly(
    CourseScheduleProvider sc,
    DateTime weekStart,
    double exactW,
  ) {
    final wn = sc.getAcademicWeek(weekStart);
    if (wn == null) {
      return Center(
        child: _buildWeekEmptyPlaceholder(context),
      );
    }
    final allActive = <CourseBlock>[];
    final allInactive = <CourseBlock>[];
    // 先用活跃课程占据时间槽，非活跃课程只在槽位为空时才显示
    final activeSlots = <String>{};
    final inactiveSeen = <String>{};

    for (final c in sc.courses) {
      if (c.weekday < 1 || c.weekday > 7) continue;
      final key = '${c.weekday}_${c.startSection}';
      if (c.weeks.isEmpty || c.weeks.contains(wn)) {
        // 当前教学周课程优先占据时间槽。
        if (!activeSlots.contains(key)) {
          allActive.add(c);
          activeSlots.add(key);
        }
      }
    }

    // 第二轮：非当前周课程，只在槽位未被活跃课程占用时才显示
    // 已完全结课的课程（所有周数 < 当前周）不显示
    for (final c in sc.courses) {
      if (c.weekday < 1 || c.weekday > 7) continue;
      final key = '${c.weekday}_${c.startSection}';
      if (c.weeks.isNotEmpty && !c.weeks.contains(wn)) {
        // 跳过已完全结课的课程
        if (c.weeks.every((w) => w < wn)) continue;
        if (!activeSlots.contains(key) && !inactiveSeen.contains(key)) {
          allInactive.add(c);
          inactiveSeen.add(key);
        }
      }
    }

    if (allActive.isEmpty && allInactive.isEmpty && sc.courses.isNotEmpty) {
      return Center(
        child: _buildWeekEmptyPlaceholder(context),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 课程卡片（非本周在前，当前周在上层）
        for (final c in allInactive) _buildCard(c, false, exactW, wn),
        for (final c in allActive) _buildCard(c, true, exactW, wn),
      ],
    );
  }

  // ====== 课程卡片 ======
  Widget _buildCard(CourseBlock c, bool isActive, double exactW, int? wn) {
    final top = (c.startSection - 1) * _scheduleSlotHeight;
    final h = c.span * _scheduleSlotHeight - 2;
    String? inactiveLabel;
    if (!isActive && wn != null && c.weeks.isNotEmpty) {
      inactiveLabel = c.weeks.first > wn ? '后期' : '前期';
    }
    final base = getCourseColor(
      c.name,
      isActive: isActive,
      courseCode: c.courseCode,
      location: c.location,
    ).withValues(alpha: isActive ? _scheduleCardOpacity : 0.2);

    // 根据可用宽度动态放大字体和内边距，解决大屏下太空的问题
    final double scale = (exactW / 45.0).clamp(1.0, 1.35);
    final double paddingVal = exactW > 80 ? 6.0 : 3.0;

    // 根据可用高度决定显示内容（优先课名+地点）
    final bool isCompact = h < 70;

    return Positioned(
      key: ValueKey('${c.id}_${c.weekday}_${c.startSection}'),
      left: (c.weekday - 1) * exactW + 1.5,
      width: exactW - 3,
      top: top,
      height: h,
      child: GestureDetector(
        onTap: () => _showDetail(c),
        child: Container(
          alignment: Alignment.topLeft,
          padding: EdgeInsets.all(paddingVal),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(6.0),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (inactiveLabel != null)
                Text(
                  inactiveLabel,
                  style: TextStyle(
                    fontSize: 8 * scale,
                    fontWeight: FontWeight.w700,
                    color: Colors.white54,
                  ),
                ),
              Flexible(
                child: Text(
                  c.name.isNotEmpty ? c.name : '未知课名',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: (isCompact ? 11 : 13) * scale,
                    fontWeight: FontWeight.bold,
                    height: 1.15,
                  ),
                  textAlign: TextAlign.left,
                  maxLines: isCompact ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.location != null && c.location!.isNotEmpty) ...[
                SizedBox(height: 1 * scale),
                Text(
                  '@${c.location}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: (isCompact ? 9 : 11) * scale,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                  textAlign: TextAlign.left,
                ),
              ],
              if (!isCompact && c.teacher != null && c.teacher!.isNotEmpty) ...[
                SizedBox(height: 1 * scale),
                Text(
                  c.teacher!,
                  style: TextStyle(color: Colors.white60, fontSize: 10 * scale),
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
      context: appNavigatorKey.currentContext!,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 4,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    c.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _detailRow(Icons.person_outline, '教师', c.teacher ?? '未知'),
            _detailRow(Icons.location_on_outlined, '教室', c.location ?? '未知'),
            _detailRow(
              Icons.access_time,
              '时间',
              '周$wdn 第${c.startSection}-${c.endSection}节',
            ),
            _detailRow(
              Icons.date_range,
              '周次',
              c.weeks.isNotEmpty ? '第${c.weeks.first}-${c.weeks.last}周' : '未知',
            ),
            if (c.note != null && c.note!.isNotEmpty)
              _detailRow(Icons.note_outlined, '备注', c.note!),
            const SizedBox(height: 16),
            if (c.id < 0) ...[
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.edit, color: Colors.blue),
                    label: const Text(
                      '编辑',
                      style: TextStyle(color: Colors.blue),
                    ),
                    onPressed: () {
                      Navigator.pop(appNavigatorKey.currentContext!);
                      _showAddCourseDialog(context, editCourse: c);
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    label: const Text(
                      '删除',
                      style: TextStyle(color: Colors.red),
                    ),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除课程'),
                          content: const Text('确定要删除这门自定义课程吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text(
                                '删除',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        Navigator.pop(appNavigatorKey.currentContext!);
                        await context
                            .read<CourseScheduleProvider>()
                            .removeCustomCourse(c.id);
                        if (mounted) setState(() {});
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('课程已删除')));
                      }
                    },
                  ),
                ],
              ),
            ],
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
              child: Text(
                v,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      );
}

class _SaveArchiveDialog extends StatefulWidget {
  final CourseScheduleProvider sc;
  final StateSetter setSheetState;

  const _SaveArchiveDialog({required this.sc, required this.setSheetState});

  @override
  State<_SaveArchiveDialog> createState() => _SaveArchiveDialogState();
}

class _SaveArchiveDialogState extends State<_SaveArchiveDialog> {
  late final TextEditingController nameCtrl;

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(
      text: '课表 ${DateTime.now().month}/${DateTime.now().day}',
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存为存档'),
      content: TextField(
        controller: nameCtrl,
        maxLength: 20,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '输入存档名称',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            final scaffoldMessenger = ScaffoldMessenger.of(context);
            Navigator.pop(context);
            await widget.sc.saveCurrentAsArchive(name);
            widget.setSheetState(() {});
            scaffoldMessenger.showSnackBar(
              SnackBar(content: Text('已保存存档「$name」\n如需提取文件，请点击该存档的分享按钮。')),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
