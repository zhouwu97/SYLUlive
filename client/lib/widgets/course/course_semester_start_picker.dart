import 'package:flutter/material.dart';
import '../../models/course_term.dart';
import '../campus/campus_theme.dart';

/// A bottom-sheet week picker for setting the semester start date.
///
/// Each row represents Mon–Sun. Tapping any day in a row selects that entire
/// week; the returned value is always the Monday of the selected week.
class CourseSemesterStartPicker {
  static Future<DateTime?> show(
    BuildContext context, {
    required CourseTerm term,
    DateTime? initialMonday,
  }) {
    final pickerTheme = CampusTheme.withBrandAccent(Theme.of(context));
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Theme(
        data: pickerTheme,
        child: _PickerContent(
          term: term,
          initialMonday: initialMonday,
        ),
      ),
    );
  }
}

class _PickerContent extends StatefulWidget {
  final CourseTerm term;
  final DateTime? initialMonday;

  const _PickerContent({required this.term, this.initialMonday});

  @override
  State<_PickerContent> createState() => _PickerContentState();
}

class _PickerContentState extends State<_PickerContent> {
  late PageController _pageController;
  late DateTime _baseMonth;
  late int _currentPage;
  DateTime? _selectedMonday;
  bool _pickingYearMonth = false;
  late int _pickerYear;

  @override
  void initState() {
    super.initState();
    _selectedMonday = widget.initialMonday;
    if (widget.initialMonday != null) {
      _baseMonth =
          DateTime(widget.initialMonday!.year, widget.initialMonday!.month, 1);
    } else {
      final y = int.tryParse(widget.term.year) ?? DateTime.now().year;
      _baseMonth =
          widget.term.semester == 3 ? DateTime(y, 8, 1) : DateTime(y + 1, 2, 1);
    }
    _currentPage = 6;
    _pageController = PageController(initialPage: _currentPage);
    _pickerYear = _baseMonth.year;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  DateTime _monthForPage(int page) {
    final diff = page - 6;
    final y = _baseMonth.year;
    final m = _baseMonth.month + diff;
    if (m > 12) return DateTime(y + (m - 1) ~/ 12, (m - 1) % 12 + 1, 1);
    if (m < 1) return DateTime(y + (m - 12) ~/ 12, (m - 1) % 12 + 1, 1);
    return DateTime(y, m, 1);
  }

  String _fmt(DateTime d) => '${d.month}月${d.day}日';

  String _fmtMonthLabel(DateTime m) => '${m.year}年${m.month}月';

  Color? _primary(BuildContext c) => Theme.of(c).colorScheme.primary;

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _prevMonth() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextMonth() {
    if (_currentPage < 12) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _toggleYearMonthPicker() {
    setState(() {
      if (!_pickingYearMonth) _pickerYear = _monthForPage(_currentPage).year;
      _pickingYearMonth = !_pickingYearMonth;
    });
  }

  void _jumpToMonth(int month) {
    setState(() {
      _baseMonth = DateTime(_pickerYear, month, 1);
      _currentPage = 6;
      _pickingYearMonth = false;
    });
    _pageController.jumpToPage(6);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final height = MediaQuery.of(context).size.height * 0.75;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : CampusTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          // Title
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '设置开学第一周',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              widget.term.title,
              style: TextStyle(color: CampusTheme.subText, fontSize: 14),
            ),
          ),
          const SizedBox(height: 6),
          // Month selector
          _buildMonthSelector(),
          if (_pickingYearMonth)
            Expanded(child: _buildYearMonthPicker())
          else ...[
            _buildWeekdayHeader(),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemCount: 13,
                itemBuilder: (_, i) => _buildCalendarMonth(_monthForPage(i)),
              ),
            ),
          ],
          _buildBottomArea(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Month selector (← year·month →)
  // ---------------------------------------------------------------------------

  Widget _buildMonthSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: _prevMonth),
        TextButton(
          onPressed: _toggleYearMonthPicker,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fmtMonthLabel(_monthForPage(_currentPage)),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _pickingYearMonth ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        IconButton(
            icon: const Icon(Icons.chevron_right), onPressed: _nextMonth),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Inline year → month quick-pick
  // ---------------------------------------------------------------------------

  Widget _buildYearMonthPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Year row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _pickerYear--),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: _primary(context)!.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$_pickerYear 年',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _primary(context))),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _pickerYear++),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Month grid
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 1.8,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: 12,
              itemBuilder: (_, i) {
                final m = i + 1;
                final curMonth = _monthForPage(_currentPage);
                final sel = _pickerYear == curMonth.year && m == curMonth.month;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                return GestureDetector(
                  onTap: () => _jumpToMonth(m),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: sel
                          ? _primary(context)
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.grey[100]),
                      borderRadius: BorderRadius.circular(12),
                      border: sel
                          ? null
                          : Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Colors.grey.withValues(alpha: 0.15)),
                    ),
                    alignment: Alignment.center,
                    child: Text('$m月',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
                            color: sel
                                ? Colors.white
                                : (isDark ? Colors.white70 : Colors.black87))),
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
  // Weekday header
  // ---------------------------------------------------------------------------

  Widget _buildWeekdayHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: ['一', '二', '三', '四', '五', '六', '日'].map((day) {
          return SizedBox(
            width: 32,
            child: Text(day,
                textAlign: TextAlign.center,
                style: TextStyle(color: CampusTheme.subText, fontSize: 13)),
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Calendar — one month of week-rows
  // ---------------------------------------------------------------------------

  Widget _buildCalendarMonth(DateTime monthDate) {
    final firstDay = DateTime(monthDate.year, monthDate.month, 1);
    final firstMonday = firstDay.subtract(Duration(days: firstDay.weekday - 1));

    return Column(
      children: List.generate(6, (i) {
        final weekMonday = firstMonday.add(Duration(days: i * 7));
        final isSelected = _selectedMonday != null &&
            _selectedMonday!.year == weekMonday.year &&
            _selectedMonday!.month == weekMonday.month &&
            _selectedMonday!.day == weekMonday.day;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final primary = _primary(context)!;

        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _selectedMonday = weekMonday),
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? primary.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(7, (di) {
                  final day = weekMonday.add(Duration(days: di));
                  final inMonth = day.month == monthDate.month;
                  final isMon = di == 0;

                  // Solid dot for the selected Monday
                  Widget child;
                  if (isMon && isSelected) {
                    child = Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text('${day.day}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                    );
                  } else {
                    child = Text('${day.day}',
                        style: TextStyle(
                            color: inMonth
                                ? (isSelected
                                    ? primary
                                    : (isDark ? Colors.white : Colors.black87))
                                : Colors.grey.withValues(alpha: 0.45),
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontSize: 14));
                  }

                  return SizedBox(width: 32, child: Center(child: child));
                }),
              ),
            ),
          ),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom bar
  // ---------------------------------------------------------------------------

  Widget _buildBottomArea() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = _primary(context)!;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : CampusTheme.card,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, -4))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedMonday != null) ...[
            Text('已选择',
                style: TextStyle(color: CampusTheme.subText, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
                '第1周 · ${_fmt(_selectedMonday!)}—${_fmt(_selectedMonday!.add(const Duration(days: 6)))}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('以${_fmt(_selectedMonday!)}周一作为开学日期',
                style: TextStyle(color: primary, fontSize: 13)),
          ] else ...[
            Text('尚未选择',
                style: TextStyle(color: CampusTheme.subText, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('--',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            const Text('请在上方日历中选择',
                style: TextStyle(color: Colors.transparent, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    elevation: 0,
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _selectedMonday == null
                      ? null
                      : () => Navigator.pop(context, _selectedMonday),
                  child: const Text('保存设置'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
