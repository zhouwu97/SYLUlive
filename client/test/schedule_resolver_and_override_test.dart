import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/schedule/course.dart';
import 'package:shenliyuan/models/schedule/course_source.dart';
import 'package:shenliyuan/models/schedule/meeting.dart';
import 'package:shenliyuan/models/schedule/schedule_override.dart';
import 'package:shenliyuan/services/schedule/schedule_resolver.dart';
import 'package:shenliyuan/services/schedule/meeting_reconciler.dart';
import 'package:shenliyuan/services/schedule/schedule_conflict_service.dart';
import 'package:shenliyuan/repositories/schedule_override_repository.dart';

void main() {
  group('ScheduleResolver 核心算法测试 (Section 42 核心规范)', () {
    const resolver = ScheduleResolver();
    const conflictService = ScheduleConflictService();

    final baseCourse1 = Course(
      courseKey: 'edu:2026_1:080123:TC01',
      semesterId: '2026_1',
      source: CourseSource.edu,
      name: '数字图像处理',
      courseCode: '080123',
      teachingClassId: 'TC01',
      teacher: '王辉宇',
      meetings: [
        Meeting(
          meetingKey: 'm_mon_34',
          weekday: 1,
          startSection: 3,
          endSection: 4,
          weeks: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13},
          room: 'XX-430',
          teacher: '王辉宇',
        ),
      ],
    );

    test('场景1：修改单周 -> 只有该周变化，其他周保持原时间', () {
      final override = ScheduleOverride(
        id: 'ov_1',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {5},
        toWeekday: 3,
        toStartSection: 1,
        toEndSection: 2,
        toRoom: 'XX-430',
        sourceSnapshotHash: baseCourse1.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [override],
        semesterId: '2026_1',
      );

      // 应当产生两块：原时间 (1-4, 6-13周) 和 调整后 (5周，周三1-2)
      expect(resolved.length, 2);

      final originalPart = resolved.firstWhere((r) => !r.isOverridden);
      expect(originalPart.weekday, 1);
      expect(originalPart.startSection, 3);
      expect(originalPart.endSection, 4);
      expect(originalPart.weeks, {1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13});

      final overriddenPart = resolved.firstWhere((r) => r.isOverridden);
      expect(overriddenPart.weekday, 3);
      expect(overriddenPart.startSection, 1);
      expect(overriddenPart.endSection, 2);
      expect(overriddenPart.weeks, {5});
      expect(overriddenPart.overrideId, 'ov_1');
    });

    test('场景2：修改连续周 -> 只有选择范围变化 (第5-8周)', () {
      final override = ScheduleOverride(
        id: 'ov_5_8',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {5, 6, 7, 8},
        toWeekday: 3,
        toStartSection: 1,
        toEndSection: 2,
        toRoom: 'B-201',
        sourceSnapshotHash: baseCourse1.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [override],
        semesterId: '2026_1',
      );

      // 原课剩余周：1-4 和 9-13
      final originalPart = resolved.firstWhere((r) => !r.isOverridden);
      expect(originalPart.weeks, {1, 2, 3, 4, 9, 10, 11, 12, 13});

      // 调整后：5-8
      final overriddenPart = resolved.firstWhere((r) => r.isOverridden);
      expect(overriddenPart.weekday, 3);
      expect(overriddenPart.startSection, 1);
      expect(overriddenPart.endSection, 2);
      expect(overriddenPart.weeks, {5, 6, 7, 8});
      expect(overriddenPart.room, 'B-201');
    });

    test('场景3 & 4 & 5：单双周与离散周处理 -> 取 affectedWeeks 交集，不产生虚假周次', () {
      // 单周课: 1, 3, 5, 7, 9, 11, 13
      final oddCourse = Course(
        courseKey: 'edu:2026_1:odd_course:TC02',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '单周实验课',
        meetings: [
          Meeting(
            meetingKey: 'm_odd',
            weekday: 2,
            startSection: 1,
            endSection: 2,
            weeks: {1, 3, 5, 7, 9, 11, 13},
            room: 'Lab-101',
          ),
        ],
      );

      // 用户选择了 3 到 8 周
      final override = ScheduleOverride(
        id: 'ov_discrete',
        semesterId: '2026_1',
        courseKey: oddCourse.courseKey,
        meetingKey: 'm_odd',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {3, 4, 5, 6, 7, 8}, // 包含双周
        toWeekday: 4,
        toStartSection: 5,
        toEndSection: 6,
        sourceSnapshotHash: oddCourse.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [oddCourse],
        overrides: [override],
        semesterId: '2026_1',
      );

      final original = resolved.firstWhere((r) => !r.isOverridden);
      final overridden = resolved.firstWhere((r) => r.isOverridden);

      // 原课剩余周次只剩下 1, 9, 11, 13
      expect(original.weeks, {1, 9, 11, 13});

      // 调整后周次严格为交集 {3, 5, 7}，绝不会凭空出现 4, 6, 8 双周！
      expect(overridden.weeks, {3, 5, 7});
      expect(overridden.weekday, 4);
    });

    test('场景6 & 7：同课程两个 Meeting 以及同天 1-2 / 3-4 -> 互不影响', () {
      final multiMeetingCourse = Course(
        courseKey: 'edu:2026_1:multi:TC03',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '高等数学',
        meetings: [
          Meeting(
            meetingKey: 'm_mon_12',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3, 4, 5},
            room: 'A-101',
          ),
          Meeting(
            meetingKey: 'm_mon_34',
            weekday: 1,
            startSection: 3,
            endSection: 4,
            weeks: {1, 2, 3, 4, 5},
            room: 'A-101',
          ),
        ],
      );

      // 只调整 1-2 节
      final override = ScheduleOverride(
        id: 'ov_mon_12',
        semesterId: '2026_1',
        courseKey: multiMeetingCourse.courseKey,
        meetingKey: 'm_mon_12',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {3},
        toWeekday: 2,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: multiMeetingCourse.meetings[0].computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [multiMeetingCourse],
        overrides: [override],
        semesterId: '2026_1',
      );

      // m_mon_34 绝不能受到任何影响
      final meeting34 = resolved.firstWhere(
        (r) => r.meetingKey == 'm_mon_34',
      );
      expect(meeting34.weekday, 1);
      expect(meeting34.startSection, 3);
      expect(meeting34.endSection, 4);
      expect(meeting34.weeks, {1, 2, 3, 4, 5});
      expect(meeting34.isOverridden, false);

      // m_mon_12 只有第 3 周调整
      final meeting12Original = resolved.firstWhere(
        (r) => r.meetingKey == 'm_mon_12' && !r.isOverridden,
      );
      expect(meeting12Original.weeks, {1, 2, 4, 5});

      final meeting12Overridden = resolved.firstWhere(
        (r) => r.meetingKey == 'm_mon_12' && r.isOverridden,
      );
      expect(meeting12Overridden.weekday, 2);
      expect(meeting12Overridden.weeks, {3});
    });

    test('场景8：同名不同课 -> 互不影响 (通过 courseKey 隔离)', () {
      final courseA = Course(
        courseKey: 'edu:2026_1:CS01:TC_A',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '程序设计',
        courseCode: 'CS01',
        teachingClassId: 'TC_A',
        meetings: [
          Meeting(
            meetingKey: 'm_a',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3},
          ),
        ],
      );

      final courseB = Course(
        courseKey: 'edu:2026_1:CS02:TC_B',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '程序设计',
        courseCode: 'CS02',
        teachingClassId: 'TC_B',
        meetings: [
          Meeting(
            meetingKey: 'm_b',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3},
          ),
        ],
      );

      final overrideA = ScheduleOverride(
        id: 'ov_a',
        semesterId: '2026_1',
        courseKey: courseA.courseKey,
        meetingKey: 'm_a',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {2},
        toWeekday: 5,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: courseA.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [courseA, courseB],
        overrides: [overrideA],
        semesterId: '2026_1',
      );

      // Course B 保持完整原样
      final bMeetings = resolved.where((r) => r.courseKey == courseB.courseKey);
      expect(bMeetings.length, 1);
      expect(bMeetings.first.weeks, {1, 2, 3});
      expect(bMeetings.first.isOverridden, false);
    });

    test('场景9：修改教室 -> 只修改指定周次教室，节次时间不变', () {
      final override = ScheduleOverride(
        id: 'ov_room',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.changeRoom,
        affectedWeeks: {7, 8, 9},
        toRoom: 'A-108',
        sourceSnapshotHash: baseCourse1.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [override],
        semesterId: '2026_1',
      );

      final original = resolved.firstWhere((r) => !r.isOverridden);
      expect(original.room, 'XX-430');
      expect(original.weeks, {1, 2, 3, 4, 5, 6, 10, 11, 12, 13});

      final changed = resolved.firstWhere((r) => r.isOverridden);
      expect(changed.room, 'A-108');
      expect(changed.weeks, {7, 8, 9});
      expect(changed.weekday, 1);
      expect(changed.startSection, 3);
      expect(changed.endSection, 4);
    });

    test('场景10：Override 删除 -> 自动恢复 BaseSchedule 原数据', () {
      // 没有任何 override 传入时
      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [],
        semesterId: '2026_1',
      );

      expect(resolved.length, 1);
      expect(resolved.first.weeks, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
      expect(resolved.first.isOverridden, false);
    });

    test('场景12：重叠 Override 规则校验 -> 同一 meetingKey 禁止 affectedWeeks 相交', () {
      final ov1 = ScheduleOverride(
        id: 'ov_5_8',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {5, 6, 7, 8},
        toWeekday: 3,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final ov2 = ScheduleOverride(
        id: 'ov_7_10',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {7, 8, 9, 10}, // 与 ov1 在 7,8 周重叠
        toWeekday: 4,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final repo = ScheduleOverrideRepository();
      expect(
        () => repo.validateNoOverlap(candidate: ov2, existingList: [ov1]),
        throwsA(isA<ScheduleOverrideOverlapException>()),
      );

      expect(
        () => resolver.resolve(
          baseSchedule: [baseCourse1],
          overrides: [ov1, ov2],
          semesterId: '2026_1',
        ),
        throwsA(isA<ScheduleResolverException>()),
      );
    });

    test('场景13：目标时间冲突检测与展示 -> 提示时间冲突并标识 hasConflict', () {
      final existingCourse = Course(
        courseKey: 'edu:2026_1:080999:TC99',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '高频电子线路',
        meetings: [
          Meeting(
            meetingKey: 'm_wed_12',
            weekday: 3,
            startSection: 1,
            endSection: 2,
            weeks: {5, 6, 7, 8},
            room: 'C-302',
          ),
        ],
      );

      // 用户将数字图像处理第 6 周调到 周三 1-2
      final conflictCheck = conflictService.check(
        currentResolved: resolver.resolve(
          baseSchedule: [baseCourse1, existingCourse],
          overrides: [],
          semesterId: '2026_1',
        ),
        targetCourseKey: baseCourse1.courseKey,
        targetMeetingKey: 'm_mon_34',
        targetWeekday: 3,
        targetStartSection: 1,
        targetEndSection: 2,
        targetWeeks: {6},
      );

      expect(conflictCheck.hasConflict, true);
      expect(conflictCheck.conflicts.first.existingCourseName, '高频电子线路');
      expect(conflictCheck.conflicts.first.conflictingWeeks, {6});

      // 用户选择保留冲突并保存时，Resolver 正确标记 hasConflict
      final overrideConflict = ScheduleOverride(
        id: 'ov_conflict',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        status: ScheduleOverrideStatus.conflicted,
        affectedWeeks: {6},
        toWeekday: 3,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: baseCourse1.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1, existingCourse],
        overrides: [overrideConflict],
        semesterId: '2026_1',
      );

      final conflictedMeeting = resolved.firstWhere(
        (r) => r.overrideId == 'ov_conflict',
      );
      expect(conflictedMeeting.hasConflict, true);
    });

    test('场景14 & 15 & 16 & 17：MeetingReconciler 对齐行为测试', () {
      const reconciler = MeetingReconciler();

      final existingOverride = ScheduleOverride(
        id: 'ov_reconcile_test',
        semesterId: '2026_1',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {5},
        toWeekday: 4,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: baseCourse1.meetings.first.computeSnapshotHash(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // 1. 教务重新同步，且数据无变化 -> meetingKey 继承，Override 保持 active
      final result1 = reconciler.reconcile(
        oldBaseSchedule: [baseCourse1],
        newEduCourses: [baseCourse1],
        existingOverrides: [existingOverride],
        semesterId: '2026_1',
      );

      expect(result1.updatedOverrides.first.status, ScheduleOverrideStatus.active);
      expect(result1.needsReviewOverrides, isEmpty);
      expect(result1.orphanedOverrides, isEmpty);

      // 2. 学校教务调整了上课教室或节次 -> snapshotHash 不匹配，Override 进入 needsReview
      final changedEduCourse = Course(
        courseKey: baseCourse1.courseKey,
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: baseCourse1.name,
        courseCode: baseCourse1.courseCode,
        teachingClassId: baseCourse1.teachingClassId,
        teacher: baseCourse1.teacher,
        meetings: [
          Meeting(
            meetingKey: '', // 新拉取的课程暂无 key
            weekday: 1,
            startSection: 3,
            endSection: 4,
            weeks: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13},
            room: 'NEW-ROOM-999', // 学校换了教室！
          ),
        ],
      );

      final result2 = reconciler.reconcile(
        oldBaseSchedule: [baseCourse1],
        newEduCourses: [changedEduCourse],
        existingOverrides: [existingOverride],
        semesterId: '2026_1',
      );

      expect(result2.needsReviewOverrides.length, 1);
      expect(result2.updatedOverrides.first.status, ScheduleOverrideStatus.needsReview);

      // 3. 学校取消了这门课 -> 无法重新关联，Override 进入 orphaned
      final result3 = reconciler.reconcile(
        oldBaseSchedule: [baseCourse1],
        newEduCourses: [],
        existingOverrides: [existingOverride],
        semesterId: '2026_1',
      );

      expect(result3.orphanedOverrides.length, 1);
      expect(result3.updatedOverrides.first.status, ScheduleOverrideStatus.orphaned);
    });

    test('场景18：学期切换 -> 不加载旧学期规则', () {
      final overrideNextSemester = ScheduleOverride(
        id: 'ov_next_term',
        semesterId: '2026_2',
        courseKey: baseCourse1.courseKey,
        meetingKey: 'm_mon_34',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {5},
        toWeekday: 5,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [overrideNextSemester],
        semesterId: '2026_1',
      );

      // 2026_2 的规则绝不会应用到 2026_1
      expect(resolved.length, 1);
      expect(resolved.first.isOverridden, false);
    });

    test('场景19：手动课程 -> 正常进入 ScheduleResolver，统一数据结构', () {
      final manualCourse = Course(
        courseKey: 'manual:2026_1:m1',
        semesterId: '2026_1',
        source: CourseSource.manual,
        name: 'ACM集训',
        meetings: [
          Meeting(
            meetingKey: 'm_manual_sat',
            weekday: 6,
            startSection: 1,
            endSection: 4,
            weeks: {1, 2, 3, 4},
            room: '机房1',
          ),
        ],
      );

      final resolved = resolver.resolve(
        baseSchedule: [baseCourse1],
        overrides: [],
        manualCourses: [manualCourse],
        semesterId: '2026_1',
      );

      expect(resolved.length, 2);
      final manualResolved = resolved.firstWhere(
        (r) => r.source == CourseSource.manual,
      );
      expect(manualResolved.courseName, 'ACM集训');
      expect(manualResolved.weekday, 6);
      expect(manualResolved.startSection, 1);
      expect(manualResolved.endSection, 4);
      expect(manualResolved.isOverridden, false);
    });

    test('回归测试：冲突只发生在第6周 -> 仅第6周标记冲突，第1-5、7-8周不得显示冲突', () {
      final courseA = Course(
        courseKey: 'edu:2026_1:c_a:tc_a',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '课程A',
        meetings: [
          Meeting(
            meetingKey: 'm_a',
            weekday: 3,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3, 4, 5, 6, 7, 8},
          ),
        ],
      );

      final courseB = Course(
        courseKey: 'edu:2026_1:c_b:tc_b',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '课程B',
        meetings: [
          Meeting(
            meetingKey: 'm_b',
            weekday: 3,
            startSection: 1,
            endSection: 2,
            weeks: {6}, // 仅第6周
          ),
        ],
      );

      final resolved = resolver.resolve(
        baseSchedule: [courseA, courseB],
        overrides: [],
        semesterId: '2026_1',
      );

      final resolvedA = resolved.firstWhere((r) => r.courseKey == courseA.courseKey);
      final resolvedB = resolved.firstWhere((r) => r.courseKey == courseB.courseKey);

      // 整体冲突布尔标记
      expect(resolvedA.hasConflict, isTrue);
      expect(resolvedB.hasConflict, isTrue);

      // 冲突周次粒度必须严格为 {6}
      expect(resolvedA.conflictWeeks, {6});
      expect(resolvedB.conflictWeeks, {6});

      // 第6周必须报告冲突
      expect(resolvedA.hasConflictAtWeek(6), isTrue);
      expect(resolvedB.hasConflictAtWeek(6), isTrue);

      // 第1-5、7-8周绝不得报告冲突！
      for (final w in [1, 2, 3, 4, 5, 7, 8]) {
        expect(
          resolvedA.hasConflictAtWeek(w),
          isFalse,
          reason: '课程A在第$w周不应显示冲突',
        );
      }
    });

    test('回归测试：不同课程即使拥有相同 meetingKey 也不得误判为同一时间块重叠', () {
      final overrideCourse1 = ScheduleOverride(
        id: 'ov_c1',
        semesterId: '2026_1',
        courseKey: 'edu:2026_1:c1',
        meetingKey: 'meeting_1',
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {1, 2, 3},
        toWeekday: 1,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final overrideCourse2 = ScheduleOverride(
        id: 'ov_c2',
        semesterId: '2026_1',
        courseKey: 'edu:2026_1:c2',
        meetingKey: 'meeting_1', // 相同 meetingKey 但不同 courseKey
        type: ScheduleOverrideType.reschedule,
        affectedWeeks: {2, 3, 4}, // 周次有交集
        toWeekday: 2,
        toStartSection: 1,
        toEndSection: 2,
        sourceSnapshotHash: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final repo = ScheduleOverrideRepository();
      // 不应抛出重叠异常
      expect(
        () => repo.validateNoOverlap(
          candidate: overrideCourse2,
          existingList: [overrideCourse1],
        ),
        returnsNormally,
      );
    });

    test('回归测试：MeetingReconciler 优先教学班+课程代码匹配并忽略跨学期缓存', () {
      const reconciler = MeetingReconciler();

      final oldCourseSameTerm = Course(
        courseKey: 'edu:2026_1:c1:tc01',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '操作系统',
        courseCode: 'CS301',
        teachingClassId: 'TC01',
        meetings: [
          Meeting(
            meetingKey: 'm_old_2026_1',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3},
          ),
        ],
      );

      final oldCourseOtherTerm = Course(
        courseKey: 'edu:2025_2:c1:tc01',
        semesterId: '2025_2', // 上学期同教学班 ID
        source: CourseSource.edu,
        name: '操作系统（旧）',
        courseCode: 'CS301',
        teachingClassId: 'TC01',
        meetings: [
          Meeting(
            meetingKey: 'm_old_2025_2',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3},
          ),
        ],
      );

      final newCourse = Course(
        courseKey: 'edu:2026_1:c1:tc01',
        semesterId: '2026_1',
        source: CourseSource.edu,
        name: '操作系统',
        courseCode: 'CS301',
        teachingClassId: 'TC01',
        meetings: [
          Meeting(
            meetingKey: '',
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeks: {1, 2, 3},
          ),
        ],
      );

      final result = reconciler.reconcile(
        oldBaseSchedule: [oldCourseOtherTerm, oldCourseSameTerm],
        newEduCourses: [newCourse],
        existingOverrides: [],
        semesterId: '2026_1',
      );

      // 应当继承 2026_1 的 meetingKey，而不是 2025_2 的
      expect(
        result.reconciledCourses.first.meetings.first.meetingKey,
        'm_old_2026_1',
      );
    });
  });
}
