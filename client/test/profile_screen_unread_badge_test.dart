import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/profile_screen.dart';

class _ProfileDio extends Fake implements Dio {
  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    final responseData = switch (path) {
      '/user/notifications/unread_count' => {'count': 3},
      '/messages/unread_count' => {'count': 0},
      '/user/1/posts/count' => {'count': 0},
      '/user/invitations' => <dynamic>[],
      _ => throw DioException(
          requestOptions: RequestOptions(path: path),
          message: 'Unexpected request: $path',
        ),
    };

    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: responseData as T,
    );
  }
}

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  final Dio _dio = _ProfileDio();

  @override
  bool get isLoggedIn => true;

  @override
  User? get user => User(
        id: 1,
        studentId: '20260001',
        nickname: '测试用户',
        createdAt: DateTime(2026, 1, 1),
      );

  @override
  Dio get dio => _dio;

  @override
  Future<void> refreshUser() async {}
}

class _FakeThemeProvider extends Fake
    with ChangeNotifier
    implements ThemeProvider {
  @override
  bool get startOnTimetable => false;

  @override
  bool get liquidGlass => false;

  @override
  double get componentOpacity => 0.7;
}

class _FakeEduProvider extends Fake
    with ChangeNotifier
    implements EduProvider {
  @override
  bool get isBound => false;
}

void main() {
  testWidgets('私信入口只根据私信未读数显示未读提示', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(),
          ),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => _FakeThemeProvider(),
          ),
          ChangeNotifierProvider<EduProvider>(
            create: (_) => _FakeEduProvider(),
          ),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('3条新回复'), findsOneWidget);
    expect(find.text('查看私信与系统通知'), findsOneWidget);
    expect(find.textContaining('含0条私信'), findsNothing);
  });
}
