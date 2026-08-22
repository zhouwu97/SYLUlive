import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/ai/campus_personal_data_permission_screen.dart';
import 'package:shenliyuan/services/ai_personal_data_permission_service.dart';

class _MemoryAuthCredentialStore implements AuthCredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();

  @override
  Future<void> write({required String token, required String userJson}) async {}
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._currentUser)
      : super(
          Dio(),
          credentialStore: _MemoryAuthCredentialStore(),
          loadStoredAuth: false,
          onAuthenticated: () {},
        );

  User? _currentUser;

  @override
  User? get user => _currentUser;

  void switchUser(User user) {
    _currentUser = user;
    notifyListeners();
  }
}

class _PermissionAdapter implements HttpClientAdapter {
  _PermissionAdapter(this._policies);

  final List<String> _policies;
  int getRequests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (options.method != 'GET' || options.path != '/ai/personal-data-access') {
      throw StateError('未预期的请求: ${options.method} ${options.path}');
    }
    final requestIndex = getRequests++;
    final policy = _policies[requestIndex];
    return ResponseBody.fromString(
      jsonEncode({
        'permissions': [
          {
            'scope': 'ai_personal_data_access',
            'policy': policy,
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  testWidgets('教务主动刷新保持可见但不可编辑', (tester) async {
    final adapter = _PermissionAdapter(['ask']);
    final dio = Dio()..httpClientAdapter = adapter;

    await _pumpScreen(tester, dio: dio);

    expect(find.text('AI 主动刷新教务'), findsOneWidget);
    expect(
      find.text('AI 主动刷新教务暂未开放。既有教务刷新完成后，AI 可继续处理等待中的任务。'),
      findsOneWidget,
    );
    expect(find.text('暂未开放'), findsOneWidget);
    expect(find.text('外部模型辅助分析'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuButton<AiPersonalDataPermissionPolicy>,
      ),
      findsNWidgets(5),
    );
  });

  testWidgets('账号切换后重新加载权限而非复用上个账号状态', (tester) async {
    final adapter = _PermissionAdapter(['never', 'always']);
    final dio = Dio()..httpClientAdapter = adapter;
    final auth = _FakeAuthProvider(_user(1));

    await _pumpScreen(tester, auth: auth, dio: dio);
    expect(find.text('永不允许'), findsOneWidget);

    auth.switchUser(_user(2));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('永不允许'), findsNothing);

    await tester.pumpAndSettle();
    expect(adapter.getRequests, 2);
    expect(find.text('始终允许'), findsOneWidget);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  _FakeAuthProvider? auth,
  required Dio dio,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>.value(
      value: auth ?? _FakeAuthProvider(_user(1)),
      child: MaterialApp(
        home: CampusPersonalDataPermissionScreen(dio: dio),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

User _user(int id) => User(
      id: id,
      studentId: '2024000$id',
      nickname: '测试用户$id',
      createdAt: DateTime(2024),
    );
