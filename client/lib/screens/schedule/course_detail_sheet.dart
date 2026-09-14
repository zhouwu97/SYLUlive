import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/course_schedule_provider.dart';
import '../../models/schedule/schedule_override.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/course/course_evaluation_section.dart';
import 'reschedule/select_weeks_sheet.dart';
import 'reschedule/select_time_sheet.dart';
import 'reschedule/confirm_change_sheet.dart';
import 'reschedule/change_room_sheet.dart';
import '../../services/schedule/schedule_conflict_service.dart';

/// 课程详情与本地调整 BottomSheet（升级版）
class CourseDetailSheet extends StatelessWidget {
  final CourseBlock course;
  final int currentAcademicWeek;
  final VoidCallback? onEditCustomCourse;
  final VoidCallback? onDeleteCustomCourse;

  const CourseDetailSheet({
    super.key,
    required this.course,
    required this.currentAcademicWeek,
    this.onEditCustomCourse,
    this.onDeleteCustomCourse,
  });

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  static void show(
    BuildContext context, {
    required CourseBlock course,
    required int currentAcademicWeek,
    VoidCallback? onEditCustomCourse,
    VoidCallback? onDeleteCustomCourse,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CourseDetailSheet(
        course: course,
        currentAcademicWeek: currentAcademicWeek,
        onEditCustomCourse: onEditCustomCourse,
        onDeleteCustomCourse: onDeleteCustomCourse,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final provider = context.watch<CourseScheduleProvider>();
    final isCustom = course.id < 0;
    final wdn = _weekdays[(course.weekday - 1).clamp(0, 6)];

    // 查找该课程是否关联了本地调整规则
    ScheduleOverride? relatedOverride;
    if (course.isOverridden && course.overrideId != null) {
      final matches = provider.overrides.where((o) => o.id == course.overrideId);
      if (matches.isNotEmpty) relatedOverride = matches.first;
    } else if (course.courseKey != null && course.meetingKey != null) {
      final matches = provider.overrides.where((o) =>
          o.courseKey == course.courseKey &&
          o.meetingKey == course.meetingKey &&
          o.isActive);
      if (matches.isNotEmpty) relatedOverride = matches.first;
    }

    final isNeedsReview = relatedOverride?.status == ScheduleOverrideStatus.needsReview;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部拖拽把手
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

                // 标题行与颜色条
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 4,
                      height: 26,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: _parseColor(course.color),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            course.name,
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: tokens.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _buildSourceBadge(tokens, isCustom, course.isOverridden),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 教务源变更警告（needsReview，Section 10）
                if (isNeedsReview) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
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
                            Icon(Icons.notification_important_rounded,
                                color: tokens.warning, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              '教务课表已经发生变化',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: tokens.warning,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '你之前为这节课设置过本地调整，当前学校课表与调整创建时已不一致。',
                          style: TextStyle(fontSize: 12, color: tokens.textSecondary),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: tokens.primary,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              onPressed: () async {
                                if (relatedOverride != null) {
                                  await provider.confirmNeedsReviewOverride(relatedOverride.id);
                                  if (context.mounted) Navigator.pop(context);
                                }
                              },
                              child: const Text('重新确认', style: TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: tokens.error,
                                side: BorderSide(color: tokens.error),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              onPressed: () async {
                                if (relatedOverride != null) {
                                  await provider.restoreBaseMeeting(relatedOverride.id);
                                  if (context.mounted) Navigator.pop(context);
                                }
                              },
                              child: const Text('删除本地调整', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                // 详细信息条目（没有数据的字段不展示，Section 16）
                if (course.teacher != null && course.teacher!.isNotEmpty)
                  _buildDetailRow(Icons.person_outline, '教师', course.teacher!, tokens),
                if (course.location != null && course.location!.isNotEmpty)
                  _buildDetailRow(Icons.location_on_outlined, '教室', course.location!, tokens),
                _buildDetailRow(
                  Icons.access_time,
                  '时间',
                  '周$wdn 第${course.startSection}-${course.endSection}节',
                  tokens,
                ),
                _buildDetailRow(
                  Icons.date_range,
                  '周次',
                  course.weeks.isNotEmpty
                      ? '第${course.weeks.first}-${course.weeks.last}周'
                      : '全周',
                  tokens,
                ),
                if (course.courseCode.isNotEmpty && course.courseCode != 'CUSTOM')
                  _buildDetailRow(Icons.tag, '课程代码', course.courseCode, tokens),
                if (course.teachingClassId != null && course.teachingClassId!.isNotEmpty)
                  _buildDetailRow(Icons.class_outlined, '教学班', course.teachingClassId!, tokens),
                if (course.note != null && course.note!.isNotEmpty)
                  _buildDetailRow(Icons.note_outlined, '备注', course.note!, tokens),

                // 冲突警告指示 (Section 21)
                if (course.hasConflict) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: tokens.isDark ? const Color(0xFF382312) : const Color(0xFFFFEDD5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 18, color: tokens.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            course.hasConflictAtWeek(currentAcademicWeek)
                                ? '当前周（第$currentAcademicWeek周）存在课程时间冲突'
                                : (course.conflictWeeks.isNotEmpty
                                    ? '第${(course.conflictWeeks.toList()..sort()).join('、')}周存在课程时间冲突'
                                    : '当前时间段存在课程时间冲突'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: tokens.isDark ? Colors.amber[300] : Colors.orange[900],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                Divider(color: tokens.divider),
                const SizedBox(height: 12),

                // 操作按钮区 (Section 16 & 17 & 23)
                if (isCustom) ...[
                  // 自定义课程：编辑 / 删除
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        icon: Icon(Icons.edit_outlined, color: tokens.primary),
                        label: Text('编辑课程', style: TextStyle(color: tokens.primary)),
                        onPressed: () {
                          Navigator.pop(context);
                          onEditCustomCourse?.call();
                        },
                      ),
                      TextButton.icon(
                        icon: Icon(Icons.delete_outline, color: tokens.error),
                        label: Text('删除课程', style: TextStyle(color: tokens.error)),
                        onPressed: () {
                          Navigator.pop(context);
                          onDeleteCustomCourse?.call();
                        },
                      ),
                    ],
                  ),
                ] else if (course.isOverridden || relatedOverride != null) ...[
                  // 已调整课程：修改调整 / 恢复原时间 (Section 17)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: tokens.primary,
                            side: BorderSide(color: tokens.primary),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                          label: const Text('修改调整'),
                          onPressed: () => _startRescheduleFlow(context, provider),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: tokens.tagBackground,
                            foregroundColor: tokens.textPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.restore_rounded, size: 18),
                          label: const Text('恢复原时间'),
                          onPressed: () async {
                            final overrideId = course.overrideId ?? relatedOverride?.id;
                            if (overrideId != null) {
                              await provider.restoreBaseMeeting(overrideId);
                              if (context.mounted) Navigator.pop(context);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // 正常教务课程：更换时间 / 修改教室 (Section 16)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: tokens.primary,
                            foregroundColor: tokens.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          icon: const Icon(Icons.edit_calendar_rounded, size: 18),
                          label: const Text('更换时间'),
                          onPressed: () => _startRescheduleFlow(context, provider),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: tokens.textPrimary,
                            side: BorderSide(color: tokens.outline),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          icon: const Icon(Icons.meeting_room_outlined, size: 18),
                          label: const Text('修改教室'),
                          onPressed: () => _startChangeRoomFlow(context, provider),
                        ),
                      ),
                    ],
                  ),
                ],

                // 评价区（仅正式教务课程展示）
                if (!isCustom) ...[
                  const SizedBox(height: 16),
                  CourseEvaluationSection(
                    courseName: course.name,
                    teacherName: course.teacher ?? '',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourceBadge(AppThemeTokens tokens, bool isCustom, bool isOverridden) {
    String label = '教务课表';
    Color bgColor = tokens.isDark ? const Color(0xFF162B28) : const Color(0xFFEAF6F3);
    Color textColor = tokens.primary;

    if (isCustom) {
      label = '手动添加';
      bgColor = tokens.tagBackground;
      textColor = tokens.textSecondary;
    } else if (isOverridden) {
      label = '教务课表 + 本地调整';
      bgColor = tokens.isDark ? const Color(0xFF2C253B) : const Color(0xFFF3EBF9);
      textColor = tokens.isDark ? const Color(0xFFC084FC) : const Color(0xFF7C3AED);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value,
    AppThemeTokens tokens,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 18, color: tokens.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: tokens.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: tokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _parseColor(String hex) {
    final clean = hex.replaceAll('#', '');
    if (clean.length == 6) {
      return Color(int.parse('FF$clean', radix: 16));
    }
    return const Color(0xFF6366F1);
  }

  /// 启动三步调课流程 (Section 18 - 20)
  Future<void> _startRescheduleFlow(
    BuildContext context,
    CourseScheduleProvider provider,
  ) async {
    Navigator.pop(context); // 先关闭详情弹窗

    // 步骤 1：选择周次
    final affectedWeeks = await SelectWeeksSheet.show(
      context,
      course: course,
      currentAcademicWeek: currentAcademicWeek,
    );
    if (affectedWeeks == null || affectedWeeks.isEmpty || !context.mounted) return;

    // 步骤 2：选择目标时间
    final targetTime = await SelectTimeSheet.show(
      context,
      course: course,
      affectedWeeks: affectedWeeks,
    );
    if (targetTime == null || !context.mounted) return;

    // 步骤 3：冲突检测并弹出确认弹窗
    const conflictService = ScheduleConflictService();
    final conflictResult = conflictService.check(
      currentResolved: provider.resolvedMeetings,
      targetCourseKey: course.courseKey ?? '',
      targetMeetingKey: course.meetingKey ?? '',
      targetWeekday: targetTime.weekday,
      targetStartSection: targetTime.startSection,
      targetEndSection: targetTime.endSection,
      targetWeeks: affectedWeeks,
      editingOverrideId: course.overrideId,
    );

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ConfirmChangeSheet(
        course: course,
        affectedWeeks: affectedWeeks,
        toWeekday: targetTime.weekday,
        toStartSection: targetTime.startSection,
        toEndSection: targetTime.endSection,
        toRoom: targetTime.newRoom,
        conflictResult: conflictResult,
        onBackToEdit: () {
          Navigator.pop(ctx);
          // 重新打开步骤2
          _startRescheduleFlow(context, provider);
        },
        onConfirm: () async {
          Navigator.pop(ctx);
          final snapshotHash =
              'w${course.weekday}:s${course.startSection}-${course.endSection}:weeks[${course.weeks.join(',')}]:room[${course.location?.trim() ?? ''}]';

          await provider.createRescheduleOverride(
            courseKey: course.courseKey ?? 'edu:course:${course.name}',
            meetingKey: course.meetingKey ?? 'm_${course.weekday}_${course.startSection}',
            affectedWeeks: affectedWeeks,
            toWeekday: targetTime.weekday,
            toStartSection: targetTime.startSection,
            toEndSection: targetTime.endSection,
            toRoom: targetTime.newRoom,
            sourceSnapshotHash: snapshotHash,
            fromWeekday: course.weekday,
            fromStartSection: course.startSection,
            fromEndSection: course.endSection,
            fromRoom: course.location,
            allowConflict: conflictResult.hasConflict,
          );
        },
      ),
    );
  }

  /// 启动修改教室流程 (Section 22)
  void _startChangeRoomFlow(
    BuildContext context,
    CourseScheduleProvider provider,
  ) {
    Navigator.pop(context);
    ChangeRoomSheet.show(
      context,
      course: course,
      currentAcademicWeek: currentAcademicWeek,
      onConfirm: (affectedWeeks, newRoom) async {
        final snapshotHash =
            'w${course.weekday}:s${course.startSection}-${course.endSection}:weeks[${course.weeks.join(',')}]:room[${course.location?.trim() ?? ''}]';

        await provider.createChangeRoomOverride(
          courseKey: course.courseKey ?? 'edu:course:${course.name}',
          meetingKey: course.meetingKey ?? 'm_${course.weekday}_${course.startSection}',
          affectedWeeks: affectedWeeks,
          toRoom: newRoom,
          sourceSnapshotHash: snapshotHash,
          fromRoom: course.location,
        );
      },
    );
  }
}
