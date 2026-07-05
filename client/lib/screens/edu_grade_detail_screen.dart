import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/edu_grade.dart';
import '../providers/edu_provider.dart';

enum _TagTone { neutral, danger }

/// Full-screen course grade detail page.
///
/// Replaces [GradeDetailSheet] — pushed via [Navigator.push] instead
/// of a bottom sheet.
class EduGradeDetailScreen extends StatefulWidget {
  final EduGrade grade;
  final String year;
  final int semester;

  const EduGradeDetailScreen({
    super.key,
    required this.grade,
    required this.year,
    required this.semester,
  });

  @override
  State<EduGradeDetailScreen> createState() => _EduGradeDetailScreenState();
}

class _EduGradeDetailScreenState extends State<EduGradeDetailScreen> {
  EduGradeDetail? _detail;
  String? _detailError;
  bool _isLoadingDetail = false;

  EduGrade get grade => widget.grade;

  // --- Helper Colors ---
  Color _pageBg(bool isDark) =>
      isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4);
  Color _cardColor(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : Colors.white;
  Color _accentColor(bool isDark) =>
      isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
  Color _dangerColor(bool isDark) =>
      isDark ? const Color(0xFFFF8A80) : const Color(0xFFE54848);
  Color _borderColor(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2EFEA);
  Color _titleColor(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF1F2328);
  Color _subColor(bool isDark) =>
      isDark ? Colors.grey.shade400 : const Color(0xFF747B82);

  BoxDecoration _cardDecoration(bool isDark, {bool softGreen = false}) {
    return BoxDecoration(
      color: isDark ? _cardColor(isDark) : null,
      gradient: !isDark && softGreen
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                Color(0xFFF1FBF7),
              ],
            )
          : (!isDark
              ? const LinearGradient(colors: [Colors.white, Colors.white])
              : null),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _borderColor(isDark)),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
    );
  }

  Color _gradeColor(BuildContext context, EduGrade g) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (g.isPassed == false) return _dangerColor(isDark);
    return _titleColor(isDark);
  }

  Widget _tag(BuildContext context, String label, _TagTone tone) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    late final Color bg;
    late final Color fg;

    switch (tone) {
      case _TagTone.danger:
        bg = isDark ? const Color(0xFF4A2525) : const Color(0xFFFFECEC);
        fg = isDark ? const Color(0xFFFFB4B4) : const Color(0xFFD63C3C);
        break;
      case _TagTone.neutral:
        bg = isDark
            ? _accentColor(isDark).withValues(alpha: 0.12)
            : const Color(0xFFEAF6F3);
        fg = _accentColor(isDark);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    final provider = context.read<EduProvider>();
    final cached = provider.getCachedGradeDetail(
      grade,
      widget.year,
      widget.semester,
    );

    if (cached != null) {
      _detail = cached;
      _detailError = cached.success && cached.components.isNotEmpty
          ? null
          : cached.message;
      _isLoadingDetail = false;
    } else {
      _loadDetail();
    }
  }

  Future<void> _loadDetail({bool forceRefresh = false}) async {
    if (grade.classId.isEmpty) {
      setState(() => _detailError = '缺少教学班信息，暂未获取到成绩构成');
      return;
    }

    setState(() {
      _isLoadingDetail = true;
      _detailError = null;
    });

    final provider = context.read<EduProvider>();
    final result = await provider.fetchGradeDetail(
      grade,
      widget.year,
      widget.semester,
      forceRefresh: forceRefresh,
    );

    if (!mounted) return;
    setState(() {
      _isLoadingDetail = false;
      if (result.success && result.data != null) {
        _detail = result.data;
        if (!result.data!.success || result.data!.components.isEmpty) {
          _detailError = result.data!.message ?? '暂未获取到成绩构成';
        }
      } else {
        _detailError = result.errorMessage ?? '暂未获取到成绩构成';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = _pageBg(isDark);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          grade.name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          _buildScoreHero(context, isDark),
          const SizedBox(height: 14),
          _buildGradeComponentsCard(context, isDark),
          const SizedBox(height: 14),
          _buildCourseInfoPanel(context, isDark),
        ],
      ),
    );
  }

  Widget _buildComponents(BuildContext context, bool isDark) {
    if (_isLoadingDetail) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _accentColor(isDark),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在获取成绩构成',
              style: TextStyle(fontSize: 13, color: _subColor(isDark)),
            ),
          ],
        ),
      );
    }

    final components = _detail?.components ?? const <GradeComponent>[];
    if (components.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : const Color(0xFFF1FBF7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: _subColor(isDark)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _detailError ?? '暂未获取到成绩构成',
                style: TextStyle(fontSize: 13, color: _subColor(isDark)),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _componentHeader(context),
        const SizedBox(height: 2),
        for (final component in components) _componentRow(context, component),
      ],
    );
  }

  Widget _componentHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('项目',
                style: TextStyle(fontSize: 12, color: _subColor(isDark))),
          ),
          Expanded(
            flex: 2,
            child: Text('占比', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: _subColor(isDark))),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '得分',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: _subColor(isDark)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _componentRow(BuildContext context, GradeComponent component) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isTotal = component.name.contains('总');

    final scoreValue = double.tryParse(component.score.trim());
    final isFailing = scoreValue != null && scoreValue < 60;

    return Container(
      padding: EdgeInsets.symmetric(
        vertical: isTotal ? 10 : 9,
        horizontal: isTotal ? 10 : 0,
      ),
      margin: EdgeInsets.only(top: isTotal ? 6 : 0),
      decoration: isTotal
          ? BoxDecoration(
              color: isDark
                  ? _accentColor(isDark).withValues(alpha: 0.12)
                  : const Color(0xFFEAF6F3),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  component.name,
                  style: TextStyle(
                    fontSize: isTotal ? 15 : 14,
                    fontWeight: isTotal ? FontWeight.w700 : FontWeight.w500,
                    color: _titleColor(isDark),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  component.weight ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isTotal ? Colors.transparent : _subColor(isDark),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: (() {
                  final estimatedScore =
                      isTotal ? _estimatedWeightedScore() : null;
                  if (isTotal &&
                      estimatedScore != null &&
                      !_isNumericText(component.score)) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '官方 ${component.score}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isFailing
                                ? _dangerColor(isDark)
                                : _accentColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '估算 ${_formatDouble(estimatedScore)}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: isFailing
                                ? _dangerColor(isDark)
                                : _accentColor(isDark),
                          ),
                        ),
                      ],
                    );
                  } else {
                    return Text(
                      component.score,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: isTotal ? 16 : 14,
                        fontWeight: isTotal ? FontWeight.w800 : FontWeight.w600,
                        color: isTotal
                            ? (isFailing
                                ? _dangerColor(isDark)
                                : _accentColor(isDark))
                            : _titleColor(isDark),
                      ),
                    );
                  }
                })(),
              ),
            ],
          ),
          if (!isTotal) _weightBar(context, component, isDark),
        ],
      ),
    );
  }

  Widget _weightBar(
      BuildContext context, GradeComponent component, bool isDark) {
    final weight = _parseWeightPercent(component.weight);
    if (weight == null) return const SizedBox.shrink();

    final scoreValue = double.tryParse(component.score.trim());
    final isFailing = scoreValue != null && scoreValue < 60;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: weight / 100,
          minHeight: 5,
          backgroundColor: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : const Color(0xFFE9F1EF),
          valueColor: AlwaysStoppedAnimation<Color>(
            isFailing
                ? _dangerColor(isDark).withValues(alpha: 0.55)
                : _accentColor(isDark).withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }

  Widget _buildScoreHero(BuildContext context, bool isDark) {
    final estimatedScore = _estimatedWeightedScore();
    final isDisplayGradeNumeric = _isNumericText(grade.displayGrade);

    final subtitleItems = <String>[
      if (grade.teacher != null) grade.teacher!,
      if (grade.credits > 0) '${_formatDouble(grade.credits)} 学分',
      if (grade.gpa != null) '绩点 ${grade.gpa!.toStringAsFixed(2)}',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: _cardDecoration(isDark, softGreen: grade.isPassed != false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            grade.name,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: _titleColor(isDark),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  grade.displayGrade,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isDisplayGradeNumeric ? 52 : 50,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: _gradeColor(context, grade),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: estimatedScore != null && !isDisplayGradeNumeric
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '估算 ${_formatDouble(estimatedScore)}',
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              color: _accentColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '官方总评',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1,
                              color: _subColor(isDark),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        '总评',
                        style: TextStyle(
                          fontSize: 13,
                          color: _subColor(isDark),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
            ],
          ),
          if (subtitleItems.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              subtitleItems.join(' · '),
              style: TextStyle(
                fontSize: 13,
                color: _subColor(isDark),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _tag(
                  context,
                  grade.isDegree ? '学位课' : '非学位课',
                  _TagTone.neutral),
              if (grade.examType != null)
                _tag(context, grade.examType!, _TagTone.neutral),
              if (grade.assessmentMethod != null)
                _tag(context, grade.assessmentMethod!, _TagTone.neutral),
              if (grade.isPassed == false)
                _tag(context, '未通过', _TagTone.danger),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGradeComponentsCard(BuildContext context, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: _cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '成绩构成',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: _titleColor(isDark),
                  ),
                ),
              ),
              Material(
                color: _accentColor(isDark)
                    .withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => _loadDetail(forceRefresh: true),
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(Icons.refresh_rounded,
                        size: 18, color: _accentColor(isDark)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildComponents(context, isDark),
        ],
      ),
    );
  }

  Widget _buildCourseInfoPanel(BuildContext context, bool isDark) {
    final rows = <Widget>[
      if (grade.teacher != null) _infoRow(context, '任课教师', grade.teacher!),
      _infoRow(context, '总成绩', grade.displayGrade),
      if (grade.fraction != null)
        _infoRow(context, '百分成绩', _formatDouble(grade.fraction!)),
      if (grade.gpa != null)
        _infoRow(context, '绩点', grade.gpa!.toStringAsFixed(2)),
      _infoRow(context, '学分', _formatDouble(grade.credits)),
      if (grade.gradePoints != null)
        _infoRow(context, '学分绩点', grade.gradePoints!.toStringAsFixed(2)),
      _infoRow(context, '课程类型', grade.isDegree ? '学位课' : '非学位课'),
      if (grade.courseCategory != null)
        _infoRow(context, '开课类别', grade.courseCategory!),
      if (grade.examType != null) _infoRow(context, '考试性质', grade.examType!),
      if (grade.assessmentMethod != null)
        _infoRow(context, '考核方式', grade.assessmentMethod!),
    ];

    return Container(
      decoration: _cardDecoration(isDark),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          iconColor: _accentColor(isDark),
          collapsedIconColor: _accentColor(isDark),
          title: Text(
            '课程信息',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _titleColor(isDark),
            ),
          ),
          subtitle: Text(
            [
              if (grade.teacher != null) grade.teacher!,
              if (grade.gpa != null) '绩点 ${grade.gpa!.toStringAsFixed(2)}',
              '${_formatDouble(grade.credits)} 学分',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: _subColor(isDark)),
          ),
          children: rows,
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 14, color: _subColor(isDark)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _titleColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDouble(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  double? _estimatedWeightedScore() {
    final components = _detail?.components ?? const <GradeComponent>[];
    if (components.isEmpty) return null;

    double total = 0;
    double weightSum = 0;

    for (final component in components) {
      if (component.name.contains('总')) continue;

      final weight = _parseWeightPercent(component.weight);
      final score = double.tryParse(component.score.trim());

      if (weight == null || score == null) continue;

      total += score * weight / 100;
      weightSum += weight;
    }

    if (weightSum < 99.5 || weightSum > 100.5) {
      return null;
    }

    return total;
  }

  double? _parseWeightPercent(String? value) {
    if (value == null) return null;

    final text = value.trim().replaceAll('%', '');
    if (text.isEmpty) return null;

    final parsed = double.tryParse(text);
    if (parsed == null || parsed <= 0 || parsed > 100) return null;

    return parsed;
  }

  bool _isNumericText(String value) {
    return double.tryParse(value.trim()) != null;
  }
}
