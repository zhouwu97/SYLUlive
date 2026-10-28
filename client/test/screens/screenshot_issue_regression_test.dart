import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/feedback/feedback_detail_screen.dart';
import 'package:shenliyuan/screens/likes_received_screen.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio);
  @override
  final Dio dio;
  int id = 10;
  int epoch = 1;
  @override
  User? get user => User(
      id: id, nickname: '测试用户', studentId: 'TEST', createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => id > 0;
  @override
  int get accountSessionEpoch => epoch;
  @override
  int get sessionGeneration => epoch;
  void switchAccount() {
    id = 20;
    epoch++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(_Auth auth, Widget screen, {bool dark = false, double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false)),
      ],
      child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: screen),
    );

Map<String, dynamic> _like(int id) => {
      'id': id,
      'user_id': id + 100,
      'nickname': '同学$id',
      'avatar': '',
      'target_type': id == 1 ? 'post' : 'reply',
      'target_id': 50,
      'post_id': 30,
      'post_title': '测试帖子',
      'created_at': '2026-09-25T07:22:00Z',
    };

void main() {
  setUpAll(loadTestFonts);
  for (final dark in [false, true]) {
    testWidgets('工单说明跟随真实状态，双向气泡和跨日时间统一上海时间 dark=$dark', (tester) async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
          onRequest: (o, h) =>
              h.resolve(Response(requestOptions: o, statusCode: 200, data: {
                'ticket': {
                  'id': 1,
                  'user_id': 10,
                  'status': 'accepted',
                  'status_note': '工单已提交，等待管理员查看受理',
                  'description': '测试工单',
                  'created_at': '2026-09-25T05:26:00Z',
                  'updated_at': '2026-09-25T07:45:00Z'
                },
                'messages': [
                  {
                    'id': 2,
                    'sender_type': 'admin',
                    'content': '官方回复',
                    'created_at': '2026-09-25T07:22:00Z'
                  },
                  {
                    'id': 3,
                    'sender_type': 'user',
                    'content': '用户回复',
                    'created_at': '2026-09-25T23:30:00Z'
                  },
                ],
                'history': [],
              }))));
      final auth = _Auth(dio);
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(_app(
          auth, const FeedbackDetailScreen(ticketId: 1, isAdmin: true),
          dark: dark, scale: 1.3));
      await tester.pumpAndSettle();
      expect(find.text('工单已提交，等待管理员查看受理'), findsNothing);
      await tester.scrollUntilVisible(find.text('15:22'), 100,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('15:22'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('07:30'), 100,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('07:30'), findsOneWidget);
      expect(find.text('2026-09-26'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.textContaining('最后更新 2026-09-25 15:45'), -100,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('最后更新 2026-09-25 15:45'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('收到的赞失败可重试，支持分页并保留前页数据', (tester) async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      attempts++;
      if (attempts == 1) {
        h.reject(DioException(requestOptions: o));
        return;
      }
      final more = o.queryParameters['cursor'] == '1';
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {
        'items': [_like(more ? 2 : 1)],
        'has_more': !more,
        'next_cursor': more ? '' : '1'
      }));
    }));
    await tester.pumpWidget(_app(_Auth(dio), const LikesReceivedScreen()));
    await tester.pumpAndSettle();
    expect(find.text('收到的赞加载失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('同学1 赞了你的帖子'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('同学1 赞了你的帖子'), findsOneWidget);
    expect(find.text('同学2 赞了你的评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收到的赞账号切换丢弃旧请求，空态清晰', (tester) async {
    final dio = Dio();
    final pending = Completer<Response<dynamic>>();
    var attempts = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      attempts++;
      if (attempts == 1) {
        h.resolve(await pending.future);
        return;
      }
      h.resolve(Response(
          requestOptions: o,
          statusCode: 200,
          data: {'items': [], 'has_more': false}));
    }));
    final auth = _Auth(dio);
    await tester.pumpWidget(_app(auth, const LikesReceivedScreen()));
    await tester.pump();
    auth.switchAccount();
    await tester.pumpAndSettle();
    pending.complete(
        Response(requestOptions: RequestOptions(), statusCode: 200, data: {
      'items': [_like(1)],
      'has_more': false
    }));
    await tester.pumpAndSettle();
    expect(find.text('同学1 赞了你的帖子'), findsNothing);
    expect(find.text('暂时没有收到其他人的赞'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
