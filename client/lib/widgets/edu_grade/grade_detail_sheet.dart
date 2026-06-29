import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/edu_grade.dart';
import '../../providers/edu_provider.dart';

/// Bottom sheet showing course grade details.
/// Shows local summary data immediately, then lazily loads grade components.
class GradeDetailSheet extends StatefulWidget {
  final EduGrade grade;
  final String year;
  final int semester;

  const GradeDetailSheet({
    super.key,
    required this.grade,
    required this.year,
    required this.semester,
  });

  static void show(
    BuildContext context,
    EduGrade grade, {
    required String year,
    required int semester,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => GradeDetailSheet(
        grade: grade,
        year: year,
        semester: semester,
      ),
    );
  }

  @override
  State<GradeDetailSheet> createState() => _GradeDetailSheetState();
}

class _GradeDetailSheetState extends State<GradeDetailSheet> {
  EduGradeDetail? _detail;
  String? _detailError;
  bool _isLoadingDetail = false;

  EduGrade get grade => widget.grade;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Text(
              grade.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                grade.displayGrade,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  color: _gradeColor(context, grade),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  _tag(context, grade.isDegree ? '学位课' : '非学位课', isDark),
                  if (grade.examType != null)
                    _tag(context, grade.examType!, isDark),
                  if (grade.assessmentMethod != null)
                    _tag(context, grade.assessmentMethod!, isDark),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            _sectionHeader('课程信息'),
            const SizedBox(height: 8),
            _infoRow(context, '总成绩', grade.displayGrade),
            if (grade.fraction != null)
              _infoRow(context, '百分成绩', _formatDouble(grade.fraction!)),
            if (grade.gpa != null)
              _infoRow(context, '绩点', grade.gpa!.toStringAsFixed(2)),
            _infoRow(context, '学分', grade.credits.toStringAsFixed(1)),
            if (grade.gradePoints != null)
              _infoRow(context, '学分绩点', grade.gradePoints!.toStringAsFixed(2)),
            if (grade.teacher != null)
              _infoRow(context, '任课教师', grade.teacher!),
            _infoRow(context, '课程类型', grade.isDegree ? '学位课' : '非学位课'),
            if (grade.courseCategory != null)
              _infoRow(context, '开课类别', grade.courseCategory!),
            if (grade.examType != null)
              _infoRow(context, '考试性质', grade.examType!),
            if (grade.assessmentMethod != null)
              _infoRow(context, '考核方式', grade.assessmentMethod!),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            _sectionHeader('成绩构成'),
            const SizedBox(height: 8),
            _buildComponents(context, isDark),
          ],
        );
      },
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
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在获取成绩构成',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
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
          color: isDark ? Colors.grey[850] : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _detailError ?? '暂未获取到成绩构成',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
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

  Color _gradeColor(BuildContext context, EduGrade g) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final t = g.displayGrade.trim();
    if (g.isPassed == false) return Colors.red;
    if (t == '优秀') return Colors.green;
    return isDark ? Colors.white : Colors.black87;
  }

  Widget _tag(BuildContext context, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _componentHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('成绩分项',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ),
          Expanded(
            flex: 2,
            child: Text('比例',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '成绩',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _componentRow(BuildContext context, GradeComponent component) {
    final isTotal = component.name.contains('总');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              component.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isTotal ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              component.weight ?? '',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              component.score,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isTotal ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          Text(value, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  String _formatDouble(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
