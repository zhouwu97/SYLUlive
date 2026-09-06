import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/course_evaluation.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';

class _CourseEvaluationAdapter implements HttpClientAdapter {
  final String refreshedStatus;
  int resolveCalls = 0;

  _CourseEvaluationAdapter({this.refreshedStatus = 'pending'});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (options.method == 'GET' && options.path == '/course-subjects/resolve') {
      resolveCalls++;
      return _json(<String, Object?>{
        'course_name': '体育',
        'teacher_name': '朱俊',
        'course_subjects': <Object>[],
        'teachers': <Object>[],
        'requires_confirmation': resolveCalls == 1,
        if (resolveCalls > 1)
          'submission': <String, Object?>{
            ..._pendingSubmission,
            'status': refreshedStatus,
          },
      });
    }
    if (options.method == 'POST' && options.path == '/course-evaluations') {
      return _json(_pendingSubmission);
    }
    throw StateError('未配置请求：${options.method} ${options.path}');
  }

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Object? body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
}

const Map<String, Object?> _pendingSubmission = <String, Object?>{
  'id': 7,
  'user_id': 1,
  'course_name': '体育',
  'teacher_name': '朱俊',
  'star': 5,
  'comment': '测试评价',
  'status': 'pending',
  'source': 'schedule',
  'revision': 1,
  'proposed_course_name': '体育',
  'proposed_teacher_name': '朱俊',
  'will_create_subject': true,
};

void main() {
  test('提交使用 canonical 名称时会失效原课表名称对应的解析缓存', () async {
    final adapter = _CourseEvaluationAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter;
    final provider = CourseEvaluationProvider(dio)..syncSessionUser(1);

    final before = await provider.resolveForCourse('体育5', '朱俊');
    expect(before?.submission, isNull);
    expect(adapter.resolveCalls, 1);

    final submitted = await provider.submit(
      courseName: '体育',
      teacherName: '朱俊',
      star: 5,
      comment: '测试评价',
    );
    expect(submitted?.status, CourseEvaluationStatus.pending);

    final after = await provider.resolveForCourse('体育5', '朱俊');
    expect(adapter.resolveCalls, 2);
    expect(after?.submission?.id, 7);
    expect(after?.submission?.status, CourseEvaluationStatus.pending);
  });

  test('refresh 会绕过缓存读取管理员审核后的最新状态', () async {
    final adapter = _CourseEvaluationAdapter(refreshedStatus: 'published');
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter;
    final provider = CourseEvaluationProvider(dio)..syncSessionUser(1);

    await provider.resolveForCourse('体育', '朱俊');
    final refreshed = await provider.resolveForCourse(
      '体育',
      '朱俊',
      refresh: true,
    );

    expect(adapter.resolveCalls, 2);
    expect(refreshed?.submission?.status, CourseEvaluationStatus.published);
  });
}
