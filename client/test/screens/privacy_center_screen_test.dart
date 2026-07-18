import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/privacy_center_screen.dart';

class _PrivacyAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests.add(options);
    if (options.path == '/user/privacy/data') {
      return _jsonResponse(200, {
        'scope': '账户资料和法律文件授权记录',
        'legal_consents_active': true,
        'account': {
          'id': 7,
          'student_id': '2026000007',
          'nickname': '测试用户',
          'edu_bound': false,
        },
        'legal_consents': [
          {
            'document': 'privacy_policy',
            'version': '2026-07-18-r2',
            'accepted_at': '2026-07-18T00:00:00Z',
          },
        ],
      });
    }
    if (options.path == '/user/privacy/consents' &&
        options.method == 'DELETE') {
      return _jsonResponse(200, {
        'message': '已撤销全部授权',
        'legal_consents_active': false,
      });
    }
    if (options.path == '/user/account' && options.method == 'DELETE') {
      return _jsonResponse(200, {'message': '账号已注销'});
    }
    throw StateError('未处理的请求：${options.method} ${options.path}');
  }

  ResponseBody _jsonResponse(int statusCode, Object body) {
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Map<String, dynamic> _userJson() => {
      'id': 7,
      'student_id': '2026000007',
      'nickname': '测试用户',
      'role': 'user',
      'created_at': '2026-07-18T00:00:00Z',
      'legal_consents_active': true,
    };

class _TestAuthProvider extends AuthProvider {
  final Dio testDio;
  User currentUser;

  _TestAuthProvider(this.testDio)
      : currentUser = User.fromJson(_userJson()),
        super(testDio, loadStoredAuth: false, onAuthenticated: () {});

  @override
  Dio get dio => testDio;

  @override
  bool get isLoggedIn => true;

  @override
  User? get user => currentUser;

  @override
  Future<void> logout() async {}

  @override
  Future<AuthResult> withdrawLegalConsents(String password) async {
    await testDio.delete(
      '/user/privacy/consents',
      data: {'password': password, 'confirmed': true},
    );
    currentUser = User.fromJson({
      ...currentUser.toJson(),
      'legal_consents_active': false,
    });
    notifyListeners();
    return AuthResult.success();
  }

  @override
  Future<AuthResult> deleteAccount(String password) async {
    await testDio.delete(
      '/user/account',
      data: {'password': password, 'confirmed': true},
    );
    return AuthResult.success();
  }
}

AuthProvider _buildProvider(_PrivacyAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
    ..httpClientAdapter = adapter;
  return _TestAuthProvider(dio);
}

Widget _app(AuthProvider provider) {
  return ChangeNotifierProvider<AuthProvider>.value(
    value: provider,
    child: const MaterialApp(home: PrivacyCenterScreen()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('隐私中心提供数据权利和账号注销入口，查阅会直接展示数据', (tester) async {
    final adapter = _PrivacyAdapter();
    final provider = _buildProvider(adapter);
    await tester.pumpWidget(_app(provider));

    expect(find.text('查阅个人信息'), findsOneWidget);
    expect(find.text('撤销同意'), findsOneWidget);
    expect(find.text('注销账号'), findsOneWidget);
    expect(find.text('提交个人信息请求'), findsNothing);
    expect(find.text('处理进度'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('access-personal-data')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的个人信息'), findsOneWidget);
    expect(find.text('2026000007'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(adapter.requests.single.path, '/user/privacy/data');
  });

  testWidgets('撤销同意携带密码确认并立即切换本地授权状态', (tester) async {
    final adapter = _PrivacyAdapter();
    final provider = _buildProvider(adapter);
    await tester.pumpWidget(_app(provider));

    await tester.tap(find.byKey(const ValueKey('withdraw-legal-consents')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('withdraw-consent-password')),
      'password123',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-withdraw-consent')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final request = adapter.requests.single;
    expect(request.method, 'DELETE');
    expect(request.path, '/user/privacy/consents');
    expect(request.data, {'password': 'password123', 'confirmed': true});
    expect(provider.user?.legalConsentsActive, isFalse);
    expect(find.text('已撤销，依赖授权的功能不可用'), findsOneWidget);
  });

  testWidgets('注销账号要求密码确认并调用账号注销接口', (tester) async {
    final adapter = _PrivacyAdapter();
    final provider = _buildProvider(adapter);
    await tester.pumpWidget(_app(provider));

    await tester.tap(find.byKey(const ValueKey('cancel-account')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('cancel-account-password')),
      'password123',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-cancel-account')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final request = adapter.requests.single;
    expect(request.method, 'DELETE');
    expect(request.path, '/user/account');
    expect(request.data, {'password': 'password123', 'confirmed': true});
  });
}
