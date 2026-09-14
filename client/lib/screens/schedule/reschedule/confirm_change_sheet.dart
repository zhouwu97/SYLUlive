import 'package:flutter/material.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../services/schedule/schedule_conflict_service.dart';
import '../../../theme/app_theme_tokens.dart';

/// 调课第三步：确认与冲突检查
class ConfirmChangeSheet extends StatelessWidget {
  final CourseBlock course;
  final Set<int> affectedWeeks;
  final int toWeekday;
  final int toStartSection;
  final int toEndSection;
  final String? toRoom;
  final ScheduleConflictCheckResult conflictResult;
  final VoidCallback onConfirm;
  final VoidCallback onBackToEdit;

  const ConfirmChangeSheet({
    super.key,
    required this.course,
    required this.affectedWeeks,
    required this.toWeekday,
    required this.toStartSection,
    required this.toEndSection,
    this.toRoom,
    required this.conflictResult,
    required this.onConfirm,
    required this.onBackToEdit,
  });

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final sortedWeeks = affectedWeeks.toList()..sort();
    final hasConflict = conflictResult.hasConflict;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '确认修改 (3/3)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: tokens.textSecondary, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                course.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: tokens.primary,
                ),
              ),
              const SizedBox(height: 12),
              // 调整范围与时间对比卡片
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: tokens.inputBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tokens.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '影响周次：第 ${sortedWeeks.join('、')} 周 (共 ${sortedWeeks.length} 周)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('原时间',
                                  style: TextStyle(
                                      fontSize: 11, color: tokens.textSecondary)),
                              const SizedBox(height: 2),
                              Text(
                                '周${_weekdays[course.weekday - 1]} 第${course.startSection}-${course.endSection}节',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: tokens.textPrimary,
                                ),
                              ),
                              if (course.location != null)
                                Text(course.location!,
                                    style: TextStyle(
                                        fontSize: 11, color: tokens.textSecondary)),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_forward_rounded,
                            size: 20, color: tokens.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('新时间',
                                  style: TextStyle(
                                      fontSize: 11, color: tokens.primary)),
                              const SizedBox(height: 2),
                              Text(
                                '周${_weekdays[toWeekday - 1]} 第$toStartSection-$toEndSection节',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: tokens.primary,
                                ),
                              ),
                              if (toRoom != null && toRoom!.isNotEmpty)
                                Text(toRoom!,
                                    style: TextStyle(
                                        fontSize: 11, color: tokens.textSecondary)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 冲突检测状态
              if (!hasConflict) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: tokens.isDark
                        ? const Color(0xFF142B1F)
                        : const Color(0xFFE8F7EE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: tokens.success, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '未发现课程冲突',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: tokens.success,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.primary,
                      foregroundColor: tokens.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: onConfirm,
                    child: const Text('确认修改',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
              ] else ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tokens.isDark
                        ? const Color(0xFF2E2413)
                        : const Color(0xFFFFF3DD),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: tokens.warning.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: tokens.warning, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            '发现时间冲突',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: tokens.warning,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...conflictResult.conflicts.map((conf) {
                        final weeksList = conf.conflictingWeeks.toList()..sort();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '• 第${weeksList.join('、')}周 周${_weekdays[conf.weekday - 1]} 第${conf.startSection}-${conf.endSection}节 已有课程：${conf.existingCourseName}',
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.isDark ? Colors.amber[200] : Colors.brown[800],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 6),
                      Text(
                        '继续保存后，两门课程将在同一时间出现。',
                        style: TextStyle(fontSize: 11, color: tokens.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: tokens.textPrimary,
                          side: BorderSide(color: tokens.outline),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: onBackToEdit,
                        child: const Text('返回修改'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.warning,
                          foregroundColor: Colors.black87,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: onConfirm,
                        child: const Text('保留冲突并保存',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
