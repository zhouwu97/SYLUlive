import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import 'package:shenliyuan/models/course_evaluation.dart';
import 'package:shenliyuan/models/teacher.dart';
import 'package:shenliyuan/models/teacher_governance.dart';
import 'package:shenliyuan/screens/teacher_detail_screen.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

class _FakeTeacherProvider extends ChangeNotifier implements TeacherProvider {
  final Map<int, TeacherDetailState> _states = {};

  void setDetail(int teacherId, TeacherDetailState state) {
    _states[teacherId] = state;
    notifyListeners();
  }

  @override
  TeacherDetailState detailOf(int teacherId) {
    return _states[teacherId] ?? TeacherDetailState();
  }

  @override
  Future<void> loadTeacherDetail(int teacherId, {bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('教师与课程治理客户端模型测试', () {
    test('CourseEvaluationStatus 支持 superseded 状态且不可编辑', () {
      expect(courseEvaluationStatusFromString('superseded'),
          CourseEvaluationStatus.superseded);
      expect(courseEvaluationStatusToString(CourseEvaluationStatus.superseded),
          'superseded');
      expect(CourseEvaluationStatus.superseded.label, '已合并');
      expect(CourseEvaluationStatus.superseded.editable, false);
      expect(CourseEvaluationStatus.published.editable, true);
    });

    test('CourseEvaluationSubmission 解析 superseded 关联字段', () {
      final json = {
        'id': 101,
        'course_name': '高数',
        'status': 'superseded',
        'superseded_by_submission_id': 99,
        'superseded_reason': 'teacher_merge_duplicate',
      };
      final submission = CourseEvaluationSubmission.fromJson(json);
      expect(submission.id, 101);
      expect(submission.status, CourseEvaluationStatus.superseded);
      expect(submission.supersededBySubmissionId, 99);
      expect(submission.supersededReason, 'teacher_merge_duplicate');
    });

    test('Teacher 模型正确解析治理字段与合并标记', () {
      final json = {
        'id': 20,
        'name': '张三老师',
        'course': '高等数学',
        'merged': true,
        'merged_into_id': 18,
        'merged_into_name': '张三',
        'canonical_source': 'legacy',
        'verified': true,
      };
      final t = Teacher.fromJson(json);
      expect(t.id, 20);
      expect(t.isMerged, true);
      expect(t.mergedIntoId, 18);
      expect(t.mergedIntoName, '张三');
      expect(t.canonicalSource, 'legacy');
      expect(t.verified, true);
    });

    test('TeacherGovernanceCandidateGroup 解析候选分组与置信度', () {
      final json = {
        'id': 'group-1',
        'course_name': '高等数学',
        'confidence': 'high',
        'reasons': ['名称去除老师后缀后一致'],
        'merge_allowed': true,
        'suggested_keeper_id': 18,
        'teachers': [
          {
            'id': 18,
            'name': '张三',
            'course': '高等数学',
            'canonical_source': 'edu_schedule',
            'verified': true,
            'rating_count': 10,
          },
          {
            'id': 21,
            'name': '张三老师',
            'course': '高等数学',
            'canonical_source': 'legacy',
            'verified': false,
            'rating_count': 2,
          }
        ],
      };
      final group = TeacherGovernanceCandidateGroup.fromJson(json);
      expect(group.id, 'group-1');
      expect(group.confidence, GovernanceConfidence.high);
      expect(group.confidence.label, '高置信');
      expect(group.mergeAllowed, true);
      expect(group.teachers.length, 2);
      expect(group.teachers.first.name, '张三');
    });

    test('GovernanceMergePreviewResult 正确解析冲突与指标统计', () {
      final json = {
        'keeper': {'id': 18, 'name': '张三'},
        'loser_ids': [21, 22],
        'snapshot_token': 'test-token-123',
        'merge_allowed': true,
        'ratings_migrated': 12,
        'ratings_soft_deleted': 2,
        'votes_migrated': 25,
        'submissions_superseded': 2,
        'rating_conflict_details': [
          {
            'user_id': 5,
            'user_nickname': '同学A',
            'winner_rating_id': 88,
          }
        ],
      };
      final preview = GovernanceMergePreviewResult.fromJson(json);
      expect(preview.keeperId, 18);
      expect(preview.keeperName, '张三');
      expect(preview.loserIds, [21, 22]);
      expect(preview.snapshotToken, 'test-token-123');
      expect(preview.ratingsMigrated, 12);
      expect(preview.ratingsSoftDeleted, 2);
      expect(preview.ratingConflicts.length, 1);
      expect(preview.ratingConflicts.first.userNickname, '同学A');
    });
  });

  group('TeacherDetailScreen 合并重定向测试', () {
    testWidgets('已合并教师展示提示与跳转保护', (tester) async {
      final fakeTeacherProvider = _FakeTeacherProvider();
      final authProvider = AuthProvider(Dio());
      final themeProvider = ThemeProvider();

      fakeTeacherProvider.setDetail(
        21,
        TeacherDetailState(
          isLoading: false,
          teacher: Teacher(
            id: 21,
            name: '张三老师',
            course: '高等数学',
            isMerged: true,
            mergedIntoId: 18,
            mergedIntoName: '张三',
            createdAt: DateTime.now(),
          ),
        ),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<TeacherProvider>.value(
              value: fakeTeacherProvider,
            ),
            ChangeNotifierProvider<AuthProvider>.value(
              value: authProvider,
            ),
            ChangeNotifierProvider<ThemeProvider>.value(
              value: themeProvider,
            ),
          ],
          child: const MaterialApp(
            home: TeacherDetailScreen(
              teacherId: 21,
              teacherName: '张三老师',
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.textContaining('正在跳转到最新资料'), findsNWidgets(2));
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });
}
