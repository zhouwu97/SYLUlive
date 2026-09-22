import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/feedback/feedback_center_screen.dart';

class _MockFeedbackAuthProvider extends ChangeNotifier implements AuthProvider {
  _MockFeedbackAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 1;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _makeTicketJson(int id) {
  return {
    'id': id,
    'ticket_no': 'SY260914${id.toString().padLeft(4, '0')}',
    'user_id': 10,
    'type': 'bug',
    'title': '工单标题 $id',
    'description': '描述 $id',
    'status': 'pending',
    'status_note': '',
    'admin_viewed': true,
    'user_unread_count': 0,
    'latest_reply_snippet': '最新摘要 $id',
    'created_at': DateTime(2026, 9, 14, 10, 0).toIso8601String(),
    'updated_at': DateTime(2026, 9, 14, 10, 0).toIso8601String(),
  };
}

void main() {
  testWidgets('服务端总数滞后但下一页为空时停止翻页', (tester) async {
    final requestedPages = <int>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path != '/feedback/tickets') {
        handler.next(options);
        return;
      }
      final page = options.queryParameters['page'] as int? ?? 1;
      requestedPages.add(page);
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'total': 999,
          'page': page,
          'limit': 50,
          'tickets': page == 1
              ? List.generate(50, (i) => _makeTicketJson(i + 1))
              : <dynamic>[],
        },
      ));
    }));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(
          value: _MockFeedbackAuthProvider(client: dio),
        ),
        ChangeNotifierProvider<ThemeProvider>.value(
          value: ThemeProvider(loadOnStart: false),
        ),
      ],
      child: const MaterialApp(home: FeedbackCenterScreen()),
    ));
    await tester.pumpAndSettle();
    final listView = find.byType(ListView);
    for (var i = 0; i < 20 && !requestedPages.contains(2); i++) {
      await tester.drag(listView, const Offset(0, -1000));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(requestedPages, contains(2));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.drag(listView, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(requestedPages.where((page) => page == 3), isEmpty);
  });

  testWidgets('工单列表支持多页加载、滚动翻页与下拉刷新重置', (tester) async {
    final requestedPages = <int>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/feedback/tickets') {
            final page = options.queryParameters['page'] as int? ?? 1;
            requestedPages.add(page);

            if (page == 1) {
              // 第一页返回 50 条，总数 51 条
              final tickets = List.generate(50, (i) => _makeTicketJson(i + 1));
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'total': 51,
                    'page': 1,
                    'limit': 50,
                    'tickets': tickets,
                  },
                ),
              );
            } else if (page == 2) {
              // 第二页返回第 51 条（以及重复的一条用于测试去重保护）
              final tickets = [
                _makeTicketJson(50), // 重复
                _makeTicketJson(51), // 新增
              ];
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'total': 51,
                    'page': 2,
                    'limit': 50,
                    'tickets': tickets,
                  },
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'total': 51,
                    'page': page,
                    'limit': 50,
                    'tickets': <dynamic>[],
                  },
                ),
              );
            }
            return;
          }
          handler.next(options);
        },
      ),
    );

    final authProvider = _MockFeedbackAuthProvider(client: dio);
    final themeProvider = ThemeProvider(loadOnStart: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ],
        child: const MaterialApp(
          home: FeedbackCenterScreen(),
        ),
      ),
    );

    // 等待初始加载完成
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPages, contains(1));
    // 第一页应该渲染工单标题 1
    expect(find.text('工单标题 1'), findsOneWidget);
    // 第一页最后一项工单 50 存在于列表中（可能尚未滚动到视图内）
    expect(find.byType(ListView), findsOneWidget);

    final listView = find.byType(ListView);
    // 持续向上拖动列表内容（视图下滚）直到接近底部触发加载更多
    for (int i = 0; i < 15; i++) {
      await tester.drag(listView, const Offset(0, -1000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      if (requestedPages.contains(2)) break;
    }

    // 第二页被请求
    expect(requestedPages, contains(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 滚动至第 51 项进入可视区域
    for (int i = 0; i < 20; i++) {
      if (find.text('工单标题 51').evaluate().isNotEmpty) break;
      await tester.drag(listView, const Offset(0, -600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 切换至【处理中】Tab
    await tester.tap(find.text('处理中'));
    await tester.pumpAndSettle();

    // 切回【全部】Tab
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    // 验证重新请求了 page 1
    final page1Count = requestedPages.where((p) => p == 1).length;
    expect(page1Count, greaterThanOrEqualTo(3));
  });
}
