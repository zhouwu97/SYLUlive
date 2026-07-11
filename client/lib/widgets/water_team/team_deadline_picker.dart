import 'package:flutter/material.dart';

/// A bottom-sheet date picker for team recruitment deadlines.
///
/// Shows a calendar grid with a tappable year-month header — tapping the header
/// switches to a quick-pick view (years → months) for fast navigation, then
/// returns to the calendar for day selection.
class TeamDeadlinePicker {
  static Future<DateTime?> show(
    BuildContext context, {
    required DateTime firstDate,
    required DateTime lastDate,
    required DateTime initialDate,
    Color accentColor = const Color(0xFF12B8A6),
  }) {
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TeamDeadlinePickerContent(
        firstDate: firstDate,
        lastDate: lastDate,
        initialDate: initialDate,
        accentColor: accentColor,
      ),
    );
  }
}

class _TeamDeadlinePickerContent extends StatefulWidget {
  final DateTime firstDate;
  final DateTime lastDate;
  final DateTime initialDate;
  final Color accentColor;

  const _TeamDeadlinePickerContent({
    required this.firstDate,
    required this.lastDate,
    required this.initialDate,
    required this.accentColor,
  });

  @override
  State<_TeamDeadlinePickerContent> createState() =>
      _TeamDeadlinePickerContentState();
}

enum _PickerView { calendar, yearList, monthGrid }

class _TeamDeadlinePickerContentState
    extends State<_TeamDeadlinePickerContent> {
  late int _viewYear;
  late int _viewMonth;
  late int _selectedYear;
  late int _selectedMonth;
  late int _selectedDay;
  _PickerView _view = _PickerView.calendar;
  late PageController _yearPageController;
  late int _yearPageIndex;

  static const int _yearPageCount = 10;

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialDate.year;
    _selectedMonth = widget.initialDate.month;
    _selectedDay = widget.initialDate.day;
    _viewYear = widget.initialDate.year;
    _viewMonth = widget.initialDate.month;

    final startYear = (widget.firstDate.year ~/ _yearPageCount) * _yearPageCount;
    _yearPageIndex = (_viewYear - startYear) ~/ _yearPageCount;
    _yearPageController = PageController(initialPage: _yearPageIndex);
  }

  @override
  void dispose() {
    _yearPageController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Navigation helpers
  // ---------------------------------------------------------------------------

  void _previousMonth() {
    setState(() {
      if (_viewMonth == 1) {
        if (_viewYear > widget.firstDate.year ||
            (_viewYear == widget.firstDate.year &&
                widget.firstDate.month < 12)) {
          _viewYear--;
          _viewMonth = 12;
        }
      } else {
        final newMonth = _viewMonth - 1;
        final dt = DateTime(_viewYear, newMonth);
        if (!dt.isBefore(DateTime(widget.firstDate.year, widget.firstDate.month))) {
          _viewMonth = newMonth;
        }
      }
    });
  }

  void _nextMonth() {
    setState(() {
      if (_viewMonth == 12) {
        if (_viewYear < widget.lastDate.year ||
            (_viewYear == widget.lastDate.year &&
                widget.lastDate.month > 11)) {
          _viewYear++;
          _viewMonth = 1;
        }
      } else {
        final newMonth = _viewMonth + 1;
        final dt = DateTime(_viewYear, newMonth);
        if (!dt.isAfter(DateTime(widget.lastDate.year, widget.lastDate.month))) {
          _viewMonth = newMonth;
        }
      }
    });
  }

  void _goToYearMonth(int year, int month) {
    setState(() {
      _viewYear = year;
      _viewMonth = month;
      _view = _PickerView.calendar;
    });
  }

  bool _isDayEnabled(int year, int month, int day) {
    final dt = DateTime(year, month, day);
    return !dt.isBefore(widget.firstDate) && !dt.isAfter(widget.lastDate);
  }

  void _confirm() {
    final result = DateTime(_selectedYear, _selectedMonth, _selectedDay);
    Navigator.of(context).pop(result);
  }

  // ---------------------------------------------------------------------------
  // Calendar helpers
  // ---------------------------------------------------------------------------

  int _daysInMonth(int year, int month) {
    if (month == 12) {
      return DateTime(year + 1, 1, 0).day;
    }
    return DateTime(year, month + 1, 0).day;
  }

  int _firstWeekday(int year, int month) {
    // Monday = 1 … Sunday = 7
    final wd = DateTime(year, month, 1).weekday; // 1=Mon
    return wd; // Monday=1 is our column 0
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF161B22) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final subColor = isDark ? Colors.white54 : Colors.black54;

    const calendarHeight = 380.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择截止日期',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            // Body
            SizedBox(
              height: calendarHeight,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _buildBody(isDark, textColor, subColor),
              ),
            ),
            // Footer
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, 12 + bottomInset),
              child: Row(
                children: [
                  Text(
                    '已选 $_selectedYear 年 $_selectedMonth 月 $_selectedDay 日',
                    style: TextStyle(fontSize: 13, color: subColor),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _confirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: widget.accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textColor, Color subColor) {
    switch (_view) {
      case _PickerView.calendar:
        return _buildCalendar(isDark, textColor, subColor,
            key: const ValueKey('cal'));
      case _PickerView.yearList:
        return _buildYearList(isDark, textColor, subColor,
            key: const ValueKey('year'));
      case _PickerView.monthGrid:
        return _buildMonthGrid(isDark, textColor, subColor,
            key: const ValueKey('month'));
    }
  }

  // ---------------------------------------------------------------------------
  // Calendar view
  // ---------------------------------------------------------------------------

  Widget _buildCalendar(bool isDark, Color textColor, Color subColor,
      {Key? key}) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final dayCount = _daysInMonth(_viewYear, _viewMonth);
    final firstWd = _firstWeekday(_viewYear, _viewMonth);
    final canPrev = !DateTime(_viewYear, _viewMonth)
        .isBefore(DateTime(widget.firstDate.year, widget.firstDate.month));
    // lastDate is inclusive: user can pick lastDate; month view is ok as long
    // as any day of the target month is <= lastDate.
    final canNext = DateTime(_viewYear, _viewMonth)
        .isBefore(DateTime(widget.lastDate.year, widget.lastDate.month));

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Month navigation header
          Row(
            children: [
              IconButton(
                onPressed: canPrev ? _previousMonth : null,
                icon: Icon(Icons.chevron_left,
                    color: canPrev ? widget.accentColor : Colors.grey),
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _view = _PickerView.yearList),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$_viewYear 年 $_viewMonth 月',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_drop_down,
                            size: 20, color: widget.accentColor),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: canNext ? _nextMonth : null,
                icon: Icon(Icons.chevron_right,
                    color: canNext ? widget.accentColor : Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Weekday labels
          Row(
            children: weekdays.map((wd) {
              final isWeekend = wd == '六' || wd == '日';
              return SizedBox(
                width: (MediaQuery.of(context).size.width - 32) / 7,
                child: Center(
                  child: Text(
                    wd,
                    style: TextStyle(
                      fontSize: 12,
                      color: isWeekend
                          ? widget.accentColor.withValues(alpha: 0.7)
                          : subColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
          // Day cells
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.1,
              ),
              itemCount: firstWd - 1 + dayCount,
              itemBuilder: (context, index) {
                final dayIndex = index - firstWd + 1;
                if (dayIndex < 1) return const SizedBox.shrink();

                final day = dayIndex;
                final enabled = _isDayEnabled(_viewYear, _viewMonth, day);
                final isSelected = _viewYear == _selectedYear &&
                    _viewMonth == _selectedMonth &&
                    day == _selectedDay;
                final isToday = DateTime.now().year == _viewYear &&
                    DateTime.now().month == _viewMonth &&
                    DateTime.now().day == day;

                return GestureDetector(
                  onTap: enabled
                      ? () => setState(() {
                            _selectedYear = _viewYear;
                            _selectedMonth = _viewMonth;
                            _selectedDay = day;
                          })
                      : null,
                  child: Container(
                    margin: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? widget.accentColor
                          : isToday && !isSelected
                              ? widget.accentColor.withValues(alpha: 0.1)
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              isSelected || isToday ? FontWeight.w700 : FontWeight.w400,
                          color: isSelected
                              ? Colors.white
                              : enabled
                                  ? textColor
                                  : (isDark ? Colors.white24 : Colors.grey[300]),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Year list view
  // ---------------------------------------------------------------------------

  Widget _buildYearList(bool isDark, Color textColor, Color subColor,
      {Key? key}) {
    final startYear =
        (widget.firstDate.year ~/ _yearPageCount) * _yearPageCount;
    final endYear = widget.lastDate.year;

    return Column(
      key: key,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const BackButton(),
              Expanded(
                child: Text(
                  '选择年份',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Year pages
        Expanded(
          child: PageView.builder(
            controller: _yearPageController,
            itemCount:
                ((endYear - startYear) ~/ _yearPageCount) + 1,
            onPageChanged: (idx) => setState(() => _yearPageIndex = idx),
            itemBuilder: (context, pageIdx) {
              final pageStart = startYear + pageIdx * _yearPageCount;
              final pageEnd =
                  (pageStart + _yearPageCount - 1).clamp(0, endYear);
              final years = List.generate(
                  pageEnd - pageStart + 1, (i) => pageStart + i);
              return GridView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20),
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  childAspectRatio: 1.6,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: years.length,
                itemBuilder: (context, index) {
                  final y = years[index];
                  final isValid = y >= widget.firstDate.year &&
                      y <= widget.lastDate.year;
                  final isCurrent = _selectedYear == y;
                  return GestureDetector(
                    onTap: isValid
                        ? () => setState(() {
                              _selectedYear = y;
                              _view = _PickerView.monthGrid;
                            })
                        : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? widget.accentColor
                            : widget.accentColor
                                .withValues(alpha: 0.06),
                        borderRadius:
                            BorderRadius.circular(10),
                        border: isCurrent
                            ? null
                            : Border.all(
                                color: widget.accentColor
                                    .withValues(alpha: 0.18)),
                      ),
                      child: Center(
                        child: Text(
                          '$y',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: isCurrent
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isCurrent
                                ? Colors.white
                                : isValid
                                    ? textColor
                                    : (isDark
                                        ? Colors.white24
                                        : Colors.grey[300]),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Month grid view (after year selection)
  // ---------------------------------------------------------------------------

  Widget _buildMonthGrid(bool isDark, Color textColor, Color subColor,
      {Key? key}) {
    final months = List.generate(12, (i) => i + 1);
    final now = DateTime.now();

    return Column(
      key: key,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              BackButton(
                onPressed: () =>
                    setState(() => _view = _PickerView.yearList),
              ),
              Expanded(
                child: Text(
                  '$_selectedYear 年',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Month grid
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 1.6,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: 12,
              itemBuilder: (context, index) {
                final m = months[index];
                final isCurrent = _selectedMonth == m;
                // Check if this year-month is within range
                final ym = DateTime(_selectedYear, m);
                final inRange = !ym.isBefore(DateTime(
                        widget.firstDate.year, widget.firstDate.month)) &&
                    !ym.isAfter(DateTime(
                        widget.lastDate.year, widget.lastDate.month));
                final isThisMonth = now.year == _selectedYear && now.month == m;

                return GestureDetector(
                  onTap: inRange
                      ? () => _goToYearMonth(_selectedYear, m)
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? widget.accentColor
                          : isThisMonth && !isCurrent
                              ? widget.accentColor.withValues(alpha: 0.08)
                              : widget.accentColor.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: isCurrent || isThisMonth
                          ? Border.all(color: widget.accentColor
                              .withValues(alpha: isCurrent ? 1 : 0.25))
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$m 月',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isCurrent ? FontWeight.w700 : FontWeight.w500,
                            color: isCurrent
                                ? Colors.white
                                : inRange
                                    ? textColor
                                    : (isDark
                                        ? Colors.white24
                                        : Colors.grey[300]),
                          ),
                        ),
                        if (isThisMonth)
                          Text(
                            '本月',
                            style: TextStyle(
                              fontSize: 10,
                              color: isCurrent
                                  ? Colors.white70
                                  : widget.accentColor
                                      .withValues(alpha: 0.7),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
