import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('悬浮液态底栏保留五个入口、选中语义与完整点击区域', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final semantics = tester.ensureSemantics();
    try {
      expect(find.byKey(const ValueKey('bottom-nav-floating-dock')),
          findsOneWidget);
      expect(
        find.byKey(const ValueKey('bottom-nav-liquid-lens')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('bottom-nav-selection-fallback')),
        findsOneWidget,
      );

      for (final label in const ['首页', '集市', '课表', '校园', '我']) {
        expect(find.text(label), findsOneWidget);
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('bottom-nav-item-3')));
      await tester.pump();

      expect(harness.selectedIndex.value, 3);
      expect(harness.lastTappedIndex.value, 3);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('bottom-nav-item-3')))
              .height,
          greaterThanOrEqualTo(44));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('拖动透镜保持连续位置，松手后才吸附并恢复', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final lensFinder = find.byKey(const ValueKey('bottom-nav-liquid-lens'));
    expect(lensFinder, findsNothing);

    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 120));
    expect(lensFinder, findsOneWidget);
    await gesture.moveTo(
      Offset(layerTopLeft.dx + itemWidth * 2.0, layerTopLeft.dy + 30),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();

    expect(harness.visualIndex.value, closeTo(1.5, 0.02));
    expect(harness.selectedIndex.value, 0);
    expect(harness.commitCount.value, 0);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(lensFinder, findsNothing);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-fallback')),
      findsOneWidget,
    );
    expect(harness.visualIndex.value, closeTo(2, 0.01));
    expect(harness.selectedIndex.value, 2);
    expect(harness.lastCommittedIndex.value, 2);
    expect(harness.commitCount.value, 1);
  });

  testWidgets('V8 按住当前选中块激活连续 Capsule，短按会完整收回', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);

    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 60));

    expect(harness.phase.value, LiquidNavPhase.pressing);
    expect(harness.activation.value, greaterThan(0));
    expect(harness.activation.value, lessThan(1));
    expect(
        find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsOneWidget);

    await tester.pumpFrames(harness, const Duration(milliseconds: 70));
    // V8 使用可中断 spring，不把 progress 人为截成 tween 的终点；
    // 此时应已进入完整玻璃态的接近区间，但仍允许物理收敛。
    expect(harness.activation.value, greaterThan(0.90));
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-fallback')),
      findsOneWidget,
    );

    // Hold 不应因为没有移动而超时收回；这是 Press-to-Liquid 与普通长按的
    // 关键区别，完整 Lens 要一直保持到 pointer up。
    await tester.pumpFrames(harness, const Duration(seconds: 2));
    expect(harness.phase.value, LiquidNavPhase.pressing);
    expect(harness.activation.value, closeTo(1, 0.01));
    expect(
      find.byKey(const ValueKey('bottom-nav-liquid-lens')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
    expect(harness.commitCount.value, 0);
  });

  testWidgets('V8 快速点击只短暂触发 Pressed，不提交也不残留 Lens', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );

    await tester.pumpFrames(harness, const Duration(milliseconds: 40));
    expect(harness.phase.value, LiquidNavPhase.pressing);
    expect(harness.activation.value, lessThan(1));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(harness.commitCount.value, 0);
    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-fallback')),
      findsOneWidget,
    );
  });

  testWidgets('V8 拖动经历 dragging → settling → collapsing 并只提交一次',
      (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 120));
    await gesture.moveTo(
      Offset(layerTopLeft.dx + itemWidth * 2.0, layerTopLeft.dy + 30),
    );
    await tester.pump();

    expect(harness.phase.value, LiquidNavPhase.dragging);
    expect(harness.visualIndex.value, closeTo(1.5, 0.02));

    await gesture.up();
    expect(harness.phase.value, LiquidNavPhase.settling);
    expect(harness.commitCount.value, 0);
    await tester.pumpAndSettle();

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(harness.selectedIndex.value, 2);
    expect(harness.commitCount.value, 1);
    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
  });

  testWidgets('多指触控锁定首个 pointer，不让第二个 pointer 接管 Lens', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final first = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
      pointer: 1,
    );

    await first.moveTo(
      Offset(layerTopLeft.dx + itemWidth * 1.5, layerTopLeft.dy + 30),
    );
    await tester.pump();
    expect(harness.visualIndex.value, closeTo(1, 0.02));

    final second = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 2.5, layerTopLeft.dy + 30),
      pointer: 2,
    );
    await second.moveTo(
      Offset(layerTopLeft.dx + itemWidth * 4.5, layerTopLeft.dy + 30),
    );
    await tester.pump();

    expect(harness.visualIndex.value, closeTo(1, 0.02));
    await second.cancel();
    await first.up();
    await tester.pumpAndSettle();
  });

  testWidgets('首尾 Lens 中心与固定 Tab 中心对齐且不受 Dock 裁剪限制', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final lensFinder = find.byKey(const ValueKey('bottom-nav-liquid-lens'));
    final firstItem = find.byKey(const ValueKey('bottom-nav-item-0'));
    final lastItem = find.byKey(const ValueKey('bottom-nav-item-4'));

    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 120));
    expect(
      find.ancestor(of: lensFinder, matching: find.byType(ClipRRect)),
      findsNothing,
    );
    expect(
      tester.getCenter(lensFinder).dx,
      closeTo(tester.getCenter(firstItem).dx, 1),
    );

    harness.visualIndex.value = 4;
    await tester.pump();

    expect(
      tester.getCenter(lensFinder).dx,
      closeTo(tester.getCenter(lastItem).dx, 1),
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('连续位置不会在跨过 Tab 中点时提前吸附', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await gesture.moveTo(
      Offset(layerTopLeft.dx + itemWidth * 1.25, layerTopLeft.dy + 30),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(harness.visualIndex.value, closeTo(0.75, 0.02));
    expect(harness.selectedIndex.value, 0);
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('Reduced Motion 直接让透镜落在当前 Tab', (tester) async {
    await _pumpNav(
      tester,
      liquidGlass: true,
      disableAnimations: true,
      initialIndex: 3,
      initialVisualIndex: 0.4,
    );

    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
    expect(
      tester
          .getCenter(
              find.byKey(const ValueKey('bottom-nav-selection-fallback')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-3'))).dx,
        1,
      ),
    );
  });

  testWidgets('关闭液态玻璃时使用稳定的实色选中态', (tester) async {
    await _pumpNav(tester, liquidGlass: false);

    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-fallback')),
      findsOneWidget,
    );
  });

  testWidgets('暗色与 1.3 倍字号下底栏不溢出', (tester) async {
    await _pumpNav(
      tester,
      liquidGlass: true,
      darkMode: true,
      textScale: 1.3,
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('bottom-nav-liquid-lens')), findsNothing);
  });
}

Future<_NavHarness> _pumpNav(
  WidgetTester tester, {
  required bool liquidGlass,
  bool darkMode = false,
  bool disableAnimations = false,
  double textScale = 1,
  int initialIndex = 0,
  double? initialVisualIndex,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  AppPreferencesStore.setMockInitialValues({
    'floating_nav_bar': true,
    'liquid_glass_v2': liquidGlass,
  });
  final themeProvider = ThemeProvider(loadOnStart: false);
  await themeProvider.loadThemeForTesting();
  final authProvider = AuthProvider(Dio(), loadStoredAuth: false);
  final harness = _NavHarness(
    themeProvider: themeProvider,
    authProvider: authProvider,
    selectedIndex: ValueNotifier(initialIndex),
    visualIndex: ValueNotifier(initialVisualIndex ?? initialIndex.toDouble()),
    darkMode: darkMode,
    disableAnimations: disableAnimations,
    textScale: textScale,
  );
  addTearDown(harness.dispose);

  await tester.pumpWidget(harness);
  await tester.pumpAndSettle();
  return harness;
}

class _NavHarness extends StatelessWidget {
  _NavHarness({
    required this.themeProvider,
    required this.authProvider,
    required this.selectedIndex,
    required this.visualIndex,
    required this.darkMode,
    required this.disableAnimations,
    required this.textScale,
  })  : lastTappedIndex = ValueNotifier(null),
        lastCommittedIndex = ValueNotifier(null),
        commitCount = ValueNotifier(0),
        phase = ValueNotifier(LiquidNavPhase.idle),
        activation = ValueNotifier(0);

  final ThemeProvider themeProvider;
  final AuthProvider authProvider;
  final ValueNotifier<int> selectedIndex;
  final ValueNotifier<double> visualIndex;
  final bool darkMode;
  final bool disableAnimations;
  final double textScale;
  final ValueNotifier<int?> lastTappedIndex;
  final ValueNotifier<int?> lastCommittedIndex;
  final ValueNotifier<int> commitCount;
  final ValueNotifier<LiquidNavPhase> phase;
  final ValueNotifier<double> activation;

  void dispose() {
    selectedIndex.dispose();
    visualIndex.dispose();
    lastTappedIndex.dispose();
    lastCommittedIndex.dispose();
    commitCount.dispose();
    phase.dispose();
    activation.dispose();
    themeProvider.dispose();
    authProvider.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThemeProvider>.value(
      value: themeProvider,
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        home: Builder(
          builder: (context) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                disableAnimations: disableAnimations,
                textScaler: TextScaler.linear(textScale),
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: selectedIndex,
                builder: (context, currentIndex, child) {
                  return Scaffold(
                    extendBody: true,
                    body: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFE5B2), Color(0xFF8EDFD3)],
                        ),
                      ),
                      child: SizedBox.expand(),
                    ),
                    bottomNavigationBar: BottomNavWrapper(
                      currentIndex: currentIndex,
                      visualIndexListenable: visualIndex,
                      onTap: (index) {
                        lastTappedIndex.value = index;
                        selectedIndex.value = index;
                      },
                      onNavigationCommitted: (index) {
                        lastCommittedIndex.value = index;
                        commitCount.value++;
                        selectedIndex.value = index;
                      },
                      onLiquidPhaseChanged: (value) => phase.value = value,
                      onLiquidActivationChanged: (value) =>
                          activation.value = value,
                      authProvider: authProvider,
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
