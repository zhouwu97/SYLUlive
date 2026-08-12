import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/screens/market_screen.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 未登录的 AuthProvider 假实现：首页 bootstrap 与各 Tab 的登录守卫
/// 只读取 isLoggedIn / user / token / dio，其余成员通过 noSuchMethod 兜底。
class _HomeAuthProvider extends ChangeNotifier implements AuthProvider {
  _HomeAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => null;

  @override
  String? get token => null;

  @override
  bool get isLoggedIn => false;

  @override
  int get sessionGeneration => 0;

  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => client;

  @override
  Future<void> refreshUser() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('首页内容区域横滑不切换根 Tab', (tester) async {
    final page = await _pumpHome(tester);

    // 从首页信息流中部向左快速横滑：旧行为会切到集市，新行为必须停留首页。
    await tester.dragFrom(const Offset(300, 400), const Offset(-160, 0));
    await tester.pumpAndSettle();

    expect(_rootTabIndex(tester), 0);
    expect(find.byType(MarketScreen), findsNothing);

    await _disposeHome(tester, page);
  });

  testWidgets('首页内容区域向右横滑也不切换根 Tab', (tester) async {
    final page = await _pumpHome(tester);

    await tester.dragFrom(const Offset(100, 400), const Offset(160, 0));
    await tester.pumpAndSettle();

    expect(_rootTabIndex(tester), 0);
    expect(find.byType(MarketScreen), findsNothing);

    await _disposeHome(tester, page);
  });

  testWidgets('底部导航可完整切换 首页/集市/课表/校园/我', (tester) async {
    final page = await _pumpHome(tester);

    const labels = ['集市', '课表', '校园', '我', '首页'];
    for (var index = 0; index < labels.length; index++) {
      final label = labels[index];
      final expectedIndex = (index + 1) % 5;
      await tester.tap(_navLabel(label));
      await tester.pumpAndSettle();
      expect(_rootTabIndex(tester), expectedIndex,
          reason: '点击「$label」后应切到 Tab $expectedIndex');
    }

    await _disposeHome(tester, page);
  });

  testWidgets('冷启动 start_on_timetable=true 不被上次停留的一级 Tab 覆盖', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'start_on_timetable': true,
      'navigation_last_root_tab': 4,
    });
    // HomeInitialTabResolver: start_on_timetable=true -> 课表(2)
    final page = await _pumpHome(tester, initialTab: 2);
    await tester.pump();
    expect(_rootTabIndex(tester), 2);
    await _disposeHome(tester, page);
  });

  testWidgets('冷启动 start_on_timetable=false 不被上次停留的一级 Tab 覆盖', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'start_on_timetable': false,
      'navigation_last_root_tab': 4,
    });
    // HomeInitialTabResolver: start_on_timetable=false -> 首页(0)
    final page = await _pumpHome(tester, initialTab: 0);
    await tester.pump();
    expect(_rootTabIndex(tester), 0);
    await _disposeHome(tester, page);
  });

  testWidgets('桌面小组件明确要求课表时优先于任何启动偏好', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'start_on_timetable': false,
      'navigation_last_root_tab': 4,
    });
    widgetTabSwitch.value++;
    final page = await _pumpHome(tester, initialTab: 0);
    await tester.pump();
    expect(_rootTabIndex(tester), 2);
    await _disposeHome(tester, page);
  });
}

Finder _navLabel(String label) {
  return find.descendant(
    of: find.byType(BottomNavWrapper),
    matching: find.text(label),
  );
}

int _rootTabIndex(WidgetTester tester) {
  return tester
      .widget<HomeTabKeepAliveStage>(find.byType(HomeTabKeepAliveStage))
      .index;
}

Future<_HomeTestPage> _pumpHome(
  WidgetTester tester, {
  int initialTab = 0,
  Map<String, Object> prefs = const {},
}) async {
  AppPreferencesStore.setMockInitialValues({...prefs});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
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
        );
      },
    ),
  );

  final auth = _HomeAuthProvider(client: dio);
  final postProvider = PostProvider(dio, enableCache: false);
  final messageProvider = MessageProvider(Dio());
  final themeProvider = ThemeProvider(loadOnStart: false);
  final sectionProvider = WaterSectionProvider(null);
  final eduProvider = EduProvider(Dio());
  final updateCoordinator = AppUpdateCoordinator();

  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<PostProvider>.value(value: postProvider),
      ChangeNotifierProvider<MessageProvider>.value(value: messageProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
      ChangeNotifierProvider<WaterSectionProvider>.value(
          value: sectionProvider),
      ChangeNotifierProvider<EduProvider>.value(value: eduProvider),
      ChangeNotifierProvider<AppUpdateCoordinator>.value(
          value: updateCoordinator),
    ],
    child: MaterialApp(home: HomeScreen(initialTab: initialTab)),
  );
  await tester.pumpWidget(widget);
  await tester.pump();
  // 消耗 _bootstrapHome 里的 500ms / 1200ms 延迟任务，避免测试结束时残留 Timer。
  await tester.pump(const Duration(milliseconds: 1500));
  return _HomeTestPage(
    auth: auth,
    postProvider: postProvider,
    messageProvider: messageProvider,
    themeProvider: themeProvider,
    sectionProvider: sectionProvider,
    eduProvider: eduProvider,
    updateCoordinator: updateCoordinator,
  );
}

Future<void> _disposeHome(WidgetTester tester, _HomeTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  // 课表 Tab 的后台保活检查带 2s 超时定时器，放行它避免遗留 pending timer。
  await tester.pump(const Duration(seconds: 2));
  page.auth.dispose();
  page.postProvider.dispose();
  page.messageProvider.dispose();
  page.themeProvider.dispose();
  page.sectionProvider.dispose();
  page.eduProvider.dispose();
  page.updateCoordinator.dispose();
}

class _HomeTestPage {
  const _HomeTestPage({
    required this.auth,
    required this.postProvider,
    required this.messageProvider,
    required this.themeProvider,
    required this.sectionProvider,
    required this.eduProvider,
    required this.updateCoordinator,
  });

  final _HomeAuthProvider auth;
  final PostProvider postProvider;
  final MessageProvider messageProvider;
  final ThemeProvider themeProvider;
  final WaterSectionProvider sectionProvider;
  final EduProvider eduProvider;
  final AppUpdateCoordinator updateCoordinator;
}
