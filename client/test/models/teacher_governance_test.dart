import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/teacher_governance.dart';

void main() {
  group('GovernanceApiErrorMapper', () {
    test('正确映射 401 未登录状态', () {
      final dioErr = DioException(
        requestOptions: RequestOptions(path: '/api/admin/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/admin/test'),
          statusCode: 401,
        ),
      );
      expect(GovernanceApiErrorMapper.format(dioErr), '登录状态已失效，请重新登录');
    });

    test('正确映射 403 无权限状态', () {
      final dioErr = DioException(
        requestOptions: RequestOptions(path: '/api/admin/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/admin/test'),
          statusCode: 403,
        ),
      );
      expect(GovernanceApiErrorMapper.format(dioErr), '当前账号没有治理权限');
    });

    test('正确映射 404 服务端未提供治理功能', () {
      final dioErr = DioException(
        requestOptions: RequestOptions(path: '/api/admin/teacher-governance/teachers'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/admin/teacher-governance/teachers'),
          statusCode: 404,
        ),
      );
      expect(
        GovernanceApiErrorMapper.format(dioErr),
        '当前服务端暂未提供该治理功能（请确认服务端已升级）',
      );
    });

    test('正确展示 409 后端稳定业务错误信息', () {
      final dioErr = DioException(
        requestOptions: RequestOptions(path: '/api/admin/teacher-governance/merge'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/admin/teacher-governance/merge'),
          statusCode: 409,
          data: {'error': '数据快照已过期，请刷新后重试', 'code': 'GOVERNANCE_SNAPSHOT_STALE'},
        ),
      );
      expect(GovernanceApiErrorMapper.format(dioErr), '数据快照已过期，请刷新后重试');
    });

    test('正确映射网络连接超时异常', () {
      final dioErr = DioException(
        requestOptions: RequestOptions(path: '/api/admin/test'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(
        GovernanceApiErrorMapper.format(dioErr),
        '网络连接超时或不可达，请检查网络连接',
      );
    });

    test('非 Dio 异常使用 fallback 提示', () {
      expect(
        GovernanceApiErrorMapper.format(Exception('未知异常'), fallback: '操作失败'),
        '操作失败',
      );
    });
  });

  group('ServerCapabilities', () {
    test('正确解析具备治理能力的服务端响应', () {
      final json = {
        'status': 'ok',
        'git_sha': 'abcdef123',
        'build_time': '2026-09-17T09:00:00Z',
        'api_version': 'v1',
        'capabilities': {
          'teacher_governance_v1': true,
        },
      };
      final caps = ServerCapabilities.fromJson(json);
      expect(caps.teacherGovernanceV1, isTrue);
      expect(caps.gitSha, 'abcdef123');
      expect(caps.buildTime, '2026-09-17T09:00:00Z');
      expect(caps.apiVersion, 'v1');
    });

    test('旧版本服务端 capabilities 缺失时安全识别为 false', () {
      final json = {
        'status': 'ok',
      };
      final caps = ServerCapabilities.fromJson(json);
      expect(caps.teacherGovernanceV1, isFalse);
      expect(caps.gitSha, '');
    });
  });

  group('GovernancePageResult & Items', () {
    test('正确解析教师治理项及分页字段', () {
      final itemJson = {
        'id': 101,
        'name': '李老师',
        'course': '计算机网络',
        'course_subject_id': 20,
        'course_subject_name': '网络工程基础',
        'subject_verified': true,
        'verified': true,
        'rating_count': 15,
        'pending_submission_count': 3,
        'alias_count': 2,
      };
      final teacher = TeacherGovernanceTeacherItem.fromJson(itemJson);
      expect(teacher.id, 101);
      expect(teacher.name, '李老师');
      expect(teacher.subjectId, 20);
      expect(teacher.ratingCount, 15);
      expect(teacher.pendingCount, 3);
      expect(teacher.aliasCount, 2);
      expect(teacher.isMerged, isFalse);

      final page = GovernancePageResult<TeacherGovernanceTeacherItem>(
        items: [teacher],
        hasMore: true,
        nextCursor: 101,
      );
      expect(page.items.length, 1);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 101);
    });
  });
}
