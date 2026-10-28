import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/schedule/course.dart';
import 'package:shenliyuan/models/schedule/course_source.dart';
import 'package:shenliyuan/models/schedule/meeting.dart';
import 'package:shenliyuan/services/schedule/schedule_conflict_service.dart';
import 'package:shenliyuan/services/schedule/schedule_resolver.dart';
import 'package:shenliyuan/models/schedule/schedule_override.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/repositories/schedule_override_repository.dart';
import 'package:shenliyuan/services/schedule/meeting_reconciler.dart';

Course _course(
        {String key = 'course',
        Set<int> weeks = const {8, 9, 10},
        int weekday = 1}) =>
    Course(
      courseKey: key,
      semesterId: 'term',
      source: CourseSource.edu,
      name: '网络安全技术',
      meetings: [
        Meeting(
          meetingKey: 'meeting',
          weekday: weekday,
          startSection: 5,
          endSection: 6,
          weeks: weeks,
        )
      ],
    );

ScheduleOverride _override(
        {Set<int> weeks = const {9},
        int offset = -1,
        bool merge = false,
        String id = 'ov',
        int weekday = 1}) =>
    ScheduleOverride(
      id: id,
      semesterId: 'term',
      courseKey: 'course',
      meetingKey: 'meeting',
      type: ScheduleOverrideType.reschedule,
      affectedWeeks: weeks,
      weekOffset: offset,
      replaceSameCourse: merge,
      toWeekday: weekday,
      toStartSection: 5,
      toEndSection: 6,
      sourceSnapshotHash: _course().meetings.single.computeSnapshotHash(),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

class _FailingPreferences extends MemoryPreferencesStore {
  bool fail = true;
  @override
  Future<bool> setString(String key, String value) async =>
      fail ? false : await super.setString(key, value);
}

void main() {
  setUp(() => AppPreferencesStore.setCustomInstance(MemoryPreferencesStore()));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));
  test('调课预览不把本次移走的原安排算作冲突', () {
    final resolved = const ScheduleResolver().resolve(
      baseSchedule: [
        const Course(
          courseKey: 'course',
          semesterId: 'term',
          source: CourseSource.edu,
          name: '网络安全技术',
          meetings: [
            Meeting(
              meetingKey: 'meeting',
              weekday: 1,
              startSection: 5,
              endSection: 6,
              weeks: {8, 9, 10},
            )
          ],
        ),
      ],
      overrides: [],
    );
    final result = const ScheduleConflictService().check(
      currentResolved: resolved,
      targetCourseKey: 'course',
      targetMeetingKey: 'meeting',
      targetWeekday: 1,
      targetStartSection: 5,
      targetEndSection: 6,
      targetWeeks: {9},
    );
    expect(result.hasConflict, isFalse);
  });

  test('第9周提前到空闲的第8周，保留第10周；恢复后回到原安排', () {
    final base = [
      _course(weeks: {9, 10})
    ];
    final result = const ScheduleResolver()
        .resolve(baseSchedule: base, overrides: [_override()]);
    expect(result.firstWhere((r) => r.isOverridden).weeks, {8});
    expect(result.firstWhere((r) => !r.isOverridden).weeks, {10});
    expect(result.any((r) => r.weeks.contains(9)), isFalse);
    expect(result.any((r) => r.hasConflict), isFalse);
    expect(
        const ScheduleResolver()
            .resolve(baseSchedule: base, overrides: [])
            .single
            .weeks,
        {9, 10});
  });

  test('同课程目标安排仅在明确合并后显示一次；恢复时保留原目标周', () {
    final base = [_course()];
    final duplicate = const ScheduleResolver()
        .resolve(baseSchedule: base, overrides: [_override()]);
    expect(duplicate.where((r) => r.weeks.contains(8)), hasLength(2));
    expect(duplicate.every((r) => r.hasConflictAtWeek(8)), isTrue);
    final merged = const ScheduleResolver()
        .resolve(baseSchedule: base, overrides: [_override(merge: true)]);
    expect(merged.where((r) => r.weeks.contains(8)), hasLength(1));
    expect(merged.any((r) => r.hasConflict), isFalse);
    expect(merged.firstWhere((r) => !r.isOverridden).weeks, {10});
    expect(
        const ScheduleResolver()
            .resolve(baseSchedule: base, overrides: [])
            .single
            .weeks,
        {8, 9, 10});
  });

  test('连续周和单双周整体平移，不补出不存在的周次', () {
    for (final sourceWeeks in [
      {9, 10, 11},
      {9, 11, 13}
    ]) {
      final resolved = const ScheduleResolver().resolve(
        baseSchedule: [_course(weeks: sourceWeeks)],
        overrides: [_override(weeks: sourceWeeks)],
      );
      expect(resolved.single.weeks, sourceWeeks.map((w) => w - 1).toSet());
    }
  });

  test('同名不同课程和已有调课不能被合并；冲突周只标记目标周', () {
    final resolved = const ScheduleResolver().resolve(
      baseSchedule: [
        _course(weeks: {9}),
        _course(key: 'other', weeks: {8, 10})
      ],
      overrides: [_override(merge: true)],
    );
    expect(resolved.where((r) => r.weeks.contains(8)), hasLength(2));
    expect(resolved.every((r) => r.conflictWeeks.contains(8)), isTrue);
    expect(resolved.any((r) => r.conflictWeeks.contains(10)), isFalse);
    final ownOverrides = const ScheduleResolver().resolve(
      baseSchedule: [_course()],
      overrides: [
        _override(merge: true),
        _override(id: 'other', weeks: {10}, offset: -2)
      ],
    );
    expect(ownOverrides.where((r) => r.isOverridden), hasLength(2));
    expect(ownOverrides.every((r) => r.hasConflict), isTrue);
  });

  test('目标冲突检查排除移走的源周，并区分可合并与不同教学安排', () {
    final resolved = const ScheduleResolver().resolve(
        baseSchedule: [_course(), _course(key: 'other')], overrides: []);
    final result = const ScheduleConflictService().check(
      currentResolved: resolved,
      targetCourseKey: 'course',
      targetMeetingKey: 'meeting',
      targetWeekday: 1,
      targetStartSection: 5,
      targetEndSection: 6,
      sourceWeeks: {9},
      targetWeeks: {8},
    );
    expect(result.conflicts, hasLength(2));
    expect(result.conflicts.where((c) => c.canReplaceSameCourse), hasLength(1));
    expect(
        result.conflicts.every((c) => c.conflictingWeeks.single == 8), isTrue);
  });

  test('部分重叠的同课程不提供合并', () {
    final resolved = const ScheduleResolver()
        .resolve(baseSchedule: [_course()], overrides: []);
    final result = const ScheduleConflictService().check(
      currentResolved: resolved,
      targetCourseKey: 'course',
      targetMeetingKey: 'meeting',
      targetWeekday: 1,
      targetStartSection: 6,
      targetEndSection: 7,
      sourceWeeks: {9},
      targetWeeks: {8},
    );
    expect(result.hasConflict, isTrue);
    expect(result.conflicts.single.canReplaceSameCourse, isFalse);
  });

  test('新规则往返持久化，旧规则默认周次不变，重新同步保留调整', () async {
    final repository = ScheduleOverrideRepository();
    final candidate = _override(merge: true);
    expect(await repository.upsertOverride(override: candidate), isTrue);
    final saved = await repository.loadOverrides(semesterId: 'term');
    expect(saved.single, candidate);
    expect(saved.single.weekOffset, -1);
    expect(saved.single.replaceSameCourse, isTrue);
    final oldJson = candidate.toJson()
      ..remove('week_offset')
      ..remove('replace_same_course');
    final old = ScheduleOverride.fromJson(oldJson);
    expect(old.weekOffset, 0);
    expect(old.replaceSameCourse, isFalse);
    final reconciled = const MeetingReconciler().reconcile(
      oldBaseSchedule: [_course()],
      newEduCourses: [_course()],
      existingOverrides: saved,
      semesterId: 'term',
    );
    expect(reconciled.updatedOverrides.single, candidate);
    expect(
        const ScheduleResolver()
            .resolve(baseSchedule: [_course()], overrides: [old])
            .firstWhere((r) => r.isOverridden)
            .weeks,
        {9});
  });

  test('目标越界不能落盘，保存失败后可重试，编辑时恢复旧规则的源周', () async {
    final provider = CourseScheduleProvider();
    addTearDown(provider.dispose);
    final base = _course().copyWith(semesterId: provider.currentTerm.id);
    provider.setBaseScheduleForTesting([base]);
    Future<ScheduleOverride> save(
            {int offset = -1, bool merge = true, String? id}) =>
        provider.createRescheduleOverride(
          courseKey: 'course',
          meetingKey: 'meeting',
          affectedWeeks: {9},
          weekOffset: offset,
          replaceSameCourse: merge,
          toWeekday: 1,
          toStartSection: 5,
          toEndSection: 6,
          sourceSnapshotHash: base.meetings.single.computeSnapshotHash(),
          overrideId: id,
        );
    await expectLater(save(offset: -9), throwsStateError);
    expect(provider.overrides, isEmpty);
    final preferences = _FailingPreferences();
    AppPreferencesStore.setCustomInstance(preferences);
    await expectLater(save(), throwsStateError);
    expect(provider.overrides, isEmpty);
    preferences.fail = false;
    final saved = await save();
    expect(provider.courses.where((c) => c.weeks.contains(8)), hasLength(1));
    final preview = provider.previewReschedule(
      courseKey: 'course',
      meetingKey: 'meeting',
      affectedWeeks: {10},
      weekOffset: -1,
      toWeekday: 1,
      toStartSection: 5,
      toEndSection: 6,
      overrideId: saved.id,
    );
    expect(preview.conflicts.single.conflictingWeeks, {9});
    await provider.restoreBaseMeeting(saved.id);
    expect(provider.courses.single.weeks, [8, 9, 10]);
  });

  test('其他课程冲突仍需确认，单独设置合并不能绕过冲突', () async {
    final provider = CourseScheduleProvider();
    addTearDown(provider.dispose);
    provider.setBaseScheduleForTesting([
      _course(weeks: {9}).copyWith(semesterId: provider.currentTerm.id),
      _course(key: 'other').copyWith(semesterId: provider.currentTerm.id),
    ]);
    Future<ScheduleOverride> save(bool allow) =>
        provider.createRescheduleOverride(
          courseKey: 'course',
          meetingKey: 'meeting',
          affectedWeeks: {9},
          weekOffset: -1,
          replaceSameCourse: true,
          allowConflict: allow,
          toWeekday: 1,
          toStartSection: 5,
          toEndSection: 6,
          sourceSnapshotHash: '',
        );
    await expectLater(save(false), throwsStateError);
    expect(provider.overrides, isEmpty);
    expect((await save(true)).status, ScheduleOverrideStatus.conflicted);
    expect(provider.courses.where((c) => c.weeks.contains(8)), hasLength(2));
  });

  test('异步保存前切换账号，拒绝旧操作', () async {
    final provider = CourseScheduleProvider();
    addTearDown(provider.dispose);
    provider.setBaseScheduleForTesting(
        [_course().copyWith(semesterId: provider.currentTerm.id)]);
    final pending = provider.createRescheduleOverride(
      courseKey: 'course',
      meetingKey: 'meeting',
      affectedWeeks: {9},
      weekOffset: -1,
      replaceSameCourse: true,
      toWeekday: 1,
      toStartSection: 5,
      toEndSection: 6,
      sourceSnapshotHash: '',
    );
    provider.clearAllUserState();
    await expectLater(pending, throwsStateError);
    expect(provider.courses, isEmpty);
    expect(provider.overrides, isEmpty);
  });

  test('手动课程校验周次边界，合法课程立即进入课表，源快照变更拒绝旧调课', () async {
    final provider = CourseScheduleProvider();
    addTearDown(provider.dispose);
    provider.setBaseScheduleForTesting(
        [_course().copyWith(semesterId: provider.currentTerm.id)]);
    await expectLater(
        provider.addCustomCourse(
            name: '补课',
            weekday: 1,
            startSection: 5,
            endSection: 6,
            startWeek: 0,
            endWeek: 8),
        throwsStateError);
    expect(provider.manualCourses, isEmpty);
    await provider.addCustomCourse(
        name: '补课',
        weekday: 1,
        startSection: 5,
        endSection: 6,
        startWeek: 8,
        endWeek: 8);
    expect(provider.courses.where((c) => c.name == '补课'), hasLength(1));
    expect(
        provider.courses.firstWhere((c) => c.name == '补课').conflictWeeks, {8});
    await expectLater(
        provider.createRescheduleOverride(
            courseKey: 'course',
            meetingKey: 'meeting',
            affectedWeeks: {9},
            weekOffset: -1,
            toWeekday: 1,
            toStartSection: 5,
            toEndSection: 6,
            sourceSnapshotHash: 'stale-source-hash'),
        throwsStateError);
    expect(provider.overrides, isEmpty);
  });
}
