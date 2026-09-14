import 'package:flutter/material.dart';
import '../../models/edu_academic_situation.dart';

/// 官方学业概览卡片（置于“学业总览”顶部）
class AcademicSituationCard extends StatelessWidget {
  final EduAcademicSituation? situation;
  final bool isLoading;
  final bool isRefreshing;
  final String? errorMessage;
  final DateTime? updatedAt;
  final VoidCallback? onRetry;

  const AcademicSituationCard({
    super.key,
    required this.situation,
    this.isLoading = false,
    this.isRefreshing = false,
    this.errorMessage,
    this.updatedAt,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF7A8087);
    final accentColor =
        isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE2EFEA);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          gradient: isDark
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white,
                    Color(0xFFF1FBF7),
                  ],
                ),
          color: isDark ? const Color(0xFF1E2226) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶栏：标题 + 官方数据徽章 + 刷新状态
            Row(
              children: [
                Text(
                  '学业概览',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark
                        ? accentColor.withValues(alpha: 0.14)
                        : const Color(0xFFEAF6F3),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '官方数据',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: accentColor,
                    ),
                  ),
                ),
                const Spacer(),
                if (isRefreshing || isLoading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(accentColor),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // 主内容：官方 GPA 双指标
            if (situation != null) ...[
              Row(
                children: [
                  Expanded(
                    child: _buildGpaMetric(
                      title: '全部课程 GPA',
                      value: situation!.allGpa?.toStringAsFixed(2) ?? '--',
                      accentColor: accentColor,
                      subColor: subColor,
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 36,
                    color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
                  ),
                  Expanded(
                    child: _buildGpaMetric(
                      title: '学位课程 GPA',
                      value: situation!.degreeGpa?.toStringAsFixed(2) ?? '--',
                      accentColor: accentColor,
                      subColor: subColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // 课程进度 Pills
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildStatPill('计划 ${situation!.totalCourses} 门', accentColor, isDark),
                  _buildStatPill('已通过 ${situation!.passedCourses} 门', accentColor, isDark),
                  if (situation!.inProgressCourses > 0)
                    _buildStatPill('在读 ${situation!.inProgressCourses} 门', accentColor, isDark),
                  if (situation!.failedCourses > 0)
                    _buildStatPill('未通过 ${situation!.failedCourses} 门', const Color(0xFFE54848), isDark),
                  if (situation!.notStartedCourses > 0)
                    _buildStatPill('未修 ${situation!.notStartedCourses} 门', subColor, isDark),
                ],
              ),
              const SizedBox(height: 12),
              // 底部更新时间
              Text(
                updatedAt == null
                    ? '教务官方数据 · 暂未记录同步时间'
                    : '教务官方数据 · ${updatedAt!.toLocal().month}月${updatedAt!.toLocal().day}日 ${updatedAt!.toLocal().hour.toString().padLeft(2, '0')}:${updatedAt!.toLocal().minute.toString().padLeft(2, '0')} 同步',
                style: TextStyle(
                  fontSize: 12,
                  color: subColor,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ] else if (isLoading) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '正在获取教务官方学业概览…',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
              ),
            ] else ...[
              // 空或异常状态
              Row(
                children: [
                  Expanded(
                    child: Text(
                      errorMessage ?? '暂未获取到官方学业概览',
                      style: TextStyle(fontSize: 13, color: subColor),
                    ),
                  ),
                  if (onRetry != null)
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGpaMetric({
    required String title,
    required String value,
    required Color accentColor,
    required Color subColor,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 26,
            height: 1,
            fontWeight: FontWeight.w800,
            color: accentColor,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: subColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildStatPill(String label, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark
            ? color.withValues(alpha: 0.12)
            : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
