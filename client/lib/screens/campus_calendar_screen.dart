import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/campus_calendar.dart';
import '../providers/campus_calendar_provider.dart';

class CampusCalendarScreen extends StatefulWidget {
  const CampusCalendarScreen({super.key});

  @override
  State<CampusCalendarScreen> createState() => _CampusCalendarScreenState();
}

class _CampusCalendarScreenState extends State<CampusCalendarScreen> {
  DateTime _displayMonth = _monthStart(DateTime.now());
  DateTime _selectedDate = dateOnly(DateTime.now());

  void _showToday() {
    final today = dateOnly(DateTime.now());
    setState(() {
      _selectedDate = today;
      _displayMonth = _monthStart(today);
    });
  }

  void _changeMonth(int delta) {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + delta);
    });
  }

  void _selectDate(DateTime date) =>
      setState(() => _selectedDate = dateOnly(date));

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<CampusCalendarProvider>();
    final calendar = provider.calendar;
    final background =
        isDark ? const Color(0xFF111315) : const Color(0xFFFAF8F4);

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
        foregroundColor: isDark ? Colors.white : const Color(0xFF20212B),
        actions: [
          TextButton(
            onPressed: _showToday,
            child: const Text('今天'),
          ),
          PopupMenuButton<_CalendarMenuAction>(
            tooltip: '更多操作',
            onSelected: (action) {
              if (action == _CalendarMenuAction.sourceImage) {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _OfficialCalendarSourceScreen(),
                  ),
                );
              } else if (calendar != null) {
                _showImportantEvents(calendar);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _CalendarMenuAction.importantEvents,
                child: Text('本学期重要日程'),
              ),
              PopupMenuItem(
                value: _CalendarMenuAction.sourceImage,
                child: Text('查看官方原图'),
              ),
            ],
          ),
        ],
      ),
      body: calendar == null
          ? _CalendarLoading(isDark: isDark, error: provider.error)
          : _buildCalendar(calendar, isDark),
    );
  }

  Widget _buildCalendar(CampusCalendar calendar, bool isDark) {
    final selectedInfo = calendar.dayInfo(_selectedDate);
    final currentInfo = calendar.dayInfo(DateTime.now());
    final semester = selectedInfo.semester ?? currentInfo.semester;

    return SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _AcademicYearHeader(
            calendar: calendar,
            semester: semester,
            currentInfo: currentInfo,
            isDark: isDark,
            onSemesterTap: () => _selectSemester(calendar),
          ),
          const SizedBox(height: 16),
          _MonthNavigator(
            month: _displayMonth,
            onPrevious: () => _changeMonth(-1),
            onNext: () => _changeMonth(1),
          ),
          const SizedBox(height: 12),
          _CalendarMonthGrid(
            month: _displayMonth,
            selectedDate: _selectedDate,
            calendar: calendar,
            isDark: isDark,
            onSelect: _selectDate,
          ),
          const SizedBox(height: 16),
          _DayDetailCard(info: selectedInfo, isDark: isDark),
        ],
      ),
    );
  }

  void _showImportantEvents(CampusCalendar calendar) {
    final now = dateOnly(DateTime.now());
    final events = [...calendar.events]
      ..sort((left, right) => left.startDate.compareTo(right.startDate));

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              const Text(
                '重要日程',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              for (final event in events)
                _ImportantEventTile(
                    event: event, isPast: event.endDate.isBefore(now)),
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
                child: Text('切换学期',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
                    setState(() {
                      _selectedDate = semester.startDate;
                      _displayMonth = _monthStart(semester.startDate);
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CalendarMenuAction { importantEvents, sourceImage }

class _AcademicYearHeader extends StatelessWidget {
  const _AcademicYearHeader({
    required this.calendar,
    required this.semester,
    required this.currentInfo,
    required this.isDark,
    required this.onSemesterTap,
  });

  final CampusCalendar calendar;
  final CampusSemester? semester;
  final CampusDayInfo currentInfo;
  final bool isDark;
  final VoidCallback onSemesterTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final weekLabel = currentInfo.teachingWeek == null
        ? '非教学周'
        : '第 ${currentInfo.teachingWeek!.week} 教学周';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1D2225) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE3E7E5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${calendar.academicYear}学年',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: onSemesterTap,
                icon: const Icon(Icons.unfold_more_rounded, size: 16),
                label: Text(semester?.name ?? '假期'),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '$weekLabel · ${_weekdayLabel(DateTime.now())}',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthNavigator extends StatelessWidget {
  const _MonthNavigator({
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Tooltip(
          message: '上个月',
          child: IconButton(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              DateFormat('yyyy年M月').format(month),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        Tooltip(
          message: '下个月',
          child: IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ),
      ],
    );
  }
}

class _CalendarMonthGrid extends StatelessWidget {
  const _CalendarMonthGrid({
    required this.month,
    required this.selectedDate,
    required this.calendar,
    required this.isDark,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selectedDate;
  final CampusCalendar calendar;
  final bool isDark;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final firstVisible = month.subtract(Duration(days: month.weekday - 1));
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final trailingDays = (7 - monthEnd.weekday) % 7;
    final count = monthEnd.day + (month.weekday - 1) + trailingDays;
    final rows = (count / 7).ceil();

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1D2225) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE3E7E5),
        ),
      ),
      child: Column(
        children: [
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
          const SizedBox(height: 4),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows * 7,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.82,
            ),
            itemBuilder: (context, index) {
              final date = firstVisible.add(Duration(days: index));
              return _CalendarDayCell(
                date: date,
                inCurrentMonth: date.month == month.month,
                selected: sameDay(date, selectedDate),
                today: sameDay(date, DateTime.now()),
                info: calendar.dayInfo(date),
                isDark: isDark,
                onTap: () => onSelect(date),
              );
            },
          ),
        ],
      ),
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
              fontWeight: FontWeight.w600,
              color: isWeekend ? const Color(0xFFE06A5F) : Colors.grey,
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
    required this.isDark,
    required this.onTap,
  });

  final DateTime date;
  final bool inCurrentMonth;
  final bool selected;
  final bool today;
  final CampusDayInfo info;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final markers = info.markers;
    final weekend = date.weekday >= DateTime.saturday;
    final textColor = !inCurrentMonth
        ? (isDark ? Colors.white24 : Colors.black26)
        : selected
            ? Colors.white
            : weekend
                ? const Color(0xFFD8635A)
                : (isDark ? Colors.white : const Color(0xFF252A2D));
    final background = selected
        ? primary
        : today
            ? primary.withValues(alpha: isDark ? 0.2 : 0.1)
            : Colors.transparent;

    return Semantics(
      button: true,
      label: '${date.month}月${date.day}日',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          margin: const EdgeInsets.all(2),
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
            border: today && !selected
                ? Border.all(color: primary, width: 1.2)
                : null,
          ),
          child: Column(
            children: [
              Text(
                '${date.day}',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 18,
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
    final visible = markers.take(2).toList(growable: false);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final marker in visible) ...[
            _MarkerBadge(marker: marker, selected: selected),
            const SizedBox(width: 1),
          ],
          if (markers.length > 2)
            Text(
              '+${markers.length - 2}',
              style: TextStyle(
                fontSize: 9,
                color: selected ? Colors.white : Colors.grey,
              ),
            ),
        ],
      ),
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
      height: 15,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.23)
            : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      child: Text(
        marker.badge,
        style: TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : color,
        ),
      ),
    );
  }
}

class _DayDetailCard extends StatelessWidget {
  const _DayDetailCard({required this.info, required this.isDark});

  final CampusDayInfo info;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? Colors.white60 : Colors.black54;
    final status = info.override != null
        ? info.override!.title
        : info.events.isNotEmpty
            ? info.events.first.title
            : info.isTeachingDay
                ? '正常教学'
                : info.isWeekend
                    ? '周末'
                    : '非教学周';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1D2225) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isDark ? Colors.white12 : const Color(0xFFE3E7E5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${DateFormat('M月d日').format(info.date)} ${_weekdayLabel(info.date)}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            info.teachingWeek == null
                ? (info.semester == null ? '寒暑假或非当前校历范围' : '非教学周')
                : '第 ${info.teachingWeek!.week} 教学周',
            style: TextStyle(fontSize: 14, color: muted),
          ),
          const SizedBox(height: 14),
          _DetailLine(title: status, description: _primaryDescription(info)),
          for (final event in info.events.skip(info.override == null ? 1 : 0))
            _DetailLine(title: event.title, description: event.description),
        ],
      ),
    );
  }

  String _primaryDescription(CampusDayInfo info) {
    if (info.override != null) return info.override!.description;
    if (info.events.isNotEmpty) return info.events.first.description;
    if (info.isTeachingDay) return '按正常课程安排上课。';
    if (info.isWeekend) return '非学校明确放假日，不显示法定假期标记。';
    return '';
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 18,
              margin: const EdgeInsets.only(top: 2, right: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(description,
                        style: TextStyle(
                            fontSize: 13, color: Theme.of(context).hintColor)),
                  ],
                ],
              ),
            ),
          ],
        ),
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
              borderRadius: BorderRadius.circular(6)),
          child: Text(event.badge,
              style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ),
        title: Text(event.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${DateFormat('M月d日').format(event.startDate)}${sameDay(event.startDate, event.endDate) ? '' : ' - ${DateFormat('M月d日').format(event.endDate)}'}',
        ),
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
              const CircularProgressIndicator()
            else
              const Icon(Icons.calendar_month_outlined, size: 40),
            const SizedBox(height: 12),
            Text(error ?? '正在读取校历',
                style:
                    TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
          ],
        ),
      );
}

class _OfficialCalendarSourceScreen extends StatelessWidget {
  const _OfficialCalendarSourceScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('官方校历原图')),
        body: InteractiveViewer(
          minScale: 0.7,
          maxScale: 4,
          child: Center(
            child: Image.asset('assets/images/xiaoli.jpg', fit: BoxFit.contain),
          ),
        ),
      );
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

Color _markerColor(String type) => switch (type) {
      'holiday' ||
      'winter_vacation' ||
      'summer_vacation' =>
        const Color(0xFFD9534F),
      'makeup_teaching' => const Color(0xFFE58A2B),
      'exam' => const Color(0xFF8A63C7),
      'registration' => const Color(0xFF3A7BD5),
      'semester_start' => const Color(0xFF3A9D6C),
      'semester_end' => const Color(0xFF168C9A),
      _ => const Color(0xFF5B7385),
    };
