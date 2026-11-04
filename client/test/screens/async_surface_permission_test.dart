import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/blog_screen.dart';
import 'package:shenliyuan/screens/erke_score_screen.dart';
import 'package:shenliyuan/screens/super_admin_screen.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _AdminAuth extends AuthProvider {
  _AdminAuth(super.dio) : super(loadStoredAuth: false);
  @override User get user => User(id: 1, studentId: 'fixture', nickname: '验收',
      role: 'super_admin', createdAt: DateTime(2026));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('后台标签预取失败可延迟展示并重试，没有未处理异常', (tester) async {
    var fail = true;
    var lotteryRequests = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      if (o.path == '/super/lottery/participants') {
        lotteryRequests++;
        if (fail) {
          h.reject(DioException(requestOptions: o,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: o, statusCode: 403,
                  data: {'error': '当前账号暂无此操作权限'})));
          return;
        }
        h.resolve(Response(requestOptions: o, statusCode: 200,
            data: {'event': {'id': 1, 'name': '本地验收'}, 'participants': []}));
      } else {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: []));
      }
    }));
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>(
      create: (_) => _AdminAuth(dio),
      child: const GoldenTestApp(home: SuperAdminScreen()),
    ));
    await tester.pumpAndSettle();
    expect(lotteryRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('抽奖管理'));
    await tester.pumpAndSettle();
    expect(find.text('重新加载'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(lotteryRequests, 2);
    expect(find.text('重新加载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录点击二课分入口会提示登录，不打开账号缓存页', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appearance),
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(Dio(), loadStoredAuth: false)),
      ],
      child: const GoldenTestApp(home: ToolboxScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('二课分查询'));
    await tester.tap(find.text('二课分查询'));
    await tester.pump();
    expect(find.text('请先登录'), findsOneWidget);
    expect(find.byType(ErkeScoreScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('博客精选卡在大字号时自然增高，普通字号保留高度', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    for (final scale in [1.0, 1.3, 1.5]) {
      await tester.pumpWidget(GoldenTestApp(
        textScaler: TextScaler.linear(scale), home: const BlogScreen(),
      ));
      await tester.pumpAndSettle();
      final heroTitle = find.byWidgetPredicate((w) => w is Text &&
          w.data == 'Flutter 状态管理深度对比' && w.style?.fontSize == 20);
      expect(heroTitle, findsOneWidget);
      final hero = find.ancestor(of: heroTitle, matching: find.byType(AppCardSurface));
      expect(tester.getSize(hero).height, scale == 1 ? 200 : greaterThan(200));
      expect(tester.takeException(), isNull);
    }
  });
}
