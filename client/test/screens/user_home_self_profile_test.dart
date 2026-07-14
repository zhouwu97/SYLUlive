import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/screens/user_home_screen.dart';

class _ProfileRouteAdapter implements HttpClientAdapter {
  final requestedPaths = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final route = options.uri.path;
    requestedPaths.add(route);
    final statusCode = route == '/user/2' ||
            route == '/user/2/posts' ||
            route == '/user/2/market-posts' ||
            route == '/user/profile'
        ? 200
        : 404;
    final response = switch (route) {
      '/user/2' => {
          'id': 2,
          'nickname': '女生用户',
          'avatar': '',
          'background': '',
          'exp': 0,
          'followers_count': 0,
          'following_count': 0,
          'total_likes_received': 0,
          'is_following': false,
        },
      '/user/profile' => {
          'id': 2,
          'student_id': '20260002',
          'nickname': '女生用户',
          'gender': 'female',
          'created_at': '2026-07-15T00:00:00Z',
        },
      '/user/2/posts' => <Object>[],
      '/user/2/market-posts' => {
          'items': <Object>[],
          'total': 0,
          'sold': 0,
        },
      _ => {'error': 'not found'},
    };
    return ResponseBody.fromString(
      jsonEncode(response),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _MemoryAuthCredentialStore implements AuthCredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<void> deleteEduPassword(String studentId) async {}

  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();

  @override
  Future<String?> readEduPassword(String studentId) async => null;

  @override
  Future<void> write({required String token, required String userJson}) async {}

  @override
  Future<void> writeEduPassword(String studentId, String password) async {}
}

void main() {
  testWidgets('自己的主页刷新后保留登录态中的女性性别', (tester) async {
    const keepAliveChannel = MethodChannel('shenliyuan/keep_alive');
    const gradeReminderChannel = MethodChannel('shenliyuan/grade_reminders');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async => true);
    messenger.setMockMethodCallHandler(
      gradeReminderChannel,
      (call) async => null,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(keepAliveChannel, null);
      messenger.setMockMethodCallHandler(gradeReminderChannel, null);
    });

    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    final adapter = _ProfileRouteAdapter();
    dio.httpClientAdapter = adapter;
    final auth = AuthProvider(
      dio,
      credentialStore: _MemoryAuthCredentialStore(),
      loadStoredAuth: false,
      onAuthenticated: () {},
    );
    await auth.applyAuthPayload('token', {
      'id': 2,
      'student_id': '20260002',
      'nickname': '女生用户',
      'gender': 'female',
      'created_at': '2026-07-15T00:00:00Z',
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<SocialProvider>(
            create: (_) => SocialProvider(dio),
          ),
        ],
        child: const MaterialApp(home: UserHomeScreen(userId: 2)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.female), findsOneWidget);
    expect(find.byIcon(Icons.male), findsNothing);
    expect(adapter.requestedPaths, contains('/user/profile'));
    expect(adapter.requestedPaths, isNot(contains('/user/2')));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
