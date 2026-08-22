import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/campus_calendar.dart';
import '../models/exam_schedule.dart';
import '../models/user_calendar.dart';
import '../providers/campus_calendar_provider.dart';
import '../providers/user_calendar_provider.dart';
import '../services/exam_schedule_repository.dart';
import '../services/app_resume_coordinator.dart';
import '../widgets/campus/campus_theme.dart';

class CampusCalendarScreen extends StatefulWidget {
  const CampusCalendarScreen({super.key});

  @override
  State<CampusCalendarScreen> createState() => _CampusCalendarScreenState();
}

class _CampusCalendarScreenState extends State<CampusCalendarScreen> {
  static const _monthCenterPage = 1200;
  static const _monthPageCount = 2401;

  DateTime _displayMonth = _monthStart(DateTime.now());
  DateTime _selectedDate = dateOnly(DateTime.now());
  late final DateTime _monthBase;
  late final PageController _monthPageController;
  final _examRepository = ExamScheduleRepository();
  List<ExamModel> _importedExams = const [];
  DateTime? _pendingSelectedDate;
  bool _isMonthPagerScrolling = false;
  bool? _pendingMonthPagerScrolling;
  bool _monthPagerScrollUpdateScheduled = false;
  VoidCallback? _unregisterCalendarRefresh;

  @override
  void initState() {
    super.initState();
    _monthBase = _displayMonth;
    _monthPageController = PageController(initialPage: _monthCenterPage);
    _loadImportedExams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = _optionalUserCalendar(context, listen: false);
      provider?.load();
      if (provider != null) {
        _unregisterCalendarRefresh =
            AppResumeCoordinator.instance.registerVisibleRefresh(
          provider.load,
          isVisible: () => mounted,
        );
      }
    });
  }

  @override
  void dispose() {
    _unregisterCalendarRefresh?.call();
    _monthPageController.dispose();
    super.dispose();
  }

  Future<void> _loadImportedExams() async {
    final exams = await _examRepository.load();
    if (!mounted) return;
    setState(() => _importedExams = exams);
  }

  void _showToday() {
    _selectDate(dateOnly(DateTime.now()));
  }

  void _changeMonth(int delta) {
    if (delta == 0) return;
    final currentPage = _monthPageController.hasClients
        ? (_monthPageController.page ?? _monthCenterPage).round()
        : _pageForMonth(_displayMonth);
    _pendingSelectedDate = null;
    _animateToMonthPage(currentPage + delta);
  }

  void _selectDate(DateTime date) {
    final normalized = dateOnly(date);
    final targetMonth = _monthStart(normalized);
    if (sameDay(targetMonth, _displayMonth)) {
      setState(() => _selectedDate = normalized);
      return;
    }
    _pendingSelectedDate = normalized;
    _animateToMonthPage(_pageForMonth(targetMonth));
  }

  DateTime _monthForPage(int page) =>
      DateTime(_monthBase.year, _monthBase.month + page - _monthCenterPage);

  int _pageForMonth(DateTime month) =>
      _monthCenterPage +
      (month.year - _monthBase.year) * 12 +
      month.month -
      _monthBase.month;

  void _animateToMonthPage(int targetPage) {
    final page = targetPage.clamp(0, _monthPageCount - 1);
    if (!_monthPageController.hasClients) {
      _handleMonthPageChanged(page);
      return;
    }
    _monthPageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _handleMonthPageChanged(int page) {
    final month = _monthForPage(page);
    final selectedDate = _pendingSelectedDate;
    setState(() {
      _displayMonth = month;
      _selectedDate = selectedDate != null &&
              selectedDate.year == month.year &&
              selectedDate.month == month.month
          ? selectedDate
          : DateTime(month.year, month.month, 1);
      _pendingSelectedDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<CampusCalendarProvider>();
    final calendar = provider.calendar;
    final background = isDark ? CampusTheme.darkBg : CampusTheme.bg;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('校历'),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark ? Colors.white : _CalendarPalette.ink,
        actions: [
          TextButton(
            onPressed: _showToday,
            style: TextButton.styleFrom(
              foregroundColor: isDark
                  ? _CalendarPalette.darkPrimary
                  : _CalendarPalette.primary,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('今天'),
          ),
          IconButton(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () => _showMoreActions(calendar),
          ),
        ],
      ),
      body: calendar == null
          ? _CalendarLoading(isDark: isDark, error: provider.error)
          : _buildCalendar(calendar, isDark),
    );
  }

  Widget _buildCalendar(CampusCalendar calendar, bool isDark) {
    final userCalendar = _optionalUserCalendar(context, listen: true);
    final selectedInfo = calendar.dayInfo(_selectedDate);
    final selectedExams = _examsOn(_selectedDate, _importedExams);

    return SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _CalendarOverviewCard(
            calendar: calendar,
            semester: selectedInfo.semester,
            selectedInfo: selectedInfo,
            isDark: isDark,
            onSemesterTap: () => _selectSemester(calendar),
          ),
          const SizedBox(height: 16),
          _buildMonthPager(calendar, isDark),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: _DayDetailCard(
              key: ValueKey(formatCalendarDate(selectedInfo.date)),
              info: selectedInfo,
              exams: selectedExams,
              personalEvents:
                  (userCalendar?.events ?? const <UserCalendarEvent>[])
                      .where((event) =>
                          sameDay(event.startAt.toLocal(), selectedInfo.date))
                      .toList(growable: false),
              isDark: isDark,
            ),
          ),
        ],
      ),
    );
  }

  UserCalendarProvider? _optionalUserCalendar(
    BuildContext context, {
    required bool listen,
  }) {
    try {
      return Provider.of<UserCalendarProvider>(context, listen: listen);
    } on ProviderNotFoundException {
      // 保留校历页在独立测试/嵌入场景下的原有可用性；正式 App 启动时由
      // app_bootstrap 注入个人日历 Provider。
      return null;
    }
  }

  Widget _buildMonthPager(CampusCalendar calendar, bool isDark) =>
      AnimatedContainer(
        duration: _isMonthPagerScrolling
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: _monthPagerViewportHeight(calendar),
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleMonthPagerScrollNotification,
          child: PageView.builder(
            controller: _monthPageController,
            itemCount: _monthPageCount,
            onPageChanged: _handleMonthPageChanged,
            itemBuilder: (context, page) {
              final month = _monthForPage(page);
              return Align(
                alignment: Alignment.topCenter,
                child: _CalendarMonthCard(
                  month: month,
                  selectedDate: _selectedDate,
                  calendar: calendar,
                  exams: _importedExams,
                  isDark: isDark,
                  onPrevious: () => _changeMonth(-1),
                  onNext: () => _changeMonth(1),
                  onSelect: _selectDate,
                ),
              );
            },
          ),
        ),
      );

  bool _handleMonthPagerScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _scheduleMonthPagerScrolling(true);
    } else if (notification is ScrollEndNotification) {
      _scheduleMonthPagerScrolling(false);
    }
    return false;
  }

  // 滚动通知可能在 PageView 的布局阶段发出。若此处直接 setState，
  // 会让外层 AnimatedSize 在自身 performLayout 中再次请求布局。
  void _scheduleMonthPagerScrolling(bool value) {
    _pendingMonthPagerScrolling = value;
    if (_monthPagerScrollUpdateScheduled) return;
    _monthPagerScrollUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _monthPagerScrollUpdateScheduled = false;
      final pendingValue = _pendingMonthPagerScrolling;
      _pendingMonthPagerScrolling = null;
      if (!mounted ||
          pendingValue == null ||
          pendingValue == _isMonthPagerScrolling) {
        return;
      }
      setState(() => _isMonthPagerScrolling = pendingValue);
    });
  }

  double _monthPagerViewportHeight(CampusCalendar calendar) {
    final currentHeight = _monthPagerHeight(_displayMonth, calendar);
    if (!_isMonthPagerScrolling) return currentHeight;

    final previousHeight = _monthPagerHeight(
      DateTime(_displayMonth.year, _displayMonth.month - 1),
      calendar,
    );
    final nextHeight = _monthPagerHeight(
      DateTime(_displayMonth.year, _displayMonth.month + 1),
      calendar,
    );
    return [currentHeight, previousHeight, nextHeight]
        .reduce((maximum, height) => maximum > height ? maximum : height);
  }

  void _showMoreActions(CampusCalendar? calendar) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _CalendarActionSheet(
        isDark: isDark,
        onImportantEvents: calendar == null
            ? null
            : () {
                Navigator.of(sheetContext).pop();
                Future<void>.delayed(const Duration(milliseconds: 180), () {
                  if (mounted) _showImportantEvents(calendar, _importedExams);
                });
              },
        onSourceImage: () {
          Navigator.of(sheetContext).pop();
          Future<void>.delayed(const Duration(milliseconds: 180), () {
            if (!mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _OfficialCalendarSourceScreen(),
              ),
            );
          });
        },
      ),
    );
  }

  void _showImportantEvents(
    CampusCalendar calendar,
    List<ExamModel> importedExams,
  ) {
    final now = dateOnly(DateTime.now());
    final events = [...calendar.events]
      ..sort((left, right) => left.startDate.compareTo(right.startDate));
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _CalendarSheetSurface(
        isDark: isDark,
        title: '重要日程',
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              if (importedExams.isNotEmpty) ...[
                const Text(
                  '我的考试',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                for (final exam in importedExams)
                  _ImportedExamTile(
                      exam: exam, isPast: exam.endTime.isBefore(now)),
              ],
              if (importedExams.isNotEmpty && events.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
              if (events.isNotEmpty) ...[
                if (importedExams.isNotEmpty)
                  const Text(
                    '校历日程',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                if (importedExams.isNotEmpty) const SizedBox(height: 6),
                for (final event in events)
                  _ImportantEventTile(
                    event: event,
                    isPast: event.endDate.isBefore(now),
                  ),
              ],
              if (importedExams.isEmpty && events.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 56),
                  child: Center(child: Text('暂无重要日程')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectSemester(CampusCalendar calendar) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '切换学期',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 8),
              for (final semester in calendar.semesters)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(semester.name),
                  subtitle: Text(
                    '${DateFormat('yyyy年M月d日').format(semester.startDate)} - ${DateFormat('yyyy年M月d日').format(semester.endDate)}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _selectDate(semester.startDate);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarPalette {
  static const Color primary = Color(0xFF4B5F9C);
  static const Color darkPrimary = Color(0xFFBAC6FF);
  static const Color primaryLight = Color(0xFFEEF1FF);
  static const Color ink = Color(0xFF292D3A);
  static const Color muted = Color(0xFF747887);
  static const Color border = Color(0xFFE6E7EE);
  static const Color weekend = Color(0xFFD96A62);
  static const Color warm = Color(0xFFF5AD62);

  static BoxDecoration cardDecoration(bool isDark) => BoxDecoration(
        color: isDark ? const Color(0xFF1E222B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : border,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF202738).withValues(alpha: 0.045),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
      );
}

class _CalendarActionSheet extends StatelessWidget {
  const _CalendarActionSheet({
    required this.isDark,
    required this.onImportantEvents,
    required this.onSourceImage,
  });

  final bool isDark;
  final VoidCallback? onImportantEvents;
  final VoidCallback onSourceImage;

  @override
  Widget build(BuildContext context) => _CalendarSheetSurface(
        isDark: isDark,
        title: '更多操作',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CalendarActionTile(
                icon: Icons.event_note_rounded,
                title: '本学期重要日程',
                color: _CalendarPalette.primary,
                isDark: isDark,
                onTap: onImportantEvents,
              ),
              Divider(
                height: 1,
                indent: 58,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : _CalendarPalette.border,
              ),
              _CalendarActionTile(
                icon: Icons.image_search_rounded,
                title: '查看官方原图',
                color: _CalendarPalette.warm,
                isDark: isDark,
                onTap: onSourceImage,
              ),
            ],
          ),
        ),
      );
}

class _CalendarSheetSurface extends StatelessWidget {
  const _CalendarSheetSurface({
    required this.isDark,
    required this.title,
    required this.child,
  });

  final bool isDark;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E222B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : _CalendarPalette.border,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : const Color(0xFFD8DAE3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : _CalendarPalette.ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      );
}

class _CalendarActionTile extends StatelessWidget {
  const _CalendarActionTile({
    required this.icon,
    required this.title,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Color color;
  final bool isDark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: isDark ? 0.2 : 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, size: 21, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : _CalendarPalette.ink,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: isDark ? Colors.white38 : _CalendarPalette.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _CalendarOverviewCard extends StatelessWidget {
  const _CalendarOverviewCard({
    required this.calendar,
    required this.semester,
    required this.selectedInfo,
    required this.isDark,
    required this.onSemesterTap,
  });

  final CampusCalendar calendar;
  final CampusSemester? semester;
  final CampusDayInfo selectedInfo;
  final bool isDark;
  final VoidCallback onSemesterTap;

  @override
  Widget build(BuildContext context) {
    final weekLabel = selectedInfo.teachingWeek == null
        ? '非教学周'
        : '第 ${selectedInfo.teachingWeek!.week} 教学周';
    final titleColor = isDark ? Colors.white : _CalendarPalette.ink;
    final mutedColor = isDark ? Colors.white60 : _CalendarPalette.muted;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 17, 14, 17),
      decoration: _CalendarPalette.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            calendar.school,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: mutedColor,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${calendar.academicYear} 学年',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                  ),
                ),
              ),
              _SemesterButton(
                label: semester?.name ?? '假期',
                isDark: isDark,
                onTap: onSemesterTap,
              ),
            ],
          ),
          const SizedBox(height: 17),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : _CalendarPalette.primaryLight,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 16,
                  color: isDark
                      ? _CalendarPalette.darkPrimary
                      : _CalendarPalette.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${DateFormat('M月d日').format(selectedInfo.date)} ${_weekdayLabel(selectedInfo.date)}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                ),
                Text(
                  weekLabel,
                  style: TextStyle(fontSize: 13, color: mutedColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SemesterButton extends StatelessWidget {
  const _SemesterButton({
    required this.label,
    required this.isDark,
    required this.onTap,
  });

  final String label;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: isDark
                  ? _CalendarPalette.darkPrimary.withValues(alpha: 0.14)
                  : _CalendarPalette.primaryLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 92),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? _CalendarPalette.darkPrimary
                          : _CalendarPalette.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more_rounded,
                  size: 17,
                  color: isDark
                      ? _CalendarPalette.darkPrimary
                      : _CalendarPalette.primary,
                ),
              ],
            ),
          ),
        ),
      );
}

class _CalendarMonthCard extends StatelessWidget {
  const _CalendarMonthCard({
    required this.month,
    required this.selectedDate,
    required this.calendar,
    required this.exams,
    required this.isDark,
    required this.onPrevious,
    required this.onNext,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selectedDate;
  final CampusCalendar calendar;
  final List<ExamModel> exams;
  final bool isDark;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final hasMarkers =
        calendar.events.isNotEmpty || calendar.dayOverrides.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: _CalendarPalette.cardDecoration(isDark),
      child: Column(
        children: [
          _MonthNavigator(
            month: month,
            isDark: isDark,
            onPrevious: onPrevious,
            onNext: onNext,
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              _WeekdayLabel('一'),
              _WeekdayLabel('二'),
              _WeekdayLabel('三'),
              _WeekdayLabel('四'),
              _WeekdayLabel('五'),
              _WeekdayLabel('六', isWeekend: true),
              _WeekdayLabel('日', isWeekend: true),
            ],
          ),
          const SizedBox(height: 6),
          _CalendarGrid(
            month: month,
            selectedDate: selectedDate,
            calendar: calendar,
            exams: exams,
            isDark: isDark,
            onSelect: onSelect,
          ),
          if (hasMarkers) ...[
            const SizedBox(height: 10),
            _CalendarLegend(isDark: isDark),
          ],
        ],
      ),
    );
  }
}

class _MonthNavigator extends StatelessWidget {
  const _MonthNavigator({
    required this.month,
    required this.isDark,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final bool isDark;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _MonthChangeButton(
          tooltip: '上个月',
          icon: Icons.chevron_left_rounded,
          isDark: isDark,
          onPressed: onPrevious,
        ),
        Expanded(
          child: Center(
            child: Text(
              DateFormat('yyyy年M月').format(month),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : _CalendarPalette.ink,
              ),
            ),
          ),
        ),
        _MonthChangeButton(
          tooltip: '下个月',
          icon: Icons.chevron_right_rounded,
          isDark: isDark,
          onPressed: onNext,
        ),
      ],
    );
  }
}

class _MonthChangeButton extends StatelessWidget {
  const _MonthChangeButton({
    required this.tooltip,
    required this.icon,
    required this.isDark,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool isDark;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : _CalendarPalette.primaryLight,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 21,
            color: isDark
                ? _CalendarPalette.darkPrimary
                : _CalendarPalette.primary,
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      );
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({
    required this.month,
    required this.selectedDate,
    required this.calendar,
    required this.exams,
    required this.isDark,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selectedDate;
  final CampusCalendar calendar;
  final List<ExamModel> exams;
  final bool isDark;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final firstVisible = month.subtract(Duration(days: month.weekday - 1));
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final trailingDays = (7 - monthEnd.weekday) % 7;
    final count = monthEnd.day + (month.weekday - 1) + trailingDays;
    final rows = (count / 7).ceil();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows * 7,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisExtent: 52,
      ),
      itemBuilder: (context, index) {
        final date = firstVisible.add(Duration(days: index));
        return _CalendarDayCell(
          date: date,
          inCurrentMonth: date.month == month.month,
          selected: sameDay(date, selectedDate),
          today: sameDay(date, DateTime.now()),
          info: calendar.dayInfo(date),
          exams: _examsOn(date, exams),
          isDark: isDark,
          onTap: () => onSelect(date),
        );
      },
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  const _WeekdayLabel(this.label, {this.isWeekend = false});

  final String label;
  final bool isWeekend;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color:
                  isWeekend ? _CalendarPalette.weekend : _CalendarPalette.muted,
            ),
          ),
        ),
      );
}

class _CalendarDayCell extends StatelessWidget {
  const _CalendarDayCell({
    required this.date,
    required this.inCurrentMonth,
    required this.selected,
    required this.today,
    required this.info,
    required this.exams,
    required this.isDark,
    required this.onTap,
  });

  final DateTime date;
  final bool inCurrentMonth;
  final bool selected;
  final bool today;
  final CampusDayInfo info;
  final List<ExamModel> exams;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final weekend = date.weekday >= DateTime.saturday;
    final textColor = !inCurrentMonth
        ? (isDark ? Colors.white24 : Colors.black26)
        : selected
            ? Colors.white
            : weekend
                ? _CalendarPalette.weekend
                : (isDark ? Colors.white : _CalendarPalette.ink);
    final primary =
        isDark ? _CalendarPalette.darkPrimary : _CalendarPalette.primary;
    final markers = [
      ...info.markers,
      for (final exam in exams)
        CampusCalendarMarker(badge: '考', type: 'exam', title: exam.name),
    ];

    return Semantics(
      button: true,
      selected: selected,
      label: '${date.month}月${date.day}日',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? primary : Colors.transparent,
                  shape: BoxShape.circle,
                  border: today && !selected
                      ? Border.all(color: primary, width: 1.4)
                      : null,
                ),
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        selected || today ? FontWeight.w800 : FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
              SizedBox(
                height: 10,
                child: _MarkerRow(markers: markers, selected: selected),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarkerRow extends StatelessWidget {
  const _MarkerRow({required this.markers, required this.selected});

  final List<CampusCalendarMarker> markers;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) return const SizedBox.shrink();
    final prominent = markers
        .where((marker) => const {'休', '调', '考'}.contains(marker.badge))
        .take(1)
        .toList(growable: false);
    if (prominent.isNotEmpty) {
      return _MarkerBadge(marker: prominent.first, selected: selected);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final marker in markers.take(3))
          Container(
            width: 4,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: selected ? Colors.white70 : _markerColor(marker.type),
              shape: BoxShape.circle,
            ),
          ),
      ],
    );
  }
}

class _MarkerBadge extends StatelessWidget {
  const _MarkerBadge({required this.marker, required this.selected});

  final CampusCalendarMarker marker;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = _markerColor(marker.type);
    return Container(
      constraints: const BoxConstraints(minWidth: 15),
      height: 10,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.25)
            : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        marker.badge,
        style: TextStyle(
          fontSize: 8,
          height: 1,
          fontWeight: FontWeight.w800,
          color: selected ? Colors.white : color,
        ),
      ),
    );
  }
}

class _CalendarLegend extends StatelessWidget {
  const _CalendarLegend({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white60 : _CalendarPalette.muted;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        _LegendItem(
            label: '休 假期',
            color: _markerColor('holiday'),
            textColor: textColor),
        _LegendItem(
            label: '调 调课',
            color: _markerColor('makeup_teaching'),
            textColor: textColor),
        _LegendItem(
            label: '考 考试', color: _markerColor('exam'), textColor: textColor),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: textColor)),
        ],
      );
}

class _DayDetailCard extends StatelessWidget {
  const _DayDetailCard({
    super.key,
    required this.info,
    required this.exams,
    required this.personalEvents,
    required this.isDark,
  });

  final CampusDayInfo info;
  final List<ExamModel> exams;
  final List<UserCalendarEvent> personalEvents;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? Colors.white60 : _CalendarPalette.muted;
    final titleColor = isDark ? Colors.white : _CalendarPalette.ink;
    final status = _dayStatus(info, exams);
    final eventLines = <_DayDetailLine>[
      ..._eventLines(info, exams),
      ...personalEvents.map(
        (event) => _DayDetailLine(
          title: event.title,
          description: event.location.isEmpty ? '我的日历' : event.location,
          icon: Icons.event_note_rounded,
          color: _CalendarPalette.primary,
        ),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _CalendarPalette.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isDark
                      ? _CalendarPalette.darkPrimary.withValues(alpha: 0.14)
                      : _CalendarPalette.primaryLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${info.date.day}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: isDark
                        ? _CalendarPalette.darkPrimary
                        : _CalendarPalette.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _weekdayLabel(info.date),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('yyyy年M月').format(info.date),
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                  ],
                ),
              ),
              _StatusChip(label: status, isDark: isDark),
            ],
          ),
          const SizedBox(height: 15),
          for (final line in eventLines) ...[
            _DetailLine(line: line, isDark: isDark),
            if (line != eventLines.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.isDark});

  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 96),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isDark
              ? _CalendarPalette.darkPrimary.withValues(alpha: 0.14)
              : _CalendarPalette.primaryLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isDark
                ? _CalendarPalette.darkPrimary
                : _CalendarPalette.primary,
          ),
        ),
      );
}

class _DayDetailLine {
  const _DayDetailLine({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color color;
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.line, required this.isDark});

  final _DayDetailLine line;
  final bool isDark;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: line.color.withValues(alpha: isDark ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(line.icon, size: 16, color: line.color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : _CalendarPalette.ink,
                  ),
                ),
                if (line.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    line.description,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: isDark ? Colors.white60 : _CalendarPalette.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
}

class _ImportantEventTile extends StatelessWidget {
  const _ImportantEventTile({required this.event, required this.isPast});

  final CampusCalendarEvent event;
  final bool isPast;

  @override
  Widget build(BuildContext context) {
    final color = _markerColor(event.type);
    return Opacity(
      opacity: isPast ? 0.55 : 1,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            event.badge,
            style: TextStyle(fontWeight: FontWeight.w800, color: color),
          ),
        ),
        title: Text(
          event.title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${DateFormat('M月d日').format(event.startDate)}${sameDay(event.startDate, event.endDate) ? '' : ' - ${DateFormat('M月d日').format(event.endDate)}'}',
        ),
      ),
    );
  }
}

class _ImportedExamTile extends StatelessWidget {
  const _ImportedExamTile({required this.exam, required this.isPast});

  final ExamModel exam;
  final bool isPast;

  @override
  Widget build(BuildContext context) {
    final color = _markerColor('exam');
    return Opacity(
      opacity: isPast ? 0.55 : 1,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.edit_calendar_rounded, size: 19, color: color),
        ),
        title: Text(
          exam.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(_examScheduleLabel(exam)),
      ),
    );
  }
}

class _CalendarLoading extends StatelessWidget {
  const _CalendarLoading({required this.isDark, required this.error});

  final bool isDark;
  final String? error;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error == null)
              const CircularProgressIndicator(color: _CalendarPalette.primary)
            else
              const Icon(Icons.calendar_month_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              error ?? '正在读取校历',
              style: TextStyle(
                color: isDark ? Colors.white60 : _CalendarPalette.muted,
              ),
            ),
          ],
        ),
      );
}

class _OfficialCalendarSourceScreen extends StatelessWidget {
  const _OfficialCalendarSourceScreen();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? CampusTheme.darkBg : CampusTheme.bg,
      appBar: AppBar(
        title: const Text('官方校历原图'),
        backgroundColor: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        surfaceTintColor: Colors.transparent,
      ),
      body: InteractiveViewer(
        minScale: 0.7,
        maxScale: 4,
        child: Center(
          child: Image.asset('assets/images/xiaoli.jpg', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

String _dayStatus(CampusDayInfo info, List<ExamModel> exams) {
  if (info.override != null) return info.override!.title;
  if (info.events.isNotEmpty) return info.events.first.title;
  if (exams.isNotEmpty) return '考试';
  if (info.isTeachingDay) return '正常教学';
  if (info.isWeekend) return '周末';
  return '非教学周';
}

List<_DayDetailLine> _eventLines(CampusDayInfo info, List<ExamModel> exams) {
  final lines = <_DayDetailLine>[];
  if (info.override != null) {
    lines.add(
      _DayDetailLine(
        title: info.override!.title,
        description: info.override!.description,
        icon: _detailIcon(info.override!.dayMode),
        color: _markerColor(info.override!.dayMode),
      ),
    );
  }
  for (final event in info.events) {
    lines.add(
      _DayDetailLine(
        title: event.title,
        description: event.description,
        icon: _detailIcon(event.type),
        color: _markerColor(event.type),
      ),
    );
  }
  for (final exam in exams) {
    lines.add(
      _DayDetailLine(
        title: exam.name,
        description: _examScheduleLabel(exam, includeDate: false),
        icon: Icons.edit_calendar_rounded,
        color: _markerColor('exam'),
      ),
    );
  }
  if (lines.isNotEmpty) return lines;

  if (info.isTeachingDay) {
    return const [
      _DayDetailLine(
        title: '正常教学',
        description: '按正常课程安排上课。',
        icon: Icons.school_rounded,
        color: _CalendarPalette.primary,
      ),
    ];
  }
  if (info.isWeekend) {
    return const [
      _DayDetailLine(
        title: '周末',
        description: '非学校明确放假日，不显示法定假期标记。',
        icon: Icons.weekend_rounded,
        color: _CalendarPalette.warm,
      ),
    ];
  }
  return const [
    _DayDetailLine(
      title: '非教学周',
      description: '寒暑假或非当前校历范围。',
      icon: Icons.event_available_rounded,
      color: _CalendarPalette.primary,
    ),
  ];
}

List<ExamModel> _examsOn(DateTime date, List<ExamModel> exams) =>
    exams.where((exam) => exam.occursOn(date)).toList(growable: false);

String _examScheduleLabel(ExamModel exam, {bool includeDate = true}) {
  final start = exam.startTime;
  final end = exam.endTime;
  final time =
      '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} - ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  final date = includeDate ? '${DateFormat('M月d日').format(start)} ' : '';
  return '$date$time${exam.location.isEmpty ? '' : ' · ${exam.location}'}';
}

double _monthPagerHeight(DateTime month, CampusCalendar calendar) {
  final monthEnd = DateTime(month.year, month.month + 1, 0);
  final trailingDays = (7 - monthEnd.weekday) % 7;
  final visibleDays = monthEnd.day + (month.weekday - 1) + trailingDays;
  final rows = (visibleDays / 7).ceil();
  final hasMarkers =
      calendar.events.isNotEmpty || calendar.dayOverrides.isNotEmpty;
  return 102 + rows * 52 + (hasMarkers ? 24 : 0);
}

DateTime _monthStart(DateTime date) => DateTime(date.year, date.month);

String _weekdayLabel(DateTime date) => switch (date.weekday) {
      DateTime.monday => '星期一',
      DateTime.tuesday => '星期二',
      DateTime.wednesday => '星期三',
      DateTime.thursday => '星期四',
      DateTime.friday => '星期五',
      DateTime.saturday => '星期六',
      _ => '星期日',
    };

IconData _detailIcon(String type) => switch (type) {
      'holiday' ||
      'winter_vacation' ||
      'summer_vacation' =>
        Icons.beach_access_rounded,
      'makeup_teaching' => Icons.swap_horiz_rounded,
      'exam' => Icons.edit_calendar_rounded,
      'registration' => Icons.how_to_reg_rounded,
      'semester_start' => Icons.school_rounded,
      'semester_end' => Icons.flag_rounded,
      _ => Icons.event_note_rounded,
    };

Color _markerColor(String type) => switch (type) {
      'holiday' ||
      'winter_vacation' ||
      'summer_vacation' =>
        const Color(0xFFD9534F),
      'makeup_teaching' => const Color(0xFFE58A2B),
      'exam' => const Color(0xFF8A63C7),
      'registration' => const Color(0xFF3A7BD5),
      'semester_start' => _CalendarPalette.primary,
      'semester_end' => const Color(0xFF5E8E9B),
      _ => const Color(0xFF5B7385),
    };
