import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/teacher_governance.dart';

void main() {
  group('Course & Teacher Governance Unit Tests', () {
    test('CourseMergePreviewResult deserializes and exposes impact getters', () {
      final json = {
        'snapshot_token': 'test-snapshot-token-xyz',
        'merge_allowed': true,
        'final_course_name': '高等数学A1',
        'keeper_subject': {
          'id': 101,
          'name': '高等数学A1',
          'teacher_count': 5,
          'rating_count': 42,
        },
        'loser_subjects': [
          {
            'id': 202,
            'name': '高数（上）',
            'teacher_count': 2,
            'rating_count': 18,
          }
        ],
        'migrating_teachers': [
          {
            'teacher_id': 15,
            'teacher_name': '李四',
            'from_subject': '高数（上）',
            'to_subject': '高等数学A1',
            'rating_count': 8,
          }
        ],
        'paired_teacher_merges': [
          {
            'loser_teacher_id': 12,
            'loser_teacher_name': '张老师',
            'keeper_teacher_id': 10,
            'keeper_teacher_name': '张三',
            'final_teacher_name': '张三',
            'migrated_ratings': 10,
            'soft_deleted_ratings': 2,
            'migrated_votes': 15,
          }
        ],
        'total_ratings_migrating': 18,
        'total_ratings_deduped': 2,
        'total_votes_migrating': 15,
        'total_submissions_relinked': 3,
        'course_aliases_to_create': ['高数（上）'],
        'conflicts': ['发现 2 组用户同时评价过合并目标与候选'],
      };

      final result = CourseMergePreviewResult.fromJson(json);

      expect(result.snapshotToken, 'test-snapshot-token-xyz');
      expect(result.mergeAllowed, isTrue);
      expect(result.finalCourseName, '高等数学A1');
      expect(result.keeperSubject.id, 101);
      expect(result.loserSubjects.length, 1);
      expect(result.loserSubjects.first.id, 202);
      expect(result.migratingTeachers.length, 1);
      expect(result.migratingTeachers.first.teacherName, '李四');
      expect(result.pairedTeacherMerges.length, 1);
      expect(result.pairedTeacherMerges.first.finalTeacherName, '张三');

      // Helper getters
      expect(result.ratingsMigrated, 18);
      expect(result.ratingsSoftDeleted, 2);
      expect(result.votesMigrated, 15);
      expect(result.submissionsSuperseded, 3);
      expect(result.courseAliasesAdded, 1);
      expect(result.teacherAliasesAdded, 1);
      expect(result.ratingConflicts.length, 1);
    });

    test('GovernanceCourseItem parses isMerged and mergedIntoId accurately', () {
      final activeJson = {
        'id': 10,
        'name': '大学物理',
        'teacher_count': 3,
        'rating_count': 20,
        'is_merged': false,
      };
      final activeCourse = GovernanceCourseItem.fromJson(activeJson);
      expect(activeCourse.id, 10);
      expect(activeCourse.name, '大学物理');
      expect(activeCourse.isMerged, isFalse);
      expect(activeCourse.mergedIntoId, isNull);

      final mergedJson = {
        'id': 20,
        'name': '大物',
        'teacher_count': 0,
        'rating_count': 0,
        'is_merged': true,
        'merged_into_id': 10,
      };
      final mergedCourse = GovernanceCourseItem.fromJson(mergedJson);
      expect(mergedCourse.id, 20);
      expect(mergedCourse.isMerged, isTrue);
      expect(mergedCourse.mergedIntoId, 10);
    });

    test('Cross-search teacher selection retention pattern prevents data loss', () {
      // Simulation of the Map<int, TeacherGovernanceTeacherItem> selection store
      final selectedMap = <int, TeacherGovernanceTeacherItem>{};

      // Search 1: "张" -> found Teacher #1
      const teacher1 = TeacherGovernanceTeacherItem(
        id: 1,
        name: '张老师',
        course: '高等数学',
        subjectName: '高等数学',
        subjectId: 101,
      );
      selectedMap[teacher1.id] = teacher1;

      // Search 2: "李" -> found Teacher #2
      // The current view displays only Teacher #2, but Teacher #1 must not be lost!
      const teacher2 = TeacherGovernanceTeacherItem(
        id: 2,
        name: '李四',
        course: '高等数学',
        subjectName: '高等数学',
        subjectId: 101,
      );
      selectedMap[teacher2.id] = teacher2;

      // When opening merge sheet, all selected teachers across searches are preserved
      final listForMerge = selectedMap.values.toList();
      expect(listForMerge.length, 2);
      expect(listForMerge.map((t) => t.id).toSet(), {1, 2});
      expect(listForMerge.map((t) => t.name).toSet(), {'张老师', '李四'});
    });
  });
}
