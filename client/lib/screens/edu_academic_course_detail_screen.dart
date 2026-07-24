import 'package:flutter/material.dart';
import '../models/edu_academic_situation.dart';

class EduAcademicCourseDetailScreen extends StatelessWidget {
  final EduAcademicCourse course;

  const EduAcademicCourseDetailScreen({
    super.key,
    required this.course,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程完成情况'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            course.courseName,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${course.displayStatus} · 有效成绩 ${course.displayGrade}',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          const SizedBox(height: 18),
          _section(context, [
            _row('最大成绩', course.maxGrade),
            _row('原成绩', course.grade),
            _row('补考', course.makeupGrade),
            _row('重修', course.retakeGrade),
            _row('绩点', course.gpa?.toStringAsFixed(2)),
          ]),
          const SizedBox(height: 12),
          _section(context, [
            _row('学分', course.credits.toStringAsFixed(1)),
            _row('课程性质', course.courseNature),
            _row('课程类别', course.courseCategory),
            _row('学位课', course.isDegree ? '是' : '否'),
            _row('课程号', course.courseCode.isEmpty ? null : course.courseCode),
          ]),
          const SizedBox(height: 12),
          _section(context, [
            _row('成绩学年', course.academicYear),
            _row('成绩学期', course.semester),
            _row('建议修读学年', course.suggestedYear),
            _row('建议修读学期', course.suggestedSemester),
          ]),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.25),
        ),
      ),
      child: Column(children: children),
    );
  }

  Widget _row(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ),
          Expanded(
            child: Text(
              value ?? '--',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
