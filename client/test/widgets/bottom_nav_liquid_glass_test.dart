import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('悬浮液态底栏保留五个入口、选中语义与完整点击区域', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final semantics = tester.ensureSemantics();
    try {
      expect(find.byKey(const ValueKey('bottom-nav-floating-dock')),
          findsOneWidget);
      expect(
        find.byKey(const ValueKey('bottom-nav-selection')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bottom-nav-liquid-diagnostics')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('bottom-nav-selection')),
        findsOneWidget,
      );

      for (final label in const ['首页', '集市', '课表', '校园', '我']) {
        expect(find.text(label), findsWidgets);
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('bottom-nav-item-3')));
      // 先让 tap-up 回调启动两条 spring，再推进动画时间。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(harness.phase.value, LiquidNavPhase.settling);
      expect(harness.activation.value, greaterThan(0));
      expect(harness.visualIndex.value, greaterThan(0));
      expect(harness.visualIndex.value, lessThan(3));
      // 页面提交不再等待 Lens spring 完成；此时视觉位置仍在追随目标。
      expect(harness.selectedIndex.value, 3);
      expect(harness.commitCount.value, 1);

      await tester.pumpAndSettle();

      expect(harness.selectedIndex.value, 3);
      expect(harness.lastTappedIndex.value, isNull);
      expect(harness.lastCommittedIndex.value, 3);
      expect(harness.commitCount.value, 1);
      expect(harness.phase.value, LiquidNavPhase.idle);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('bottom-nav-item-3')))
              .height,
          greaterThanOrEqualTo(44));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('frosted idle 保留背景 blur、Normal Row 挖空和 Accent 前景分层',
      (tester) async {
    await _pumpNav(tester, liquidGlass: true);

    expect(
      find.byKey(const ValueKey('bottom-nav-selection-backdrop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-base-blur')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-base-surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-normal-exclusion')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-dock-exclusion')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-foreground')),
      findsOneWidget,
    );
    // Dock 常态保留 Lens；Selection Idle 也保留基础曲面高光。
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-default-highlight')),
      findsOneWidget,
    );
    final material = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('bottom-nav-selection-material')),
    );
    final decoration = material.decoration as BoxDecoration;
    expect(decoration.boxShadow, isNull);
    // Shader 配置开启时，Idle 不再退回白色描边，而是使用真实光学材质。
    expect(decoration.border, isNull);
    final backdrop = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('bottom-nav-selection-backdrop')),
    );
    final backdropDecoration = backdrop.decoration as BoxDecoration;
    expect(backdropDecoration.boxShadow, isNull);
    final surface = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(
          const ValueKey('bottom-nav-selection-base-surface'),
        ),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(surface.color.a, closeTo(0.08, 0.001));
    final dockWidth = tester
        .getSize(find.byKey(const ValueKey('bottom-nav-floating-dock')))
        .width;
    final selectionWidth = tester
        .getSize(find.byKey(const ValueKey('bottom-nav-selection')))
        .width;
    expect(selectionWidth / (dockWidth / 5), closeTo(1.0, 0.01));
    final dockRect = tester.getRect(
      find.byKey(const ValueKey('bottom-nav-floating-dock')),
    );
    final selectionRect = tester.getRect(
      find.byKey(const ValueKey('bottom-nav-selection')),
    );
    expect(selectionRect.left, greaterThanOrEqualTo(dockRect.left));
    expect(selectionRect.right, lessThanOrEqualTo(dockRect.right));
  });

  testWidgets('V9 正式 Normal Row 始终 neutral/scale=1，Accent Copy 独立在窗口内',
      (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final item = find.byKey(const ValueKey('bottom-nav-item-2'));
    final normalTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('bottom-nav-normal-content-2')),
    );
    expect(normalTransform.transform.storage[0], closeTo(1, 0.0001));
    expect(
      tester
          .widget<Icon>(find.descendant(of: item, matching: find.byType(Icon)))
          .color,
      AppColors.iconMutedLight,
    );
    expect(
      tester
          .widget<Transform>(
            find.byKey(
              const ValueKey('bottom-nav-accent-content-scale-0'),
            ),
          )
          .transform
          .storage[0],
      closeTo(1, 0.0001),
    );
    final accentIcons = find.descendant(
      of: find.byKey(const ValueKey('bottom-nav-accent-tabs')),
      matching: find.byType(Icon),
    );
    expect(accentIcons, findsNWidgets(5));
    for (var index = 0; index < 5; index++) {
      expect(
        tester.widget<Icon>(accentIcons.at(index)).color,
        AppColors.brandPrimary,
      );
    }
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('bottom-nav-accent-tabs')), findsOneWidget);

    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final topLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;

    for (final position in const [0.0, 0.5, 1.0, 2.5]) {
      harness.visualIndex.value = position;
      await tester.pump();
      for (var index = 0; index < 5; index++) {
        final transform = tester.widget<Transform>(
          find.byKey(ValueKey('bottom-nav-normal-content-$index')),
        );
        expect(transform.transform.storage[0], closeTo(1, 0.0001));
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(ValueKey('bottom-nav-item-$index')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.color, AppColors.iconMutedLight);
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('bottom-nav-item-$index')),
            matching: find.byType(Text),
          ),
        );
        expect(label.style?.color, AppColors.iconMutedLight);
      }
    }

    final gesture = await tester.startGesture(
      Offset(topLeft.dx + itemWidth * 0.5, topLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 120));
    await gesture.moveTo(Offset(topLeft.dx + itemWidth * 2, topLeft.dy + 30));
    await tester.pump();

    expect(
      tester
          .widget<Transform>(
            find.byKey(
              const ValueKey('bottom-nav-accent-content-scale-0'),
            ),
          )
          .transform
          .storage[0],
      greaterThan(1.0),
    );

    for (var index = 0; index < 5; index++) {
      final transform = tester.widget<Transform>(
        find.byKey(ValueKey('bottom-nav-normal-content-$index')),
      );
      expect(transform.transform.storage[0], closeTo(1, 0.0001));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey('bottom-nav-item-$index')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, AppColors.iconMutedLight);
      final label = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('bottom-nav-item-$index')),
          matching: find.byType(Text),
        ),
      );
      expect(label.style?.color, AppColors.iconMutedLight);
    }
    expect(
        find.byKey(const ValueKey('bottom-nav-accent-tabs')), findsOneWidget);
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('拖动透镜保持连续位置，松手后才吸附并恢复', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final lensFinder = find.byKey(const ValueKey('bottom-nav-selection'));
    expect(lensFinder, findsOneWidget);

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
    expect(harness.phase.value, LiquidNavPhase.settling);
    expect(harness.selectedIndex.value, 2);
    expect(harness.lastCommittedIndex.value, 2);
    expect(harness.commitCount.value, 1);
    await tester.pumpAndSettle();

    expect(lensFinder, findsOneWidget);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection')),
      findsOneWidget,
    );
    expect(harness.visualIndex.value, closeTo(2, 0.01));
    expect(harness.selectedIndex.value, 2);
    expect(harness.lastCommittedIndex.value, 2);
    expect(harness.commitCount.value, 1);
  });

  testWidgets('拖拽形变左右镜像，边界压缩不会丢失反馈', (tester) async {
    final harness = await _pumpNav(
      tester,
      liquidGlass: true,
      initialIndex: 2,
    );
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;
    final lensFinder = find.byKey(const ValueKey('bottom-nav-selection'));
    final idleWidth = tester.getSize(lensFinder).width;

    Future<double> dragAndMeasure(double targetCenter) async {
      final gesture = await tester.startGesture(
        Offset(layerTopLeft.dx + itemWidth * 2.5, layerTopLeft.dy + 30),
      );
      await tester.pumpFrames(harness, const Duration(milliseconds: 120));
      await gesture.moveTo(
        Offset(
            layerTopLeft.dx + itemWidth * targetCenter, layerTopLeft.dy + 30),
      );
      await tester.pump(const Duration(milliseconds: 80));
      final width = tester.getSize(lensFinder).width;
      await gesture.cancel();
      await tester.pumpAndSettle();
      return width;
    }

    final leftWidth = await dragAndMeasure(1.5);
    final rightWidth = await dragAndMeasure(3.5);

    expect(leftWidth, greaterThan(idleWidth));
    expect(rightWidth, greaterThan(idleWidth));
    expect(leftWidth, closeTo(rightWidth, 1.0));
  });

  testWidgets('V9 按住当前选中块激活连续 Capsule，松手回到基础 Lens idle', (tester) async {
    final harness = await _pumpNav(tester, liquidGlass: true);
    final gestureLayer = find.byKey(
      const ValueKey('bottom-nav-gesture-layer'),
    );
    final layerTopLeft = tester.getTopLeft(gestureLayer);
    final itemWidth = tester.getSize(gestureLayer).width / 5;

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);

    final gesture = await tester.startGesture(
      Offset(layerTopLeft.dx + itemWidth * 0.5, layerTopLeft.dy + 30),
    );
    await tester.pumpFrames(harness, const Duration(milliseconds: 60));

    expect(harness.phase.value, LiquidNavPhase.pressing);
    expect(harness.activation.value, greaterThan(0));
    expect(harness.activation.value, lessThan(1));
    expect(
      find.byKey(
        const ValueKey('bottom-nav-selection-interactive-highlight'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-base-blur')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-default-highlight')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);

    await tester.pumpFrames(harness, const Duration(milliseconds: 70));
    // V9 使用可中断 spring，不把 progress 人为截成 tween 的终点；
    // 此时应已进入完整玻璃态的接近区间，但仍允许物理收敛。
    expect(harness.activation.value, greaterThan(0.90));
    expect(
      find.byKey(const ValueKey('bottom-nav-selection')),
      findsOneWidget,
    );

    // Hold 不应因为没有移动而超时收回；这是 Press-to-Liquid 与普通长按的
    // 关键区别，完整 Lens 要一直保持到 pointer up。
    await tester.pumpFrames(harness, const Duration(seconds: 2));
    expect(harness.phase.value, LiquidNavPhase.pressing);
    expect(harness.activation.value, closeTo(1, 0.01));
    expect(
      find.byKey(const ValueKey('bottom-nav-selection')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-base-blur')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-nav-selection-default-highlight')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('bottom-nav-selection-interactive-highlight'),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(harness.commitCount.value, 0);
  });

  testWidgets('V9 快速点击只短暂触发 Pressed，不提交也不残留 Lens', (tester) async {
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
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection')),
      findsOneWidget,
    );
  });

  testWidgets('V9 拖动经历 dragging → settling → collapsing 并只提交一次',
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
    // Drag release 立即提交业务 Tab，settling 仅负责 Lens 的视觉收尾。
    expect(harness.selectedIndex.value, 2);
    expect(harness.commitCount.value, 1);
    await tester.pumpAndSettle();

    expect(harness.phase.value, LiquidNavPhase.idle);
    expect(harness.selectedIndex.value, 2);
    expect(harness.commitCount.value, 1);
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
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
    final lensFinder = find.byKey(const ValueKey('bottom-nav-selection'));
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

    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('bottom-nav-selection'))).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-3'))).dx,
        1,
      ),
    );
  });

  testWidgets('关闭液态玻璃时使用稳定的实色选中态', (tester) async {
    await _pumpNav(tester, liquidGlass: false);

    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bottom-nav-selection')),
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
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
  });

  testWidgets('渲染诊断仅在显式 QA 开关开启时出现', (tester) async {
    await _pumpNav(tester, liquidGlass: true, showDiagnostics: true);

    expect(
      find.byKey(const ValueKey('bottom-nav-liquid-diagnostics')),
      findsOneWidget,
    );
  });

  testWidgets('Old v1 preset 使用 57ca812 的宽 Capsule 且不启用当前挖空层', (tester) async {
    await _pumpNav(
      tester,
      liquidGlass: true,
      tuning: LiquidGlassTuning.oldV1,
    );

    final dockWidth = tester
        .getSize(find.byKey(const ValueKey('bottom-nav-floating-dock')))
        .width;
    final selectionWidth = tester
        .getSize(find.byKey(const ValueKey('bottom-nav-selection')))
        .width;

    expect(selectionWidth, greaterThan(dockWidth / 5));
    expect(
      find.byKey(const ValueKey('bottom-nav-normal-exclusion')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('bottom-nav-selection')), findsOneWidget);
    expect(tester.takeException(), isNull);
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
  bool showDiagnostics = false,
  LiquidGlassTuning tuning = LiquidGlassTuning.current,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  AppPreferencesStore.setMockInitialValues({
    'floating_nav_bar': true,
    'liquid_glass_v2': liquidGlass,
    'bottom_nav_performance_mode': liquidGlass ? 'high_quality' : 'auto',
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
    showDiagnostics: showDiagnostics,
    tuning: tuning,
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
    required this.showDiagnostics,
    required this.tuning,
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
  final bool showDiagnostics;
  final LiquidGlassTuning tuning;
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
                      tuning: tuning,
                      showDiagnostics: showDiagnostics,
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
