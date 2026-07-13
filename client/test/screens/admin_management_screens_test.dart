import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_candidates_screen.dart';
import 'package:shenliyuan/screens/admin_members_screen.dart';

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
      return ResponseBody.fromString(
        jsonEncode({'error': 'not found'}),
        404,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
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

  testWidgets('候选人页面显示接口返回的学号', (tester) async {
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
          },
          '/admin/candidates': [
            {
              'id': 7,
              'nickname': '候选人',
              'student_id': '2026000007',
              'role': 'user',
              'avatar': null,
            },
          ],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('学号: 2026000007'), findsOneWidget);
    expect(find.text('学号: 未知'), findsNothing);
  });
}
