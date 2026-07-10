import 'package:flutter/material.dart';
import '../../models/course_term.dart';

class CourseSemesterStartSheet extends StatefulWidget {
  final CourseTerm term;
  final DateTime? initialMonday;

  const CourseSemesterStartSheet({
    super.key,
    required this.term,
    this.initialMonday,
  });

  @override
  State<CourseSemesterStartSheet> createState() =>
      _CourseSemesterStartSheetState();
}

class _CourseSemesterStartSheetState extends State<CourseSemesterStartSheet> {
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
      _baseMonth = DateTime(
        widget.initialMonday!.year,
        widget.initialMonday!.month,
        1,
      );
    } else {
      int year = int.tryParse(widget.term.year) ?? DateTime.now().year;
      if (widget.term.semester == 3) {
        _baseMonth = DateTime(year, 8, 1);
      } else {
        _baseMonth = DateTime(year + 1, 2, 1);
      }
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

  DateTime _monthForPage(int page) {
    int diff = page - 6;
    return DateTime(_baseMonth.year, _baseMonth.month + diff, 1);
  }

  String _formatDate(DateTime d) => '${d.month}月${d.day}日';
  String _formatMonth(DateTime d) => '${d.year}年${d.month}月';

  void _toggleYearMonthPicker() {
    setState(() {
      if (!_pickingYearMonth) {
        _pickerYear = _monthForPage(_currentPage).year;
      }
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

  Widget _buildInlineYearMonthPicker() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final currentMonth = _monthForPage(_currentPage).month;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // 年份行
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _pickerYear--),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$_pickerYear 年',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _pickerYear++),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 月份网格
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              childAspectRatio: 1.8,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: 12,
            itemBuilder: (ctx, index) {
              final month = index + 1;
              final isSelected = _pickerYear == _monthForPage(_currentPage).year && month == currentMonth;
              return GestureDetector(
                onTap: () => _jumpToMonth(month),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? primaryColor
                        : (isDark ? Colors.white.withOpacity(0.06) : Colors.grey[100]),
                    borderRadius: BorderRadius.circular(12),
                    border: isSelected
                        ? null
                        : Border.all(
                            color: isDark
                                ? Colors.white.withOpacity(0.1)
                                : Colors.grey.withOpacity(0.15),
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$month月',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected
                          ? Colors.white
                          : (isDark ? Colors.white70 : Colors.black87),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: _currentPage > 0
              ? () {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              : null,
        ),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _toggleYearMonthPicker,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatMonth(_monthForPage(_currentPage)),
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
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: _currentPage < 12
              ? () {
                  _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              : null,
        ),
      ],
    );
  }

  Widget _buildWeekdaysHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: ['一', '二', '三', '四', '五', '六', '日'].map((day) {
          return SizedBox(
            width: 32,
            child: Text(
              day,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMonthCalendar(DateTime monthDate) {
    DateTime firstDayOfMonth = DateTime(monthDate.year, monthDate.month, 1);
    DateTime firstMonday =
        firstDayOfMonth.subtract(Duration(days: firstDayOfMonth.weekday - 1));

    List<Widget> weekRows = [];
    for (int i = 0; i < 6; i++) {
      DateTime weekMonday = firstMonday.add(Duration(days: i * 7));
      bool isSelected = _selectedMonday != null &&
          _selectedMonday!.year == weekMonday.year &&
          _selectedMonday!.month == weekMonday.month &&
          _selectedMonday!.day == weekMonday.day;

      weekRows.add(
        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                _selectedMonday = weekMonday;
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
              decoration: isSelected
                  ? BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5,
                      ),
                    )
                  : BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.transparent, width: 1.5),
                    ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(7, (dayIndex) {
                  DateTime day = weekMonday.add(Duration(days: dayIndex));
                  bool isCurrentMonth = day.month == monthDate.month;
                  return SizedBox(
                    width: 32,
                    child: Center(
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          color: isCurrentMonth
                              ? (isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : (Theme.of(context).brightness == Brightness.dark
                                      ? Colors.white
                                      : Colors.black87))
                              : Colors.grey.withOpacity(0.5),
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      );
    }

    return Column(children: weekRows);
  }

  Widget _buildBottomArea() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, -4),
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedMonday != null) ...[
            const Text('已选择', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              '第1周 · ${_formatDate(_selectedMonday!)}—${_formatDate(_selectedMonday!.add(const Duration(days: 6)))}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              '周一 ${_formatDate(_selectedMonday!)}作为开学日期',
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 13),
            ),
          ] else ...[
            const Text('尚未选择', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('--', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                        borderRadius: BorderRadius.circular(12)),
                  ),
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
                    backgroundColor: Theme.of(context).colorScheme.primary,
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[50],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          // Titles
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设置开学第一周',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.term.title,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '第一周将按周一至周日计算',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _buildMonthSelector(),
          if (_pickingYearMonth)
            Expanded(child: _buildInlineYearMonthPicker())
          else ...[
            _buildWeekdaysHeader(),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (idx) {
                  setState(() {
                    _currentPage = idx;
                  });
                },
                itemCount: 13,
                itemBuilder: (context, index) {
                  return _buildMonthCalendar(_monthForPage(index));
                },
              ),
            ),
          ],
          _buildBottomArea(),
        ],
      ),
    );
  }
}
