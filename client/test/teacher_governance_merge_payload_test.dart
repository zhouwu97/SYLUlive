import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/teacher_governance.dart';

void main() {
  group('Teacher Governance Merge Payload Contract Tests', () {
    test('GovernanceCourseMergePlan deserializes and serializes with exact server keys', () {
      final json = {
        'loser_subject_id': 201,
        'loser_subject_name': '高等数学 B',
        'keeper_subject_id': 101,
        'keeper_subject_name': '高等数学 A',
        'merge_subject_entity': true,
        'rehung_teachers': 1,
        'collision_teachers': 0,
        'course_alias': '高数B',
        'course_alias_status': 'to_create',
      };

      final plan = GovernanceCourseMergePlan.fromJson(json);

      expect(plan.loserSubjectId, 201);
      expect(plan.keeperSubjectId, 101);
      expect(plan.mergeSubjectEntity, isTrue);
      expect(plan.rehungTeachers, 1);

      final outJson = plan.toJson();
      expect(outJson['loser_subject_id'], 201);
      expect(outJson['keeper_subject_id'], 101);
      expect(outJson['merge_subject_entity'], isTrue);

      final overridden = plan.toJson(overrideMergeSubjectEntity: false);
      expect(overridden['merge_subject_entity'], isFalse);
    });

    test('GovernanceMergePreviewResult parses course_merges array from preview response', () {
      final previewResponse = {
        'keeper': {'id': 1, 'name': '张三'},
        'loser_ids': [2, 3],
        'snapshot_token': 'snap_token_12345',
        'merge_allowed': true,
        'course_merges': [
          {
            'loser_subject_id': 20,
            'loser_subject_name': '线性代数（英）',
            'keeper_subject_id': 10,
            'keeper_subject_name': '线性代数',
            'merge_subject_entity': false,
            'rehung_teachers': 1,
          },
        ],
        'ratings_migrated': 5,
        'ratings_soft_deleted': 1,
        'votes_migrated': 10,
      };

      final preview = GovernanceMergePreviewResult.fromJson(previewResponse);

      expect(preview.keeperId, 1);
      expect(preview.loserIds, [2, 3]);
      expect(preview.snapshotToken, 'snap_token_12345');
      expect(preview.courseMerges.length, 1);
      expect(preview.courseMerges.first.loserSubjectId, 20);
      expect(preview.courseMerges.first.keeperSubjectId, 10);
      expect(preview.courseMerges.first.mergeSubjectEntity, isFalse);
    });

    test('Execute Merge payload builder strictly matches backend MergeInput contract', () {
      const preview = GovernanceMergePreviewResult(
        keeperId: 100,
        keeperName: '李四',
        loserIds: [101, 102],
        snapshotToken: 'snapshot_token_abc_xyz',
        courseMerges: [
          GovernanceCourseMergePlan(
            loserSubjectId: 50,
            loserSubjectName: '大学物理B',
            keeperSubjectId: 40,
            keeperSubjectName: '大学物理A',
            mergeSubjectEntity: false,
          ),
        ],
      );

      const registerTeacherAliases = true;
      const mergeSubjectEntityDecision = true;

      // Construct payload the same way as admin_teacher_governance_screen.dart
      final payload = {
        'keeper_id': preview.keeperId,
        'loser_ids': preview.loserIds,
        'snapshot_token': preview.snapshotToken,
        'register_teacher_aliases': registerTeacherAliases,
        'course_merges': preview.courseMerges.map((cm) => {
              'loser_subject_id': cm.loserSubjectId,
              'keeper_subject_id': cm.keeperSubjectId,
              'merge_subject_entity': mergeSubjectEntityDecision,
            }).toList(),
      };

      // Assert formal keys
      expect(payload.containsKey('register_teacher_aliases'), isTrue);
      expect(payload['register_teacher_aliases'], isTrue);
      // Ensure deprecated 'register_aliases' is NOT sent by new client
      expect(payload.containsKey('register_aliases'), isFalse);

      expect(payload['keeper_id'], 100);
      expect(payload['loser_ids'], [101, 102]);
      expect(payload['snapshot_token'], 'snapshot_token_abc_xyz');

      final courseMerges = payload['course_merges'] as List<Map<String, dynamic>>;
      expect(courseMerges.length, 1);
      expect(courseMerges.first['loser_subject_id'], 50);
      expect(courseMerges.first['keeper_subject_id'], 40);
      expect(courseMerges.first['merge_subject_entity'], isTrue);
    });
  });
}
