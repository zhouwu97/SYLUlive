import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_security_center_screen.dart';
import 'package:shenliyuan/screens/admin_teacher_governance_screen.dart';

typedef _ResponseFactory = Future<ResponseBody> Function(
    RequestOptions options);

class _CallbackAdapter implements HttpClientAdapter {
  const _CallbackAdapter(this.factory);

  final _ResponseFactory factory;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return factory(options);
  }
}

ResponseBody _json(Object? data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

Widget _app(Widget home, HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = adapter;
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

Map<String, dynamic> _securityEvent(int id, String target, String status) => {
      'id': id,
      'event_type': 'login_failed',
      'severity': 'high',
      'status': status,
      'route': '/api/login',
      'method': 'POST',
      'target_masked': target,
      'attempt_count': 2,
      'actionable': true,
      'first_seen_at': '2026-09-22T08:00:00Z',
      'last_seen_at': '2026-09-22T08:00:00Z',
    };

void main() {
  testWidgets('安全中心快速切换筛选时忽略较晚返回的旧请求', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final staleResponse = Completer<ResponseBody>();
    final adapter = _CallbackAdapter((options) async {
      if (options.uri.path == '/admin/security/overview') {
        return _json({
          'range': '24h',
          'actionable_high_count': 1,
          'actionable_pending_count': 1,
          'protection': <String, dynamic>{},
        });
      }
      if (options.uri.path == '/admin/security/events') {
        final status = options.queryParameters['status'];
        final actionable = options.queryParameters['actionable'];
        if (status == 'active') {
          return _json({
            'items': [_securityEvent(1, '待处置账号', 'active')],
          });
        }
        if (status == 'all' && actionable == 'all') {
          return staleResponse.future;
        }
        if (status == 'resolved') {
          return _json({
            'items': [_securityEvent(3, '已处理账号', 'resolved')],
          });
        }
      }
      return _json({'error': 'not found'}, statusCode: 404);
    });

    await tester.pumpWidget(
      _app(const AdminSecurityCenterScreen(), adapter),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('待处置账号'), findsOneWidget);

    await tester.tap(find.text('全部记录'));
    await tester.pump();
    await tester.tap(find.text('已处理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已处理账号'), findsOneWidget);

    staleResponse.complete(_json({
      'items': [_securityEvent(2, '旧筛选账号', 'active')],
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('已处理账号'), findsOneWidget);
    expect(find.textContaining('旧筛选账号'), findsNothing);
  });

  testWidgets('教师姓名变化后旧预览立即失效，失败时不能继续提交', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var previewRequests = 0;
    final adapter = _CallbackAdapter((options) async {
      if (options.uri.path == '/version') {
        return _json({
          'capabilities': {'teacher_governance_v1': true},
        });
      }
      if (options.uri.path == '/admin/teacher-governance/teachers') {
        return _json({
          'teachers': const [
            {
              'id': 1,
              'name': '张三',
              'course_subject_id': 10,
              'course_subject_name': '高等数学',
              'rating_count': 8,
            },
            {
              'id': 2,
              'name': '张三老师',
              'course_subject_id': 10,
              'course_subject_name': '高等数学',
              'rating_count': 2,
            },
          ],
          'has_more': false,
        });
      }
      if (options.uri.path == '/admin/teacher-governance/merge-preview') {
        previewRequests++;
        if (previewRequests == 1) {
          return _json({
            'keeper': {'id': 1, 'name': '张三'},
            'loser_ids': [2],
            'snapshot_token': 'old-preview-token',
            'merge_allowed': true,
            'ratings_migrated': 2,
          });
        }
        return _json(
          {'error': '预览服务暂不可用'},
          statusCode: 503,
        );
      }
      return _json({'error': 'not found'}, statusCode: 404);
    });

    await tester.pumpWidget(
      _app(
        const AdminTeacherGovernanceScreen(initialTab: 1),
        adapter,
      ),
    );
    await tester.pumpAndSettle();

    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(2));
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();

    final openMerge = find.text('发起合并治理');
    await tester.ensureVisible(openMerge);
    await tester.tap(openMerge);
    await tester.pumpAndSettle();

    final oldSubmit = find.widgetWithText(FilledButton, '确认合并为「张三」');
    expect(oldSubmit, findsOneWidget);
    expect(tester.widget<FilledButton>(oldSubmit).onPressed, isNotNull);

    final nameField = find.widgetWithText(TextField, '合并后的规范教师姓名 (必填)');
    await tester.enterText(nameField, '新名字');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('预览服务暂不可用'), findsOneWidget);
    final newSubmit = find.widgetWithText(FilledButton, '确认合并为「新名字」');
    expect(newSubmit, findsOneWidget);
    expect(tester.widget<FilledButton>(newSubmit).onPressed, isNull);
  });
}
