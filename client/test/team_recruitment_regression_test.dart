import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/team_recruitment_provider.dart';
import 'package:shenliyuan/screens/team/team_recruitment_center_screen.dart';
import 'package:shenliyuan/services/team_recruitment_service.dart';
import 'package:shenliyuan/widgets/team/team_application_sheet.dart';

void main() {
  testWidgets('申请说明不足五个字时显示校验原因', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TeamRecruitmentApplicationSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '我不会');
    await tester.tap(find.text('提交申请'));
    await tester.pump();

    expect(find.text('申请说明至少 5 个字'), findsOneWidget);
    expect(find.text('申请加入'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态筛选切换过程中始终只有一个选中底色', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: const {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'page': 1,
          'has_more': false,
        },
      ));
    }));

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AuthProvider(Dio())),
        ChangeNotifierProvider.value(value: TeamRecruitmentProvider(dio)),
      ],
      child: const MaterialApp(home: TeamRecruitmentCenterScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('已满员'));
    await tester.pump(const Duration(milliseconds: 80));

    expect(
      find.byKey(const ValueKey('team-status-selected-indicator')),
      findsOneWidget,
    );
  });

  test('编辑后读取服务端权威招募，并区分保留与清空图片', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    final requests = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      if (options.method == 'PATCH') {
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: const {'message': '更新成功'},
        ));
        return;
      }
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: _recruitmentJson(id: 7, title: '更新后的组队'),
      ));
    }));
    final service = TeamRecruitmentService(dio);

    final updated = await service.update(
      recruitmentId: 7,
      category: 'competition',
      title: '更新后的组队',
      description: '更新后的组队说明内容',
      neededCount: 2,
      roles: const ['建模'],
      imageFileIds: null,
    );

    expect(updated.id, 7);
    expect(updated.title, '更新后的组队');
    expect(updated.images.single.fileId, 23);
    expect(requests.map((item) => item.method), ['PATCH', 'GET']);
    expect((requests.first.data as Map).containsKey('image_file_ids'), isFalse);

    requests.clear();
    await service.update(
      recruitmentId: 7,
      category: 'competition',
      title: '更新后的组队',
      description: '更新后的组队说明内容',
      neededCount: 2,
      roles: const ['建模'],
      imageFileIds: const [],
    );
    expect((requests.first.data as Map)['image_file_ids'], isEmpty);
  });

  test('加载更多期间切换筛选会立即复位分页状态', () async {
    final loadMoreGate = Completer<void>();
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      final page = options.queryParameters['page'];
      if (page == 2) await loadMoreGate.future;
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: {
          'items': page == 1 && options.queryParameters['category'] == null
              ? [_recruitmentJson(id: 7, title: '第一页')]
              : <Map<String, dynamic>>[],
          'total': page == 1 ? 21 : 0,
          'page': page,
          'has_more': page == 1,
        },
      ));
    }));
    final provider = TeamRecruitmentProvider(dio);

    await provider.loadPublic();
    final loadingMore = provider.loadMorePublic();
    await Future<void>.delayed(Duration.zero);
    expect(provider.isLoadingMore, isTrue);

    await provider.loadPublic(category: 'study');
    expect(provider.isLoadingMore, isFalse);

    loadMoreGate.complete();
    await loadingMore;
  });

  test('切换账号会清空账号相关缓存并丢弃旧请求结果', () async {
    final mineGate = Completer<void>();
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.contains('/team/recruitments/mine')) {
        await mineGate.future;
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'items': [_recruitmentJson(id: 8, title: '账号 A 的组队')],
          },
        ));
        return;
      }
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: const <Map<String, dynamic>>[],
      ));
    }));
    final provider = TeamRecruitmentProvider(dio);

    provider.syncSessionUser(1);
    final loading = provider.loadMine();
    await Future<void>.delayed(Duration.zero);
    provider.syncSessionUser(2);

    expect(provider.myCreated, isEmpty);
    expect(provider.myApplications, isEmpty);
    expect(provider.isLoadingMine, isFalse);

    mineGate.complete();
    await loading;
    expect(provider.myCreated, isEmpty);
  });

  test('切换账号后丢弃旧账号的详情和申请列表响应', () async {
    final detailGate = Completer<void>();
    final applicationsGate = Completer<void>();
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.endsWith('/team/recruitments/7')) {
        await detailGate.future;
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: _recruitmentJson(id: 7, title: '账号 A 的详情'),
        ));
        return;
      }
      if (options.path.endsWith('/team/recruitments/7/applications')) {
        await applicationsGate.future;
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: [
            {
              'id': 9,
              'recruitment_id': 7,
              'post_id': 11,
              'applicant_id': 3,
              'owner_id': 1,
              'message': '账号 A 的申请记录',
              'availability': '',
              'status': 'pending',
              'created_at': '2026-07-12T00:00:00Z',
              'updated_at': '2026-07-12T00:00:00Z',
            }
          ],
        ));
        return;
      }
      handler.reject(DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
      ));
    }));
    final provider = TeamRecruitmentProvider(dio);

    provider.syncSessionUser(1);
    final detail = provider.loadDetail(7);
    final applications = provider.loadApplications(7);
    await Future<void>.delayed(Duration.zero);
    provider.syncSessionUser(2);
    detailGate.complete();
    applicationsGate.complete();

    expect(await detail, isNull);
    await applications;
    expect(provider.publicItems, isEmpty);
    expect(provider.applicationsFor(7), isEmpty);
  });

  testWidgets('会话版本变化后组队大厅自动重新加载', (tester) async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requestCount++;
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: const {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'page': 1,
          'has_more': false,
        },
      ));
    }));
    final provider = TeamRecruitmentProvider(dio);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AuthProvider(Dio())),
        ChangeNotifierProvider.value(value: provider),
      ],
      child: const MaterialApp(home: TeamRecruitmentCenterScreen()),
    ));
    await tester.pumpAndSettle();
    expect(requestCount, 1);

    provider.syncSessionUser(2);
    await tester.pumpAndSettle();
    expect(requestCount, 2);
  });

  test('旧账号操作结束时不会清除新账号的同项进行中状态', () async {
    final oldGate = Completer<void>();
    final newGate = Completer<void>();
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requestCount++;
      await (requestCount == 1 ? oldGate.future : newGate.future);
      handler.resolve(Response<dynamic>(
        requestOptions: options,
        statusCode: 201,
        data: {
          'id': requestCount,
          'recruitment_id': 7,
          'post_id': 11,
          'applicant_id': requestCount,
          'owner_id': 1,
          'message': '有效的申请留言',
          'availability': '',
          'status': 'pending',
          'created_at': '2026-07-12T00:00:00Z',
          'updated_at': '2026-07-12T00:00:00Z',
        },
      ));
    }));
    final provider = TeamRecruitmentProvider(dio);

    provider.syncSessionUser(1);
    final oldRequest = provider.apply(
      recruitmentId: 7,
      message: '账号 A 的有效申请留言',
    );
    await Future<void>.delayed(Duration.zero);
    provider.syncSessionUser(2);
    final newRequest = provider.apply(
      recruitmentId: 7,
      message: '账号 B 的有效申请留言',
    );
    await Future<void>.delayed(Duration.zero);

    oldGate.complete();
    expect(await oldRequest, '登录状态已变化，请重试');
    expect(provider.applyingIds, contains(7));

    newGate.complete();
    expect(await newRequest, isNull);
    expect(provider.applyingIds, isNot(contains(7)));
  });
}

Map<String, dynamic> _recruitmentJson(
    {required int id, required String title}) {
  return {
    'id': id,
    'post_id': 11,
    'category': 'competition',
    'title': title,
    'description': '更新后的组队说明内容',
    'author': {'id': 1, 'name': '队长'},
    'images': <Map<String, dynamic>>[
      {'id': 17, 'file_id': 23, 'url': '/uploads/team.png'},
    ],
    'needed_count': 2,
    'accepted_count': 1,
    'remaining_count': 1,
    'roles': ['建模'],
    'status': 'recruiting',
    'effective_status': 'recruiting',
    'created_at': '2026-07-12T00:00:00Z',
    'updated_at': '2026-07-12T00:00:00Z',
  };
}
