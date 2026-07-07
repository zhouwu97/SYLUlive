import 'package:flutter/material.dart';
import '../../models/edu_academic_situation.dart';
import 'grade_progress_strip.dart';

class GradeGpaHeroCard extends StatelessWidget {
  final EduAcademicSituation? situation;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final bool isDrawerMode;

  const GradeGpaHeroCard({
    super.key,
    required this.situation,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
    this.isDrawerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: isDrawerMode 
          ? const EdgeInsets.symmetric(horizontal: 0) 
          : const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.22),
          ),
        ),
        child: isLoading && situation == null
            ? _buildLoading(context)
            : errorMessage != null && situation == null
                ? _buildError(context)
                : _buildContent(context),
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final base = Theme.of(context).dividerColor.withValues(alpha: 0.18);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(width: 96, height: 14, color: base),
        const SizedBox(height: 14),
        Container(width: 92, height: 36, color: base),
        const SizedBox(height: 14),
        Container(width: double.infinity, height: 8, color: base),
        const SizedBox(height: 10),
        Text(
          '正在获取教务学业情况',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '官方 GPA 获取失败',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                errorMessage ?? '请稍后重试',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '重试',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final data = situation;
    final updatedText = data?.updatedAt == null
        ? ''
        : ' · ${data!.updatedAt!.month.toString().padLeft(2, '0')}-${data.updatedAt!.day.toString().padLeft(2, '0')} ${data.updatedAt!.hour.toString().padLeft(2, '0')}:${data.updatedAt!.minute.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '全部课程 GPA',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    data?.allGpa?.toStringAsFixed(2) ?? '--',
                    style: const TextStyle(
                      fontSize: 40,
                      height: 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '学位课 GPA',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 3),
                Text(
                  data?.degreeGpa?.toStringAsFixed(2) ?? '--',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        GradeProgressStrip(
          passed: data?.passedCourses ?? 0,
          failed: data?.failedCourses ?? 0,
          inProgress: data?.inProgressCourses ?? 0,
          notStarted: data?.notStartedCourses ?? 0,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _metric(context, '计划', data?.totalCourses ?? 0),
            _metric(context, '通过', data?.passedCourses ?? 0),
            _metric(context, '未过', data?.failedCourses ?? 0),
            _metric(context, '在读', data?.inProgressCourses ?? 0),
            _metric(context, '未修', data?.notStartedCourses ?? 0),
          ],
        ),
        if (!isDrawerMode) ...[
          const SizedBox(height: 10),
          Text(
            '官方学业情况查询$updatedText',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ]
      ],
    );
  }

  Widget _metric(BuildContext context, String label, int value) {
    return SizedBox(
      width: 48,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }
}
