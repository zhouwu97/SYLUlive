import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/team_recruitment_provider.dart';
import 'package:shenliyuan/screens/team/team_recruitment_center_screen.dart';
import 'package:shenliyuan/services/team_recruitment_service.dart';

void main() {
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
