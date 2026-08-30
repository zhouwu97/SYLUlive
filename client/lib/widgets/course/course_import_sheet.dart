import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../campus/campus_theme.dart';
import '../../models/course_term.dart';
import '../../providers/edu_provider.dart';

class CourseImportResult {
  final List<Map<String, dynamic>> courses;
  final String year;
  final int semester;

  CourseImportResult({
    required this.courses,
    required this.year,
    required this.semester,
  });
}

class CourseImportSheet extends StatefulWidget {
  final EduProvider eduProvider;
  final String? initialYear;
  final int? initialSemester;

  const CourseImportSheet({
    super.key,
    required this.eduProvider,
    this.initialYear,
    this.initialSemester,
  });

  @override
  State<CourseImportSheet> createState() => _CourseImportSheetState();

  static Future<CourseImportResult?> show(
    BuildContext context, {
    required EduProvider eduProvider,
    String? initialYear,
    int? initialSemester,
  }) {
    return showModalBottomSheet<CourseImportResult>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => CourseImportSheet(
        eduProvider: eduProvider,
        initialYear: initialYear,
        initialSemester: initialSemester,
      ),
    );
  }
}

class _CourseImportSheetState extends State<CourseImportSheet> {
  late List<CourseTerm> _terms;
  late String _selectedYear;
  late int _selectedSemester;
  bool _isFetching = false;
  String _statusText = '正在连接教务系统…';
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _terms = CourseTermCatalog.generate(
        enrollmentYear: widget.eduProvider.enrollmentYear);

    // 默认选择当前推断学期或传入学期
    final currentTerm = CourseTerm.inferCurrentTerm();
    _selectedYear = widget.initialYear ?? currentTerm.year;
    _selectedSemester = widget.initialSemester ?? currentTerm.semester;

    // 如果生成的列表中不包含推断出的学期，则默认选中第一项
    if (!_terms.any(
        (t) => t.year == _selectedYear && t.semester == _selectedSemester)) {
      if (_terms.isNotEmpty) {
        _selectedYear = _terms.first.year;
        _selectedSemester = _terms.first.semester;
      }
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    int seconds = 0;
    _statusText = '正在连接教务系统…';
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      seconds++;
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (seconds == 3) {
        setState(() {
          _statusText = '教务系统响应较慢，正在抓取中…';
        });
      } else if (seconds == 7) {
        setState(() {
          _statusText = '正在校验会话状态与解析课表…';
        });
      } else if (seconds == 15) {
        setState(() {
          _statusText = '教务系统处理中，请稍候…';
        });
      }
    });
  }

  Future<void> _fetchCourses() async {
    setState(() {
      _isFetching = true;
    });
    _startStatusTimer();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navContext = context;

    try {
      final result = await widget.eduProvider
          .getCourses(_selectedYear, _selectedSemester);

      _statusTimer?.cancel();

      if (mounted) {
        if (result != null && result.success && result.data != null) {
          Navigator.pop(
              navContext,
              CourseImportResult(
                courses: result.data!,
                year: _selectedYear,
                semester: _selectedSemester,
              ));
          return;
        } else {
          Navigator.pop(navContext); // 关闭当前Sheet
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                result?.errorMessage ?? '获取课表失败，请稍后重试或重新绑定教务账号',
              ),
              backgroundColor: CampusTheme.red,
            ),
          );
        }
      }
    } on TimeoutException {
      _statusTimer?.cancel();
      if (mounted) {
        Navigator.pop(navContext);
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('教务响应超时，请稍后重试'),
            backgroundColor: CampusTheme.red,
          ),
        );
      }
    } catch (e) {
      _statusTimer?.cancel();
      if (mounted) {
        Navigator.pop(navContext);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('获取课表异常：$e'),
            backgroundColor: CampusTheme.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '选择拉取学期',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : CampusTheme.text,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '拉取当前展示学期会刷新当前页，拉取其他学期会自动切换到对应学期',
                      style: TextStyle(
                        fontSize: 14,
                        color: CampusTheme.subText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _terms.length,
                itemBuilder: (context, index) {
                  final term = _terms[index];
                  final isSelected = term.year == _selectedYear &&
                      term.semester == _selectedSemester;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? CampusTheme.primary.withValues(alpha: 0.1)
                          : (isDark ? CampusTheme.darkCard : Colors.white),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? CampusTheme.primary.withValues(alpha: 0.3)
                            : Colors.transparent,
                      ),
                    ),
                    child: ListTile(
                      onTap: _isFetching
                          ? null
                          : () {
                              setState(() {
                                _selectedYear = term.year;
                                _selectedSemester = term.semester;
                              });
                            },
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      title: Text(
                        term.title,
                        style: TextStyle(
                          color: isSelected
                              ? CampusTheme.primary
                              : (isDark ? Colors.white : CampusTheme.text),
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle_rounded,
                              color: CampusTheme.primary)
                          : null,
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: _isFetching ? null : _fetchCourses,
                style: ElevatedButton.styleFrom(
                  backgroundColor: CampusTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: CampusTheme.primary.withValues(alpha: 0.8),
                  disabledForegroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isFetching
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _statusText,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        '拉取课表',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
