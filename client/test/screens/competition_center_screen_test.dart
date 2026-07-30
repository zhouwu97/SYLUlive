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
  _TestAuthProvider(super.dio, {this.loggedIn = false})
      : super(loadStoredAuth: false);

  final bool loggedIn;

  // 公开目录用例保持未登录，候选链路用例显式模拟登录状态。
  @override
  bool get isLoggedIn => loggedIn;
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

Map<String, dynamic> _candidateEvent(int id) {
  return {
    ..._event(id),
    'competition_id': 'COMP-$id',
    'competition_rating': 'A',
    'personalized_score': 98,
    'fit_reasons': ['旧版偏好理由'],
    'group_key': 'major_match',
    'rule_order': 1,
    'core_reason': '参赛资格与专业方向符合公开目录',
    'cautions': ['报名时间仍需确认'],
    'dataset_version': 'catalog-2026-07',
    'match_dimensions': {
      'eligibility': 'matched',
      'major': 'matched',
    },
    'gates': {
      'candidate_pool_allowed': true,
      'personalized_ranking_allowed': false,
      'strong_recommendation_eligible': false,
      'recommendation_permission_level': 'candidate_only',
      'ai_mode': 'candidate_explanation',
    },
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
  bool loggedIn = false,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>(
      create: (_) => _TestAuthProvider(dio, loggedIn: loggedIn),
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

    testWidgets('适合我调用统一候选接口并按服务端分组展示', (tester) async {
      final adapter = _CompetitionAdapter((options) {
        switch (options.path) {
          case '/competitions/events':
            return _json({
              'items': [_event(1)],
              'total': 1,
            });
          case '/user/competitions/state':
            return _json({
              'joined_event_ids': const [],
              'calendar_count': 0,
              'profile_ready': true,
            });
          case '/user/competitions/dashboard':
            return _json({
              'preference_configured': true,
              'capability_ready': true,
            });
          case '/user/competitions/candidates':
            return _json({
              'total': 1,
              'profile_ready': true,
              'catalog': {
                'dataset_version': 'catalog-2026-07',
                'mode': 'candidate_explanation',
                'personalized_ranking_allowed': false,
              },
              'groups': [
                {
                  'key': 'major_match',
                  'label': '专业匹配',
                  'count': 1,
                  'items': [_candidateEvent(8)],
                },
              ],
            });
          default:
            return _catalogStub(options);
        }
      });

      await _pump(
        tester,
        _dio(adapter),
        const CompetitionCenterScreen(),
        loggedIn: true,
      );

      await tester.tap(find.text('适合我'));
      await tester.pumpAndSettle();

      expect(
        adapter.requests.any(
          (request) => request.path == '/user/competitions/candidates',
        ),
        isTrue,
      );
      expect(find.text('根据专业、资格和目标筛出 1 项候选'), findsOneWidget);
      expect(find.text('当前为候选解释，不代表获奖概率'), findsOneWidget);
      expect(find.text('专业匹配 · 1项'), findsOneWidget);
      expect(find.text('参赛资格与专业方向符合公开目录'), findsOneWidget);
      expect(find.textContaining('偏好匹配'), findsNothing);
      expect(find.text('旧版偏好理由'), findsNothing);
      expect(find.text('推荐'), findsNothing);
    });

    testWidgets('候选加载失败时不混入旧目录结果并可重试', (tester) async {
      var candidateAttempts = 0;
      final adapter = _CompetitionAdapter((options) {
        switch (options.path) {
          case '/competitions/events':
            return _json({
              'items': [_event(1)],
              'total': 1,
            });
          case '/user/competitions/state':
            return _json({
              'joined_event_ids': const [],
              'calendar_count': 0,
              'profile_ready': true,
            });
          case '/user/competitions/dashboard':
            return _json({
              'preference_configured': true,
              'capability_ready': true,
            });
          case '/user/competitions/candidates':
            candidateAttempts++;
            if (candidateAttempts == 1) {
              return _json({'error': '候选服务暂不可用'}, 500);
            }
            return _json({
              'total': 1,
              'profile_ready': true,
              'catalog': const {'dataset_version': 'catalog-2026-07'},
              'groups': [
                {
                  'key': 'major_match',
                  'label': '专业匹配',
                  'count': 1,
                  'items': [_candidateEvent(9)],
                },
              ],
            });
          default:
            return _catalogStub(options);
        }
      });

      await _pump(
        tester,
        _dio(adapter),
        const CompetitionCenterScreen(),
        loggedIn: true,
      );

      await tester.tap(find.text('适合我'));
      await tester.pumpAndSettle();

      expect(find.text('比赛 1'), findsNothing);
      expect(find.text('比赛加载失败'), findsOneWidget);
      await tester.ensureVisible(find.text('重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(candidateAttempts, 2);
      expect(find.text('比赛 9'), findsOneWidget);
      expect(find.text('专业匹配 · 1项'), findsOneWidget);
    });
  });
}
