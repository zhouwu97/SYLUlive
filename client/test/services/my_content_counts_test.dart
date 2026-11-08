import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/course_evaluation.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/services/course_evaluation_service.dart';

Map<String, Object> _review(int id, {bool direct = false}) => {
      'id': id,
      'user_id': 20,
      'course_name': direct ? '气排球文化与健康' : '马克思主义基本原理',
      'teacher_name': direct ? '朱俊' : '周吾诠',
      'teacher_id': direct ? 7 : 8,
      'teacher_rating_id': direct ? id : 9,
      'teacher_rating_status': 'normal',
      'source': direct ? 'legacy_teacher' : 'schedule',
      'status': 'published',
      'star': 5,
      'comment': '本地测试评价',
    };

void main() {
  test('总数取帖子、集市、合并评价三类之和，使用本人认证接口', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        requests.add(o);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'items': [_review(1), _review(2, direct: true)],
          'total': 2,
          'content_counts': {
            'posts': 16,
            'market': 2,
            'evaluations': 2,
            'count': 20
          },
        }));
      }));
    final counts = await CourseEvaluationService(dio)
        .loadContentCounts(20, isCurrent: () => true);
    expect(counts.total, 20);
    expect(requests, hasLength(1));
    expect(requests.single.path, '/user/course-evaluations');
    expect(requests.single.queryParameters['include_teacher_ratings'], 'true');
    expect(requests.single.queryParameters['include_content_counts'], 'true');
    expect(requests.single.queryParameters, isNot(contains('user_id')));
  });

  test('旧服务端兼容读取已有三类内容，不再漏算学科评价', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        requests.add(o);
        final Object data = switch (o.path) {
          '/user/course-evaluations' => {
              'items': [_review(1)],
              'has_more': false,
            },
          '/user/20/posts' => List.generate(16, (i) => {'id': i + 1}),
          '/user/20/market-posts' => {'items': [], 'total': 2},
          _ => throw StateError('Unexpected endpoint ${o.path}'),
        };
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    final counts = await CourseEvaluationService(dio)
        .loadContentCounts(20, isCurrent: () => true);
    expect(counts.total, 19);
    expect(requests.last.queryParameters['post_type'], 'all');
    expect(requests.any((r) => r.path.endsWith('/posts/count')), isFalse);
  });

  test('兼容统计继续读取完整评价游标与帖子分页', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        requests.add(o);
        final Object data;
        if (o.path == '/user/course-evaluations') {
          final next = o.queryParameters['cursor'] == '99';
          data = {
            'items': [_review(next ? 2 : 1)],
            'has_more': !next,
            'next_cursor': next ? '' : '99'
          };
        } else if (o.path.endsWith('/market-posts')) {
          data = {'items': [], 'total': 2};
        } else {
          data = List.generate(
              o.queryParameters['page'] == 1 ? 50 : 1, (i) => {'id': i});
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    final counts = await CourseEvaluationService(dio)
        .loadContentCounts(20, isCurrent: () => true);
    expect(counts.total, 55);
    expect(requests.where((o) => o.path == '/user/course-evaluations'),
        hasLength(2));
    expect(requests.where((o) => o.path == '/user/20/posts'), hasLength(2));
  });

  test('分页游标重复会报告失败，不死循环或返回缺项总数', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'items': [_review(1)],
          'has_more': true,
          'next_cursor': 'same',
        }));
      }));
    await expectLater(
        CourseEvaluationService(dio)
            .loadContentCounts(20, isCurrent: () => true),
        throwsA(isA<CourseEvaluationException>()));
  });

  test('切换账号后不延续旧统计分页', () async {
    var current = true;
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls++;
        current = false;
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'items': [_review(1)],
          'has_more': true,
          'next_cursor': '99',
        }));
      }));
    await expectLater(
        CourseEvaluationService(dio)
            .loadContentCounts(20, isCurrent: () => current),
        throwsA(isA<CourseEvaluationException>()));
    expect(calls, 1);
  });

  test('历史与课表评价使用同一主记录索引', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'items': [_review(1), _review(2, direct: true)],
          'total': 25,
          'has_more': true,
          'next_cursor': 'next',
        }));
      }));
    final provider = CourseEvaluationProvider(dio)..syncSessionUser(20);
    addTearDown(provider.dispose);
    await provider.loadMine(refresh: true);
    expect(
        provider.mine.map((r) => r.recordKey), ['submission:1', 'submission:2']);
    expect(provider.mineTotal, 25, reason: '页签显示总数，不能仅显示首批加载数量');
    expect(provider.submissionById(1)!.source, 'schedule');
    expect(provider.submissionById(2)!.source, 'legacy_teacher');
  });

  test('服务端升级导致游标失效时重新读取合并后的首页', () async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls++;
        if (o.queryParameters.containsKey('cursor')) {
          h.reject(DioException(
              requestOptions: o,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: o, statusCode: 400, data: {
                'code': 'invalid_course_evaluation_input',
                'error': '无效的分页游标',
              })));
          return;
        }
        h.resolve(Response(
            requestOptions: o,
            statusCode: 200,
            data: calls == 1
                ? {
                    'items': [_review(1)],
                    'has_more': true,
                    'next_cursor': '99'
                  }
                : {
                    'items': [_review(1), _review(2, direct: true)],
                    'total': 2,
                    'has_more': false
                  }));
      }));
    final provider = CourseEvaluationProvider(dio)..syncSessionUser(20);
    addTearDown(provider.dispose);
    await provider.loadMine(refresh: true);
    await provider.loadMoreMine();
    expect(provider.mine, hasLength(2));
    expect(provider.mineTotal, 2);
    expect(provider.mineHasMore, isFalse);
    expect(calls, 3);
  });

  test('旧账号合并评价晚返回不能恢复其列表或总数', () async {
    final gate = Completer<void>();
    var old = true;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
        final wasOld = old;
        if (wasOld) await gate.future;
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'items': [_review(wasOld ? 1 : 2, direct: wasOld)],
          'total': wasOld ? 99 : 1,
          'has_more': false,
        }));
      }));
    final provider = CourseEvaluationProvider(dio)..syncSessionUser(20);
    addTearDown(provider.dispose);
    final pending = provider.loadMine(refresh: true);
    await Future<void>.delayed(Duration.zero);
    provider.syncSessionUser(21);
    old = false;
    await provider.loadMine(refresh: true);
    gate.complete();
    await pending;
    expect(provider.mine.single.id, 2);
    expect(provider.mineTotal, 1);
  });
}
