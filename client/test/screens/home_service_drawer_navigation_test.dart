import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';
import 'package:shenliyuan/screens/shuitie_screen.dart';
import 'package:shenliyuan/widgets/home_service_drawer.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _StubAuthProvider extends ChangeNotifier implements AuthProvider {
  _StubAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => false;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({
    required this.auth,
    required this.postProvider,
    required this.messageProvider,
    required this.themeProvider,
    required this.sectionProvider,
  });

  final _StubAuthProvider auth;
  final PostProvider postProvider;
  final MessageProvider messageProvider;
  final ThemeProvider themeProvider;
  final WaterSectionProvider sectionProvider;

  void dispose() {
    auth.dispose();
    postProvider.dispose();
    messageProvider.dispose();
    themeProvider.dispose();
    sectionProvider.dispose();
  }
}

Future<_Harness> _pumpHome(
  WidgetTester tester, {
  bool disableAnimations = false,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: options.path == '/posts'
            ? <String, dynamic>{
                'posts': <dynamic>[],
                'pinned_posts': <dynamic>[],
                'total': 0,
              }
            : <dynamic>[],
      ),
    ),
  ));

  final harness = _Harness(
    auth: _StubAuthProvider(client: dio),
    postProvider: PostProvider(dio, enableCache: false),
    messageProvider: MessageProvider(Dio()),
    themeProvider: ThemeProvider(loadOnStart: false),
    sectionProvider: WaterSectionProvider(null),
  );
  addTearDown(harness.dispose);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: harness.auth),
      ChangeNotifierProvider<PostProvider>.value(value: harness.postProvider),
      ChangeNotifierProvider<MessageProvider>.value(
          value: harness.messageProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: harness.themeProvider),
      ChangeNotifierProvider<WaterSectionProvider>.value(
          value: harness.sectionProvider),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data:
            MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: const ShuitieScreen(),
    ),
  ));
  await tester.pump();
  return harness;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu_rounded).first);
  await tester.pumpAndSettle();
  expect(find.text('更多服务'), findsOneWidget);
}

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('校园服务贴着左边缘滑入，点击遮罩后向左滑出', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.byTooltip('校园服务'));
    await tester.pump();

    final drawer = find.byType(HomeServiceDrawer);
    expect(tester.getTopRight(drawer).dx, closeTo(0, 0.5));
    await tester.pump(const Duration(milliseconds: 64));
    final enteringRight = tester.getTopRight(drawer).dx;
    expect(enteringRight, greaterThan(0));
    expect(enteringRight, lessThan(tester.getSize(drawer).width));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(drawer).dx, closeTo(0, 0.5));

    await tester.tapAt(const Offset(390, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 96));
    final exitingRight = tester.getTopRight(drawer).dx;
    expect(exitingRight, greaterThan(0));
    expect(exitingRight, lessThan(tester.getSize(drawer).width));
    await tester.pumpAndSettle();
    expect(drawer, findsNothing);
  });

  testWidgets('系统关闭动画时校园服务直接打开并可用返回键关闭', (tester) async {
    await _pumpHome(tester, disableAnimations: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('校园服务'));
    await tester.pump();

    final drawer = find.byType(HomeServiceDrawer);
    expect(tester.getTopLeft(drawer).dx, closeTo(0, 0.5));
    expect(find.text('工具箱').hitTestable(), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(drawer, findsNothing);
  });

  testWidgets('返回后再点其他服务项仍保留校园服务侧栏', (tester) async {
    await _pumpHome(tester);
    await _openPanel(tester);

    // 未登录时成绩查询进入登录页，无网络依赖，适合验证路由栈行为。
    await tester.tap(find.text('成绩查询'));
    await tester.pumpAndSettle();
    expect(find.text('更多服务'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('更多服务'), findsOneWidget);

    await tester.tap(find.text('考试安排'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('更多服务'), findsOneWidget,
        reason: '第二次进入服务页返回后侧栏不能被关闭');
  });

  testWidgets('返回转场未结束就点其他服务项不会误关侧栏', (tester) async {
    await _pumpHome(tester);
    await _openPanel(tester);

    await tester.tap(find.text('成绩查询'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    // 返回转场约 300ms；在转场中途点击侧栏条目，模拟真机的快速连点。
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('考试安排'));
    await tester.pumpAndSettle();

    // 转场中途的点击要么正常打开页面，要么被放弃；两种情况都不能关掉侧栏。
    if (find.byType(ExamScheduleScreen).evaluate().isNotEmpty) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.text('更多服务'), findsOneWidget,
        reason: '转场中途的点击不能变成关闭侧栏');
  });
}
