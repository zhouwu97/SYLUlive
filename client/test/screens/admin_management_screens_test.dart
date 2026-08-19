import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_announcements_screen.dart';
import 'package:shenliyuan/screens/admin_candidates_screen.dart';
import 'package:shenliyuan/screens/admin_members_screen.dart';
import 'package:shenliyuan/screens/admin_review_tasks_screen.dart';

class _RouteJsonAdapter implements HttpClientAdapter {
  final Map<String, Object> responses;

  const _RouteJsonAdapter(this.responses);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final payload = responses[options.uri.path];
    if (payload == null) {
      return _notFound();
    }
    final resolved = payload is Object? Function(RequestOptions)
        ? payload(options)
        : payload;
    if (resolved == null) {
      return _notFound();
    }
    return ResponseBody.fromString(
      jsonEncode(resolved),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  ResponseBody _notFound() {
    return ResponseBody.fromString(
      jsonEncode({'error': 'not found'}),
      404,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Widget _buildApp(Widget home, Map<String, Object> responses) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = _RouteJsonAdapter(responses);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: AuthProvider(dio, loadStoredAuth: false),
      ),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ],
    child: MaterialApp(home: home),
  );
}

void main() {
  testWidgets('管理员接口返回六条时页面显示六名管理人员', (tester) async {
    final members = List.generate(
      6,
      (index) => {
        'id': index + 1,
        'nickname': '管理员${index + 1}',
        'student_id': 'admin-${index + 1}',
        'role': index == 0 ? 'super_admin' : 'admin',
        'avatar': '',
      },
    );

    await tester.pumpWidget(
      _buildApp(
        const AdminMembersScreen(),
        {'/admin/members': members},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前共 6 名管理人员'), findsOneWidget);
    expect(find.text('暂无管理人员'), findsNothing);
  });

  testWidgets('候选人页面显示用户 ID 与接口返回的学号账号', (tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _buildApp(
        const AdminCandidatesScreen(),
        {
          '/admin/candidates/stats': {
            'total': 113,
            'edu': 103,
            'other': 10,
            'eligible': 2,
          },
          '/admin/candidates': {
            'items': [
              {
                'id': 7,
                'nickname': '候选人',
                'student_id': '2026000007',
                'role': 'user',
                'avatar': null,
              },
            ],
            'total': 1,
            'page': 1,
            'page_size': 20,
            'has_more': false,
          },
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('用户 ID：7'), findsOneWidget);
    expect(find.text('学号/账号：2026000007'), findsOneWidget);
    expect(find.text('学号/账号：未填写'), findsNothing);
    expect(find.text('符合邀请条件'), findsOneWidget);
    expect(find.text('2 人'), findsOneWidget);
  });

  testWidgets('候选人列表可以滚动到最后一条且不被底部安全区遮挡', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final candidates = List.generate(
      18,
      (index) => {
        'id': index + 1,
        'nickname': '候选人${index + 1}',
        'student_id': '20260000${(index + 1).toString().padLeft(3, '0')}',
        'role': 'user',
        'avatar': null,
      },
    );

    await tester.pumpWidget(
      _buildApp(
        const AdminCandidatesScreen(),
        {
          '/admin/candidates/stats': {
            'total': 133,
            'edu': 106,
            'other': 27,
            'eligible': 18,
          },
          '/admin/candidates': {
            'items': candidates,
            'total': 18,
            'page': 1,
            'page_size': 20,
            'has_more': false,
          },
        },
      ),
    );
    await tester.pumpAndSettle();

    final lastAccount = find.text('学号/账号：20260000018');
    await tester.scrollUntilVisible(
      lastAccount,
      500,
      scrollable: find.byType(Scrollable).last,
    );

    expect(lastAccount, findsOneWidget);
    expect(find.text('候选人18'), findsOneWidget);
  });

  testWidgets('候选人页面在大字号与深色主题下不发生布局异常', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _buildApp(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Theme(
            data: ThemeData.dark(),
            child: const AdminCandidatesScreen(),
          ),
        ),
        {
          '/admin/candidates/stats': {
            'total': 133,
            'edu': 106,
            'other': 27,
            'eligible': 2,
          },
          '/admin/candidates': {
            'items': [
              {
                'id': 7,
                'nickname': '候选人',
                'student_id': '2026000007',
                'role': 'user',
                'avatar': null,
              },
            ],
            'total': 1,
            'page': 1,
            'page_size': 20,
            'has_more': false,
          },
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('用户 ID：7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('候选人列表滚动到底部自动加载下一页', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Object? candidatesResponse(RequestOptions options) {
      final page =
          int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
      if (page == 1) {
        return {
          'items': List.generate(
            20,
            (index) => {
              'id': index + 1,
              'nickname': '候选人${index + 1}',
              'student_id':
                  '2026000${(index + 1).toString().padLeft(3, '0')}',
              'role': 'user',
              'avatar': null,
            },
          ),
          'total': 25,
          'page': 1,
          'page_size': 20,
          'has_more': true,
        };
      }
      return {
        'items': List.generate(
          5,
          (index) => {
            'id': 21 + index,
            'nickname': '候选人${21 + index}',
            'student_id':
                '2026000${(21 + index).toString().padLeft(3, '0')}',
            'role': 'user',
            'avatar': null,
          },
        ),
        'total': 25,
        'page': 2,
        'page_size': 20,
        'has_more': false,
      };
    }

    await tester.pumpWidget(
      _buildApp(
        const AdminCandidatesScreen(),
        {
          '/admin/candidates/stats': {
            'total': 133,
            'edu': 106,
            'other': 27,
            'eligible': 25,
          },
          '/admin/candidates': candidatesResponse,
        },
      ),
    );
    await tester.pumpAndSettle();

    // 第一页已加载，第二页内容尚未加载。
    expect(find.text('候选人1'), findsOneWidget);
    expect(find.text('候选人21'), findsNothing);

    // 滚到底部触发加载更多。
    await tester.drag(
      find.byType(Scrollable).last,
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();

    // 滚动后第二页内容与到底提示均已出现。
    expect(find.text('候选人25'), findsOneWidget);
    expect(find.text('已显示全部符合条件候选人'), findsOneWidget);
  });

  testWidgets('公告编辑器的长表单可滚动到末尾且底部操作仍可见', (tester) async {
    AppPreferencesStore.setMockInitialValues({});

    await tester.pumpWidget(
      _buildApp(
        const AdminAnnouncementsScreen(),
        {'/notices/admin/list': <Map<String, Object>>[]},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('发布公告'));
    await tester.pumpAndSettle();

    final newUserSwitch = find.text('向公告发布后注册的新用户展示');
    await tester.scrollUntilVisible(
      newUserSwitch,
      300,
      scrollable: find.byType(Scrollable).last,
    );

    expect(newUserSwitch, findsOneWidget);
    expect(find.text('发布'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('审核代办空态提供明确反馈与刷新入口', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        const AdminReviewTasksScreen(),
        {
          '/teachers/pending': <Object>[],
          '/majors/pending': <Object>[],
          '/admin/invitations/pending': <Object>[],
          '/admin/removals/pending': <Object>[],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('审核队列已清空'), findsOneWidget);
    expect(find.text('刷新任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
