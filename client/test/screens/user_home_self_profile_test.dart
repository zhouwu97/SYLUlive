import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final requests = <RequestOptions>[];
  final Map<String, dynamic>? profileResponse;

  _ProfileRouteAdapter({this.profileResponse});

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
    requests.add(options);
    final statusCode = route == '/user/2' ||
            route == '/user/2/posts' ||
            route == '/user/2/market-posts' ||
            route == '/user/profile' ||
            route == '/user/background' ||
            route == '/upload'
        ? 200
        : 404;
    final response = switch (route) {
      '/upload' => {'url': 'http://example.com/new_bg.jpg'},
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
      '/user/profile' => options.method == 'PUT'
          ? {
              'id': 2,
              'student_id': '20260002',
              'nickname': '新名字',
              'gender': '',
              'created_at': '2026-07-15T00:00:00Z',
              'background': 'http://example.com/bg.jpg',
            }
          : profileResponse ?? {
              'id': 2,
              'student_id': '20260002',
              'nickname': '女生用户',
              'gender': 'female',
              'created_at': '2026-07-15T00:00:00Z',
              'background': '',
            },
      '/user/background' => {
          'id': 2,
          'student_id': '20260002',
          'nickname': '新名字',
          'gender': '',
          'created_at': '2026-07-15T00:00:00Z',
          'background': 'http://example.com/new_bg.jpg',
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
  setUpAll(() {
    HttpOverrides.global = _MockHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });
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

  testWidgets('UserHomeScreen() 不传 userId 时也请求 /user/profile', (tester) async {
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
        child: const MaterialApp(home: UserHomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.requestedPaths, contains('/user/profile'));
    expect(adapter.requestedPaths, isNot(contains('/user/2')));
  });

  testWidgets('gender为空时男女图标都不显示，且编辑页默认选中保密并能保存不变性别的请求', (tester) async {
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
    final adapter = _ProfileRouteAdapter(
      profileResponse: {
        'id': 2,
        'student_id': '20260002',
        'nickname': '未知性别用户',
        'gender': '',
        'created_at': '2026-07-15T00:00:00Z',
      },
    );
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
      'nickname': '未知性别用户',
      'gender': '',
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
        child: const MaterialApp(home: UserHomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.female), findsNothing);
    expect(find.byIcon(Icons.male), findsNothing);

    // 打开编辑页
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();

    // 未知性别默认选中保密
    final secrecySegment = find.descendant(
      of: find.byType(SegmentedButton<String>),
      matching: find.text('保密'),
    );
    expect(secrecySegment, findsOneWidget);

    // 修改昵称
    await tester.enterText(find.byType(TextField).first, '新名字');
    await tester.pump();

    // 清空初始化时的 requests 记录
    adapter.requests.clear();

    // 点击保存
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 验证请求
    final profileRequests = adapter.requests
        .where((request) => request.uri.path == '/user/profile')
        .toList();

    expect(
      profileRequests.where((request) => request.method == 'PUT'),
      hasLength(1),
    );

    expect(
      profileRequests.where((request) => request.method == 'GET'),
      isEmpty,
    );

    final updateRequest = profileRequests.firstWhere((r) => r.method == 'PUT');
    final body = Map<String, dynamic>.from(updateRequest.data as Map);

    expect(body['nickname'], '新名字');
    expect(body['gender'], '');
    expect(body['gender'], isNot('male'));

    expect(auth.user?.nickname, '新名字');
    expect(auth.user?.gender, '');
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('更换主页背景后立即使用新背景且没有追加GET请求', (tester) async {
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
      HttpOverrides.global = null;
    });

    HttpOverrides.global = _MockHttpOverrides();

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
      'nickname': '测试用户',
      'gender': 'male',
      'created_at': '2026-07-15T00:00:00Z',
      'background': '',
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<SocialProvider>(
            create: (_) => SocialProvider(dio),
          ),
        ],
        child: const MaterialApp(home: UserHomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    adapter.requests.clear();

    // 直接调用 auth_provider 的 applyProfileResponse 来模拟背景更改成功的服务端下发逻辑
    final response = await dio.put('/user/background', data: {'background': 'http://example.com/new_bg.jpg'});
    await auth.applyProfileResponse(Map<String, dynamic>.from(response.data as Map));
    
    // 渲染一帧以消耗掉 notifyListeners() 产生的 pending frame
    await tester.pump();
    
    expect(auth.user?.background, 'http://example.com/new_bg.jpg');
    
    final getRequests = adapter.requests.where((r) => r.method == 'GET' && r.uri.path == '/user/profile');
    expect(getRequests, isEmpty);
    await tester.pumpAndSettle();
  });
}

final Uint8List _transparentImage = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _MockHttpClientResponse extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _transparentImage.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream<List<int>>.value(_transparentImage).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

class _MockHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();
}

class _MockHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();
  @override
  void close({bool force = false}) {}
}

class _MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient();
  }
}
