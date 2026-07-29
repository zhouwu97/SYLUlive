import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/competition/competition_center_screen.dart';
import 'package:shenliyuan/widgets/competition/competition_ui_tokens.dart';

class _CompetitionAdapter implements HttpClientAdapter {
  _CompetitionAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }
}

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider(super.dio) : super(loadStoredAuth: false);

  // 竞赛目录是公开数据，未登录也能浏览；保持未登录可以避开 /user 相关请求。
  @override
  bool get isLoggedIn => false;
}

ResponseBody _json(Object data, [int status = 200]) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

Map<String, dynamic> _event(int id) {
  return {
    'id': id,
    'title': '比赛 $id',
    'summary': '摘要 $id',
    'organizer': '主办方 $id',
    'competition_level': '省级',
    'school_recognition_status': 'recognized',
    'school_recognition_grade': 'A',
    'source_channel': 'school_catalog',
  };
}

Dio _dio(_CompetitionAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://competition.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Future<void> _pump(
  WidgetTester tester,
  Dio dio,
  Widget home, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>(
      create: (_) => _TestAuthProvider(dio),
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 列表页固定的三个初始化请求，事件请求交给各用例自己处理。
FutureOr<ResponseBody> _catalogStub(RequestOptions options) {
  switch (options.path) {
    case '/competitions/categories':
      return _json([
        {'id': 1, 'name': '学科竞赛', 'slug': 'academic'},
      ]);
    case '/competitions/overview':
      return _json({'deadline_soon_count': 2});
    default:
      return _json({'error': 'not mocked: ${options.path}'}, 404);
  }
}

void main() {
  group('CompetitionDetailScreen', () {
    testWidgets('详情加载失败时展示错误与重试入口，而不是一直转圈', (tester) async {
      var attempts = 0;
      final adapter = _CompetitionAdapter((options) {
        attempts++;
        if (attempts == 1) {
          return _json({'error': 'boom'}, 500);
        }
        return _json(_event(7));
      });

      await _pump(
        tester,
        _dio(adapter),
        const CompetitionDetailScreen(eventId: 7),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('比赛详情加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.text('比赛 7'), findsOneWidget);
      expect(find.text('比赛详情加载失败'), findsNothing);
    });

    testWidgets('详情页深色模式使用竞赛设计令牌配色', (tester) async {
      final adapter = _CompetitionAdapter((options) => _json(_event(3)));

      await _pump(
        tester,
        _dio(adapter),
        const CompetitionDetailScreen(eventId: 3),
        brightness: Brightness.dark,
      );

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, CompetitionUiTokens.pageBg(true));
      expect(find.text('比赛 3'), findsOneWidget);
    });
  });

  group('CompetitionCenterScreen 分页', () {
    testWidgets('首页只保留一个竞赛档案组件并使用单行筛选', (tester) async {
      final adapter = _CompetitionAdapter((options) {
        if (options.path == '/competitions/events') {
          return _json({
            'items': [_event(1)],
            'total': 1,
          });
        }
        return _catalogStub(options);
      });

      await _pump(tester, _dio(adapter), const CompetitionCenterScreen());

      expect(
        find.byKey(const Key('competition-profile-compact-card')),
        findsOneWidget,
      );
      expect(find.text('我的竞赛目标'), findsNothing);
      expect(find.text('我的竞赛经历'), findsNothing);
      expect(find.text('我的能力画像'), findsNothing);
      final horizontal = tester.widgetList<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(
        horizontal.any((view) => view.scrollDirection == Axis.horizontal),
        isTrue,
      );
    });

    for (final width in [360.0, 411.0]) {
      testWidgets('${width.toInt()}px 宽度首屏可看到比赛目录或首张比赛卡片', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final adapter = _CompetitionAdapter((options) {
          if (options.path == '/competitions/events') {
            return _json({
              'items': [_event(1)],
              'total': 1,
            });
          }
          return _catalogStub(options);
        });

        await _pump(tester, _dio(adapter), const CompetitionCenterScreen());

        final directory = find.text('共 1 个结果 · 全部分类');
        expect(directory, findsOneWidget);
        expect(tester.getTopLeft(directory).dy, lessThan(800));
      });
    }

    testWidgets('返回不足一页时滚动到底不再请求下一页', (tester) async {
      final pages = <int>[];
      final adapter = _CompetitionAdapter((options) {
        if (options.path != '/competitions/events') {
          return _catalogStub(options);
        }
        final page = (options.queryParameters['page'] as num).toInt();
        pages.add(page);
        if (page > 1) return _json({'items': [], 'total': 100});
        // 只返回 19 条却谎报 total=100：服务端统计口径不一致或跨页重复时的真实场景。
        return _json({
          'items': [for (var i = 1; i <= 19; i++) _event(i)],
          'total': 100,
        });
      });

      await _pump(tester, _dio(adapter), const CompetitionCenterScreen());

      await tester.drag(find.byType(ListView).first, const Offset(0, -4000));
      await tester.pumpAndSettle();

      // 列表确实渲染到了底部，滚动到底却没有再翻页。
      expect(find.text('比赛 19'), findsOneWidget);
      expect(pages, [1]);
    });

    testWidgets('返回整页时滚动到底继续请求下一页', (tester) async {
      final pages = <int>[];
      final adapter = _CompetitionAdapter((options) {
        if (options.path != '/competitions/events') {
          return _catalogStub(options);
        }
        final page = (options.queryParameters['page'] as num).toInt();
        pages.add(page);
        if (page > 2) return _json({'items': [], 'total': 40});
        final start = (page - 1) * 20 + 1;
        return _json({
          'items': [for (var i = start; i < start + 20; i++) _event(i)],
          'total': 40,
        });
      });

      await _pump(tester, _dio(adapter), const CompetitionCenterScreen());

      await tester.drag(find.byType(ListView).first, const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(pages, [1, 2]);
    });
  });
}
