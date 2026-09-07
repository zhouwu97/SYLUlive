import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../campus/campus_theme.dart';
import '../../models/course_term.dart';
import '../../providers/edu_provider.dart';
import '../../features/academic/domain/academic_provider.dart';

class CourseImportResult {
  final List<Map<String, dynamic>> courses;
  final String year;
  final int semester;
  final CourseTerm term;

  CourseImportResult({
    required this.courses,
    required this.year,
    required this.semester,
    required this.term,
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
  bool _loadingTerms = false;
  bool _termLoadFailed = false;
  String? _errorMessage;
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

    _selectInitialTerm();
    if (widget.eduProvider.isUsingLocalAcademicSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadProviderTerms());
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

  void _selectInitialTerm() {
    CourseTerm? selected;
    for (final term in _terms) {
      if (term.year == _selectedYear && term.semester == _selectedSemester) {
        selected = term;
        break;
      }
    }
    selected ??= _terms.cast<CourseTerm?>().firstWhere(
          (term) => term?.isCurrent == true,
          orElse: () => _terms.isEmpty ? null : _terms.first,
        );
    if (selected == null) return;
    _selectedYear = selected.year;
    _selectedSemester = selected.semester;
  }

  Future<void> _loadProviderTerms() async {
    if (!mounted || _loadingTerms) return;
    setState(() {
      _loadingTerms = true;
      _termLoadFailed = false;
      _errorMessage = null;
    });
    final result = await widget.eduProvider.getAcademicTerms();
    if (!mounted) return;
    if (result == null ||
        !result.success ||
        result.data == null ||
        result.data!.isEmpty) {
      setState(() {
        _loadingTerms = false;
        _termLoadFailed = true;
        _terms = const <CourseTerm>[];
        _errorMessage = '无法获取学校学期列表，请重试';
      });
      return;
    }
    final mapped = result.data!
        .where((term) => term.providerTermId.trim().isNotEmpty)
        .map(_mapAcademicTerm)
        .toList(growable: false);
    if (mapped.isEmpty) {
      setState(() {
        _loadingTerms = false;
        _termLoadFailed = true;
        _terms = const <CourseTerm>[];
        _errorMessage = '学校学期列表缺少有效标识，请重试';
      });
      return;
    }
    setState(() {
      _terms = mapped;
      _loadingTerms = false;
      _termLoadFailed = false;
      _errorMessage = null;
      _selectInitialTerm();
    });
  }

  CourseTerm _mapAcademicTerm(AcademicTerm term) {
    final providerTermId = term.providerTermId.trim();
    final digest = sha256.convert(utf8.encode(providerTermId)).toString();
    final year = term.localYear?.trim().isNotEmpty == true
        ? term.localYear!.trim()
        : 'provider_${digest.substring(0, 12)}';
    return CourseTerm(
      id: 'provider_$digest',
      year: year,
      semester: term.localSemester ?? 1,
      title: term.displayName.trim().isEmpty
          ? providerTermId
          : term.displayName.trim(),
      providerTermId: providerTermId,
      isCurrent: term.isCurrent,
    );
  }

  Future<void> _fetchCourses() async {
    if (_loadingTerms || _terms.isEmpty) return;
    setState(() {
      _isFetching = true;
      _termLoadFailed = false;
      _errorMessage = null;
    });
    _startStatusTimer();

    try {
      final selectedTerm = _terms.firstWhere(
        (term) =>
            term.year == _selectedYear && term.semester == _selectedSemester,
      );
      final result = await widget.eduProvider.getCourses(
        _selectedYear,
        _selectedSemester,
        providerTermId: selectedTerm.providerTermId,
      );

      if (mounted) {
        if (result != null && result.success && result.data != null) {
          Navigator.of(context).pop(CourseImportResult(
            courses: result.data!,
            year: _selectedYear,
            semester: _selectedSemester,
            term: selectedTerm,
          ));
          return;
        }
        _setError(result?.errorMessage);
      }
    } on TimeoutException {
      _setError('教务响应超时，请稍后重试');
    } catch (_) {
      // 原始异常可能包含学校响应或会话材料，不能直接展示到 UI。
      _setError('获取课表失败，请检查本机教务会话后重试');
    } finally {
      _statusTimer?.cancel();
      if (mounted && _isFetching) {
        setState(() => _isFetching = false);
      }
    }
  }

  void _setError(String? message) {
    if (!mounted) return;
    final normalized = message?.trim();
    setState(() {
      _isFetching = false;
      _termLoadFailed = false;
      _errorMessage = normalized == null || normalized.isEmpty
          ? '获取课表失败，请检查本机教务会话后重试'
          : normalized;
    });
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
                      onTap: _isFetching || _loadingTerms
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
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                  decoration: BoxDecoration(
                    color: CampusTheme.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: CampusTheme.red.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 19,
                          color: CampusTheme.red,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: CampusTheme.red,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isFetching
                            ? null
                            : (_termLoadFailed
                                ? _loadProviderTerms
                                : _fetchCourses),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: _isFetching || _loadingTerms || _terms.isEmpty
                    ? null
                    : _fetchCourses,
                style: ElevatedButton.styleFrom(
                  backgroundColor: CampusTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      CampusTheme.primary.withValues(alpha: 0.8),
                  disabledForegroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _loadingTerms
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('正在获取学校学期…'),
                        ],
                      )
                    : _isFetching
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
                        : Text(
                            _errorMessage == null ? '拉取课表' : '再次拉取课表',
                            style: const TextStyle(
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
